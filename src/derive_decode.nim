## derive_decode — per-type macro emitting `kdlDecode(v, c)` procs.
##
## The Cat 2 IN codegen path. `deriveDecode(T)` inspects T's structure
## at compile time and emits a proc specialized to T's field shape
## that pulls cursor events and populates a `var T` destination.
##
## ## Target cursor type — concrete StringCursor
##
## Mirrors the deriveEncode-targets-BufferEmitter decision (Stage C
## design notes). The cursor's token-resolution surface (bytes,
## bytesEqLit, tokenAsString) lives on StringCursor rather than the
## KdlCursor concept; a generic-on-concept derive would either pull
## all of that into the concept or pay an indirection cost per
## per-field lookup. Concrete is cleaner.
##
## ## Result shape
##
## `Result[void, ParseError]`. Caller pre-allocates `var T`; the
## decoder mutates. Aligns with `parser.parse` / `cursor.advance`
## error-path conventions.
##
## ## Stage D buildout
##
## - D1: tracer — single kdlArg string field
## - D2-D15: per docs/branch-rebuild-plan.md

import std/[macros, sets]

import std/options  # the emitted decoder constructs `some(value)` for Option[T] fields
export options       # so user code doesn't need to import options separately

import ./derive_common  # shared macro helpers (rfc-derive-vocabulary.md S0a)
import ./node
import ./value
import ./cursor
import ./token_text  # tokenAsString — single source of truth for token → string (rfc §6)
import ./lexer      # TokenKind / KeywordKind dispatch in emitted code
import ./numlit     # decodeIntFromToken / decodeFloatFromToken
import ./spans

# Re-export the substrate identifiers the emitted decoder body references
# (Result, ParseError, ok, err, initError, peTypeMismatch, etc., plus the
# cursor/lexer token-kind enum cases). Without these the caller would need
# to import every substrate module by hand.
export node, value, cursor, token_text, lexer, numlit, spans

# ---------------------------------------------------------------------------
# Macro
# ---------------------------------------------------------------------------
# nodeNameOf / objectRecList / isOptionType / isObjectTypeResolved /
# isEnumType now live in derive_common (S0c unification).

proc enumImpl(t: NimNode): NimNode =
  ## Resolve to the nnkEnumTy AST regardless of wrapper.
  let impl = t.getTypeImpl
  if impl.kind == nnkEnumTy: return impl
  if impl.kind == nnkBracketExpr and impl.len >= 2 and $impl[0] == "typeDesc":
    return impl[1].getTypeImpl
  impl

iterator enumVariantSyms(enumType: NimNode): string =
  ## Yield each enum variant's symbol name. The actual wire form
  ## (`$variant`, which honors `= "literal"` mappings) is computed at
  ## the call site via `$<sym>` — Nim's getTypeImpl strips the
  ## string-mapping attribute, so we can't read it at macro time.
  let impl = enumImpl(enumType)
  expectKind(impl, nnkEnumTy)
  for i in 1 ..< impl.len:
    let v = impl[i]
    case v.kind
    of nnkSym, nnkIdent: yield $v
    of nnkEnumFieldDef: yield $v[0]  # fallback for unwrapped enums
    else: discard

proc enrichLeafErrors(n: NimNode, fnLit: NimNode) =
  ## In-place: wrap every `err[void, ParseError](e)` in `n`'s subtree with
  ## `e.withField(fnLit)`, so a leaf arg/prop value-decode failure records
  ## the field name in the error's fieldPath (rfc §10 / #39 item 4). The
  ## child-boundary enrichment then prepends each enclosing child field as
  ## the error unwinds, yielding the full `outer.inner.port` path.
  # `err[void, ParseError](e)` takes two shapes depending on whether the
  # subtree is sym-bound: untyped it's Call(BracketExpr(err, ...), e);
  # after quote sym-binds `err` and `[]` it's Call(Call([], err, ...), e).
  # Match both and wrap the single arg `e` with `e.withField(fnLit)`.
  if n.kind in {nnkCall, nnkCommand} and n.len == 2:
    let head = n[0]
    let isErr =
      (head.kind == nnkBracketExpr and head.len >= 1 and head[0].eqIdent("err")) or
      (head.kind in {nnkCall, nnkCommand} and head.len >= 2 and head[1].eqIdent("err"))
    if isErr:
      n[1] = newCall(ident("withField"), n[1], fnLit)
      return   # the wrapped argument holds no further err() sites
  for i in 0 ..< n.len:
    enrichLeafErrors(n[i], fnLit)

proc emitTypedDecode(targetIdent: NimNode, tokIndexExpr: NimNode,
                     fieldType: NimNode, cSym: NimNode,
                     scalar: bool = false): NimNode =
  ## Emit the typed decode of a token at `tokIndexExpr` into
  ## `targetIdent`. Used by both arg-positional dispatch and
  ## prop-by-key dispatch. For Option[T], decode the inner T and
  ## wrap the result in `some(...)`. For plain T, assign directly.
  if scalar:
    # kdlScalar: lift the token to its typed `KdlValue` interchange form and
    # route through the user's `kdlDecodeValue(val, T): Result[T, string]`
    # hook (rfc §8 — typed scalar input: numbers/bools, not just strings).
    # The macro owns the ParseError construction — the hook's error string is
    # lifted with the value's span so users never touch span/ParseErrorCode
    # plumbing. A pre-hook lift failure (numeric overflow) carries its own
    # span-accurate ParseError straight through.
    return quote do:
      let tok = `cSym`.stream[].tokens[`tokIndexExpr`]
      let kvRes = tokenToKdlValue(tok, `cSym`.stream[], `cSym`.source)
      if kvRes.isErr:
        return err[void, ParseError](kvRes.getErr)
      let hookRes = kdlDecodeValue(kvRes.get, typeof(`targetIdent`))
      if hookRes.isErr:
        return err[void, ParseError](
          initError(peTypeMismatch, tok.span, hookRes.getErr))
      `targetIdent` = hookRes.get
  if isOptionType(fieldType):
    let inner = innerOfOption(fieldType)
    let tmpSym = genSym(nskVar, "decoded")
    let innerDecode = emitTypedDecode(tmpSym, tokIndexExpr, inner, cSym)
    return quote do:
      var `tmpSym`: `inner`
      `innerDecode`
      `targetIdent` = some(`tmpSym`)
  if isEnumType(fieldType):
    let tokSym = genSym(nskLet, "tok")
    let valSym = genSym(nskLet, "valBytes")
    var caseStmt = newTree(nnkCaseStmt, valSym)
    for symName in enumVariantSyms(fieldType):
      let symIdent = ident(symName)
      # Branch label is `$<sym>` evaluated at compile time — Nim
      # const-folds `$enumValue` to the variant's wire form (the
      # `= "literal"` mapping when present, else the symbol name).
      let wireExpr = newCall(ident("$"), symIdent)
      var assignBody = newStmtList()
      assignBody.add(newAssignment(targetIdent, symIdent))
      caseStmt.add(newTree(nnkOfBranch, wireExpr, assignBody))
    let elseErr = quote do:
      return err[void, ParseError](
        initError(peTypeEnumInvalid, `tokSym`.span,
                  "value does not match any enum variant"))
    caseStmt.add(newTree(nnkElse, elseErr))
    return quote do:
      let `tokSym` = `cSym`.stream[].tokens[`tokIndexExpr`]
      case `tokSym`.kind
      of tkString, tkRawString, tkIdent:
        let `valSym` = tokenAsString(`tokSym`, `cSym`.stream[], `cSym`.source)
        `caseStmt`
      else:
        return err[void, ParseError](
          initError(peTypeMismatch, `tokSym`.span,
                    "expected string value for enum field"))
  case baseTypeName(fieldType)
  of "string":
    return quote do:
      let tok = `cSym`.stream[].tokens[`tokIndexExpr`]
      case tok.kind
      of tkString, tkRawString, tkIdent:
        `targetIdent` = tokenAsString(tok, `cSym`.stream[], `cSym`.source)
      else:
        return err[void, ParseError](
          initError(peTypeMismatch, tok.span, "expected string value"))
  of "int", "int8", "int16", "int32", "int64":
    let typeNode = fieldType
    return quote do:
      let tok = `cSym`.stream[].tokens[`tokIndexExpr`]
      if tok.kind != tkNumber:
        return err[void, ParseError](
          initError(peTypeMismatch, tok.span, "expected integer value"))
      let decoded = decodeIntFromToken(
        numberText(`cSym`.source, tok.span), tok.numBase, tok.span)
      if decoded.isErr:
        return err[void, ParseError](decoded.getErr)
      `targetIdent` = `typeNode`(decoded.get)
  of "uint", "uint8", "uint16", "uint32", "uint64":
    let typeNode = fieldType
    return quote do:
      let tok = `cSym`.stream[].tokens[`tokIndexExpr`]
      if tok.kind != tkNumber:
        return err[void, ParseError](
          initError(peTypeMismatch, tok.span, "expected unsigned integer value"))
      let decoded = decodeIntFromToken(
        numberText(`cSym`.source, tok.span), tok.numBase, tok.span)
      if decoded.isErr:
        return err[void, ParseError](decoded.getErr)
      if decoded.get < 0:
        return err[void, ParseError](
          initError(peTypeMismatch, tok.span,
                    "expected unsigned (non-negative) integer"))
      `targetIdent` = `typeNode`(decoded.get)
  of "float", "float32", "float64":
    let typeNode = fieldType
    return quote do:
      let tok = `cSym`.stream[].tokens[`tokIndexExpr`]
      case tok.kind
      of tkNumber:
        let decoded = decodeFloatFromToken(
          numberText(`cSym`.source, tok.span), tok.span)
        if decoded.isErr:
          return err[void, ParseError](decoded.getErr)
        `targetIdent` = `typeNode`(decoded.get)
      of tkKeyword:
        case tok.keyword
        of kwInf:    `targetIdent` = `typeNode`(Inf)
        of kwNegInf: `targetIdent` = `typeNode`(NegInf)
        of kwNan:    `targetIdent` = `typeNode`(NaN)
        else:
          return err[void, ParseError](
            initError(peTypeMismatch, tok.span, "expected float value"))
      else:
        return err[void, ParseError](
          initError(peTypeMismatch, tok.span, "expected float value"))
  of "bool":
    return quote do:
      let tok = `cSym`.stream[].tokens[`tokIndexExpr`]
      if tok.kind != tkKeyword:
        return err[void, ParseError](
          initError(peTypeMismatch, tok.span, "expected bool value"))
      case tok.keyword
      of kwTrue:  `targetIdent` = true
      of kwFalse: `targetIdent` = false
      else:
        return err[void, ParseError](
          initError(peTypeMismatch, tok.span, "expected bool value"))
  else:
    error("deriveDecode: field type " & $fieldType &
          " not yet supported (D1-D3 cover string/int/float/bool)")
    return newEmptyNode()

macro deriveDecode*(T: typedesc): untyped =
  ## Emit `proc kdlDecode(v: var T; c: var StringCursor): Result[void, ParseError]`
  ## specialized to T's field shape. Pulls cursor events, dispatches
  ## each to the right field, returns success or the first error.
  let typeSym = T.getTypeInst[1]
  let wireName = nodeNameOf(typeSym)
  # `ref object` as the user-facing type (#9/#39): the proc receives
  # `v: var RefT` defaulted to nil, so the field assignments below would
  # deref nil. Allocate once up front. Value objects need no prologue.
  let typeIsRef = typeSym.getImpl[2].kind == nnkRefTy
  let refInit =
    if typeIsRef: newCall(ident("new"), ident("v"))
    else: newEmptyNode()
  let vSym = ident("v")
  let cSym = ident("c")
  let evSym = ident("ev")
  let evSym2 = ident("ev2")
  let argIdxSym = ident("argIdx")
  let sdDepthSym = ident("sdDepth")

  # Collect kdlArg + kdlProp + kdlChild fields by pragma role.
  type ChildKind = enum ckSingle, ckSeq, ckOption
  # pathExpr = the field's LHS access expression (default `v.<field>`, but
  # S8 flatten passes a compound base). requiresUncheckedAssign = true only
  # for the variant discriminator field; a discriminator write must stay
  # wrapped in `{.cast(uncheckedAssign).}` at every emit site (rfc S0b).
  type ArgField = tuple[name: string, typ: NimNode, reservedTag: string,
                        scalar: bool, pathExpr: NimNode,
                        requiresUncheckedAssign: bool]
  type PropField = tuple[name: string, typ: NimNode, wireKey: string,
                         reservedTag: string, scalar: bool, pathExpr: NimNode,
                         requiresUncheckedAssign: bool]
  type ChildField = tuple[name: string, elemType: NimNode,
                          kind: ChildKind, wireName: string, pathExpr: NimNode,
                          requiresUncheckedAssign: bool]
  var argFields: seq[ArgField]
  var propFields: seq[PropField]              # plain (non-variant) props
  var childFields: seq[ChildField]            # plain children
  # The single `{.kdlVariadic.}` field (rfc S1), if any. It collects every
  # positional arg beyond the fixed kdlArg fields into a `seq[elemType]`.
  # Routed here (NOT into argFields) and excluded from the required bitmap —
  # an empty arg tail yields an empty seq, never a missing-required error.
  var hasVariadic = false
  var variadicName: string
  var variadicElemType: NimNode = nil
  var variadicPath: NimNode = nil
  # Variant info: when the object is a case object, we track the
  # discriminator (so we know how to dispatch later) and per-branch
  # prop fields (so each branch's ceProp matches its own field set).
  var hasVariant = false
  var discName: string
  var discIdent: NimNode = nil
  var branchProps: seq[tuple[branchVal: NimNode, props: seq[PropField]]]

  proc classify(fieldName: string, fieldType: NimNode,
                pragmas: seq[NimNode];
                argSink: var seq[ArgField];
                propSink: var seq[PropField];
                childSink: var seq[ChildField];
                baseExpr: NimNode = nil) =
    # The field's LHS access expression. With no `baseExpr` (the S0b/default
    # path) this is `v.<field>`, byte-identical to the prior emit-site
    # `quote do: vSym.fIdent`. S8 flatten supplies a compound base prefix.
    let pathExpr =
      if baseExpr != nil: newDotExpr(baseExpr, ident(fieldName))
      else: newDotExpr(vSym, ident(fieldName))
    # The discriminator field is the only one whose assignment must be
    # wrapped in `{.cast(uncheckedAssign).}` (a discriminator write is
    # otherwise illegal outside its case branch).
    let needsUnchecked = hasVariant and fieldName == discName
    let reservedArg = pragmaArg(pragmas, "kdlReserved")
    let reservedTag =
      if reservedArg != nil and reservedArg.kind == nnkStrLit:
        reservedArg.strVal
      else: ""
    # kdlScalar: the value is encoded/decoded via the user hook pair rather
    # than the built-in primitive dispatch. It's a slot MODIFIER, not a slot
    # selector — it still lands in an arg or prop. With no explicit kdlArg/
    # kdlProp it defaults to a prop (key = field name).
    let scalar = hasPragma(pragmas, "kdlScalar")
    let isSeqField =
      fieldType.kind == nnkBracketExpr and fieldType[0].eqIdent("seq")
    # {.kdlVariadic.}: collects all remaining positional args into seq[T].
    # Macro-time guards (rfc §3.5.5.1 message format): exactly one per type;
    # the field MUST be a seq; the element type T must be scalar (args are
    # never child-shaped objects).
    if hasPragma(pragmas, "kdlVariadic"):
      if not isSeqField:
        error("{.kdlVariadic.} requires a seq[T] field; '" & fieldName &
              "' has type '" & $fieldType & "'.")
      if hasVariadic:
        error("{.kdlVariadic.} on '" & fieldName &
              "': only one variadic field is allowed per type; '" &
              variadicName & "' already claims the positional tail. " &
              "Merge them into one seq[T].")
      let elemT = fieldType[1]
      if isObjectTypeResolved(elemT) and not scalar:
        error("{.kdlVariadic.} on '" & fieldName & "': element type '" &
              $elemT & "' is child-shaped, but positional args are scalar. " &
              "Use {.kdlChild.} for a seq of nested objects.")
      hasVariadic = true
      variadicName = fieldName
      variadicElemType = elemT
      variadicPath = pathExpr
      return
    # {.kdlArg.} on a seq field is the classic mistake — kdlArg consumes a
    # single positional. Point the user at kdlVariadic (rfc §3.5.5.1).
    if hasPragma(pragmas, "kdlArg") and isSeqField:
      error("{.kdlArg.} on a seq field '" & fieldName &
            "' consumes only one argument. Did you mean {.kdlVariadic.}?")
    if hasPragma(pragmas, "kdlArg"):
      argSink.add((name: fieldName, typ: fieldType, reservedTag: reservedTag,
                   scalar: scalar, pathExpr: pathExpr,
                   requiresUncheckedAssign: needsUnchecked))
    elif hasPragma(pragmas, "kdlProp") or (scalar and
         not hasPragma(pragmas, "kdlChild")):
      let renameArg = pragmaArg(pragmas, "kdlRename")
      let wireKey =
        if renameArg != nil and renameArg.kind == nnkStrLit:
          renameArg.strVal
        else: fieldName
      propSink.add((name: fieldName, typ: fieldType, wireKey: wireKey,
                    reservedTag: reservedTag, scalar: scalar,
                    pathExpr: pathExpr,
                    requiresUncheckedAssign: needsUnchecked))
    elif hasPragma(pragmas, "kdlChild"):
      var kind: ChildKind
      var elemType: NimNode
      if fieldType.kind == nnkBracketExpr and fieldType[0].eqIdent("seq"):
        kind = ckSeq
        elemType = fieldType[1]
      elif isOptionType(fieldType):
        # Option[Inner] child: peel to Inner so nodeNameOf sees a type sym
        # (getImpl rejects the BracketExpr wrapper). Absent → None.
        kind = ckOption
        elemType = innerOfOption(fieldType)
      else:
        kind = ckSingle
        elemType = fieldType
      childSink.add((name: fieldName, elemType: elemType, kind: kind,
                     wireName: nodeNameOf(elemType), pathExpr: pathExpr,
                     requiresUncheckedAssign: needsUnchecked))
    else:
      # No routing pragma — infer the slot from the field type (rfc §8.2,
      # name-preserving). Previously this fell through silently, dropping the
      # field from the decoder (a D3 "fail loud" violation).
      var ft = fieldType
      if isOptionType(ft): ft = innerOfOption(ft)   # Option[X] inherits X's routing
      if ft.kind == nnkBracketExpr and ft[0].eqIdent("seq"):
        if isObjectTypeResolved(ft[1]):
          childSink.add((name: fieldName, elemType: ft[1], kind: ckSeq,
                         wireName: nodeNameOf(ft[1]), pathExpr: pathExpr,
                         requiresUncheckedAssign: needsUnchecked))
        else:
          error("deriveDecode: cannot infer a KDL slot for seq field '" &
                fieldName & "' of primitive elements — annotate it with " &
                "{.kdlArg.} (variadic args) or {.kdlChild.}")
      elif isObjectTypeResolved(ft):
        # Option[object] infers to an optional child (absent → None); plain
        # object infers to a single required child.
        let kind = if isOptionType(fieldType): ckOption else: ckSingle
        childSink.add((name: fieldName, elemType: ft, kind: kind,
                       wireName: nodeNameOf(ft), pathExpr: pathExpr,
                       requiresUncheckedAssign: needsUnchecked))
      else:
        # primitive / enum (incl. Option[primitive]) → prop; key = field name.
        propSink.add((name: fieldName, typ: fieldType, wireKey: fieldName,
                      reservedTag: reservedTag, scalar: false,
                      pathExpr: pathExpr,
                      requiresUncheckedAssign: needsUnchecked))

  let recList = objectRecList(typeSym)
  for (fieldName, fieldType, pragmas, _) in regularFields(recList):
    classify(fieldName, fieldType, pragmas, argFields, propFields, childFields)
  let recCase = findRecCase(recList)
  if recCase != nil:
    hasVariant = true
    # Discriminator IdentDefs is recCase[0]; classify it as a regular
    # arg/prop so it gets decoded into v.<discName> at its source position.
    let discDefs = recCase[0]
    let discType = discDefs[^2]
    let (dn, dPragmas) = fieldInfo(discDefs, 0)
    discName = dn
    discIdent = ident(dn)
    classify(discName, discType, dPragmas, argFields, propFields, childFields)
    # Per-branch field collection.
    for i in 1 ..< recCase.len:
      let branch = recCase[i]
      var args2: seq[ArgField]
      var props2: seq[PropField]
      var children2: seq[ChildField]
      let branchRecList =
        if branch.kind == nnkOfBranch: branch[^1]
        elif branch.kind == nnkElse:   branch[0]
        else: newEmptyNode()
      if branchRecList.kind == nnkRecList:
        for (bf, bt, bp, _) in regularFields(branchRecList):
          classify(bf, bt, bp, args2, props2, children2)
      if args2.len > 0 or children2.len > 0:
        error("deriveDecode: branch fields other than kdlProp not yet " &
              "supported (D8 cycle covers kdlProp per-branch)")
      # Each branch's of-value list lives at branch[0..^2]; capture as
      # a single NimNode (the branch's variant identifier).
      if branch.kind == nnkOfBranch:
        # Single-value branches only for now — multi-value `of A, B:` is
        # exotic enough to defer.
        if branch.len != 2:
          error("deriveDecode: multi-value `of A, B:` branches not yet " &
                "supported")
        branchProps.add((branchVal: branch[0], props: props2))

  # Required-field bitmap. Each non-Option / non-seq kdlArg / kdlProp /
  # kdlChild gets a slot bit; final mask compare emits
  # peTypeMissingRequired when any required field was missed. Branch
  # fields (variant) are conditionally required per branch — current
  # implementation marks them as not-required to avoid the per-branch
  # mask complexity; a later cycle adds branch-aware tracking.
  let seenSym = ident("__slotsSeen")
  var requiredMask: uint64 = 0
  var nextSlot = 0
  proc claimSlot(): int =
    if nextSlot >= 64:
      # The required-field bitmap is a uint64; slots past 63 would silently lose
      # their required bit (missing-required would never fire). Fail loud (§8.7).
      error("deriveDecode: type has more than 64 required fields — make some " &
            "Option[T] / {.kdlSkip.}, or split the type")
    result = nextSlot
    requiredMask = requiredMask or (1'u64 shl result)
    inc nextSlot

  proc isOptionalKdlArgOrProp(typ: NimNode): bool =
    isOptionType(typ)

  # Pre-allocate slots in declaration order. Discriminator field doesn't
  # need a required-slot — the case-object machinery itself ensures the
  # discriminator is set; the cursor either provided it or the decode
  # already errored at the type level.
  var argSlots: seq[int]
  for (fName, fType, _, _, _, _) in argFields:
    if isOptionalKdlArgOrProp(fType) or (hasVariant and fName == discName):
      argSlots.add(-1)
    else:
      argSlots.add(claimSlot())
  var propSlots: seq[int]
  for (fName, fType, _, _, _, _, _) in propFields:
    if isOptionalKdlArgOrProp(fType) or (hasVariant and fName == discName):
      propSlots.add(-1)
    else:
      propSlots.add(claimSlot())
  var childSlots: seq[int]
  for (_, _, kind, _, _, _) in childFields:
    if kind in {ckSeq, ckOption}:
      childSlots.add(-1)  # empty seq / absent Option is fine
    else:
      childSlots.add(claimSlot())

  proc markSlot(slot: int): NimNode =
    if slot < 0:
      newStmtList()
    else:
      let bit = newLit(1'u64 shl slot)
      quote do:
        `seenSym` = `seenSym` or `bit`

  # Build the per-arg dispatch.
  var argCase = newTree(nnkCaseStmt, argIdxSym)
  for i, af in argFields:
    let fName = af.name
    let fType = af.typ
    let reservedTag = af.reservedTag
    let argScalar = af.scalar
    let idxLit = newIntLitNode(i)
    let tokIndexExpr = quote do: `evSym2`.argTok
    let target = af.pathExpr
    var branchBody = emitTypedDecode(target, tokIndexExpr, fType, cSym, argScalar)
    enrichLeafErrors(branchBody, newLit(fName))
    if af.requiresUncheckedAssign:
      let bodyCopy = branchBody
      branchBody = quote do:
        {.cast(uncheckedAssign).}:
          `bodyCopy`
    let mark = markSlot(argSlots[i])
    # kdlReserved tag check (if declared). Verify the cursor event's
    # arg-annotation matches the declared tag; mismatch → error. The
    # tag literal is inlined at the call site via bytesEqLit so the
    # compiler folds the length + byte checks.
    var reservedCheck = newStmtList()
    if reservedTag.len > 0:
      let tagLit = newStrLitNode(reservedTag)
      reservedCheck = quote do:
        if `evSym2`.argAnnoTok < 0 or
           not bytesEqLit(`cSym`, `evSym2`.argAnnoTok, `tagLit`):
          return err[void, ParseError](
            initError(peTypeReservedMismatch, `evSym2`.span,
                      "expected (" & `tagLit` & ") annotation on value"))
    branchBody = quote do:
      `reservedCheck`
      `branchBody`
      `mark`
    argCase.add(newTree(nnkOfBranch, idxLit, branchBody))
  if hasVariadic:
    # Every positional arg beyond the fixed kdlArg fields decodes as the
    # variadic element type and appends to the seq (rfc S1). No required-slot
    # mark — a variadic field is never required.
    let elemSym = genSym(nskVar, "variadicElem")
    let tokIndexExpr = quote do: `evSym2`.argTok
    var elemDecode = emitTypedDecode(elemSym, tokIndexExpr, variadicElemType, cSym)
    enrichLeafErrors(elemDecode, newLit(variadicName))
    let vPath = variadicPath
    argCase.add(newTree(nnkElse,
      quote do:
        var `elemSym`: `variadicElemType`
        `elemDecode`
        `vPath`.add(`elemSym`)))
  else:
    argCase.add(newTree(nnkElse,
      quote do:
        return err[void, ParseError](
          initError(peParseUnexpected, `evSym2`.span,
                    "unexpected extra positional argument"))))

  # FNV-1a 32-bit, evaluated at macro time so each prop key's hash
  # becomes a const branch label. Must match cursor.tokenBytesHash
  # byte-for-byte (FNV-1a 32-bit; offset 0x811C9DC5; prime 0x01000193).
  proc fnv32(s: string): uint32 =
    result = 0x811C9DC5'u32
    for ch in s:
      result = result xor uint32(uint8(ch))
      result = result * 0x01000193'u32

  proc buildPropIf(fields: seq[PropField], slots: seq[int]): NimNode =
    ## ≤8 fields → bytesEqLit if-elif chain (compiler-folded inline).
    ## >8 fields with no macro-time hash collisions → case-on-FNV-32
    ## dispatch with bytesEqLit confirmation per branch.
    ##
    ## bytesEqLit takes the literal directly (no lifted-let plumbing);
    ## the macro expands to per-byte compares the compiler folds.
    if fields.len == 0:
      return quote do:
        return err[void, ParseError](
          initError(peTypeUnknownField, `evSym2`.span,
                    "unknown property"))
    proc branchBodyFor(i: int): NimNode =
      let fName = fields[i].name
      let fType = fields[i].typ
      let reservedTag = fields[i].reservedTag
      let tokIndexExpr = quote do: `evSym2`.propValueTok
      let target = fields[i].pathExpr
      var decodeBody = emitTypedDecode(target, tokIndexExpr, fType, cSym,
                                       fields[i].scalar)
      enrichLeafErrors(decodeBody, newLit(fName))
      if fields[i].requiresUncheckedAssign:
        let bodyCopy = decodeBody
        decodeBody = quote do:
          {.cast(uncheckedAssign).}:
            `bodyCopy`
      let mark = markSlot(slots[i])
      var reservedCheck = newStmtList()
      if reservedTag.len > 0:
        let tagLit = newStrLitNode(reservedTag)
        reservedCheck = quote do:
          if `evSym2`.propAnnoTok < 0 or
             not bytesEqLit(`cSym`, `evSym2`.propAnnoTok, `tagLit`):
            return err[void, ParseError](
              initError(peTypeReservedMismatch, `evSym2`.span,
                        "expected (" & `tagLit` & ") annotation on value"))
      quote do:
        `reservedCheck`
        `decodeBody`
        `mark`
    # Perfect-hash path for wide types — only if no macro-time hash
    # collisions (we don't iterate seeds; fall back to if-elif on
    # collision).
    var useHash = fields.len > 8
    var hashes: seq[uint32]
    if useHash:
      var seen = initHashSet[uint32]()
      for f in fields:
        let h = fnv32(f.wireKey)
        if h in seen:
          useHash = false
          break
        seen.incl(h)
        hashes.add(h)
    if useHash:
      var caseStmt = newTree(nnkCaseStmt,
        newCall(bindSym"tokenBytesHash", cSym,
                quote do: `evSym2`.propKeyTok))
      for i in 0 ..< fields.len:
        let hLit = newLit(hashes[i])
        let keyLit = newStrLitNode(fields[i].wireKey)
        let decodeBlock = branchBodyFor(i)
        # bytesEqLit confirmation guards against runtime hash collisions
        # from unknown keys that happen to map to a known field's hash.
        # The literal is inlined; compiler folds the per-byte checks.
        let confirmed = quote do:
          if bytesEqLit(`cSym`, `evSym2`.propKeyTok, `keyLit`):
            `decodeBlock`
          else:
            return err[void, ParseError](
              initError(peTypeUnknownField, `evSym2`.span,
                        "unknown property"))
        caseStmt.add(newTree(nnkOfBranch, hLit, confirmed))
      caseStmt.add(newTree(nnkElse, quote do:
        return err[void, ParseError](
          initError(peTypeUnknownField, `evSym2`.span,
                    "unknown property"))))
      return caseStmt
    # Default: if-elif chain.
    var ifNode = newNimNode(nnkIfStmt)
    for i in 0 ..< fields.len:
      let keyLit = newStrLitNode(fields[i].wireKey)
      let cond = quote do: bytesEqLit(`cSym`, `evSym2`.propKeyTok, `keyLit`)
      ifNode.add(newNimNode(nnkElifBranch).add(cond).add(branchBodyFor(i)))
    ifNode.add(newNimNode(nnkElse).add(quote do:
      return err[void, ParseError](
        initError(peTypeUnknownField, `evSym2`.span,
                  "unknown property"))))
    ifNode

  var propDispatch = newStmtList()
  if hasVariant:
    var caseStmt = newTree(nnkCaseStmt, quote do: `vSym`.`discIdent`)
    for i, (branchVal, props) in branchProps:
      var branchSlots: seq[int]
      for _ in props: branchSlots.add(-1)
      let perBranchIf = buildPropIf(props, branchSlots)
      caseStmt.add(newTree(nnkOfBranch, branchVal, perBranchIf))
    propDispatch.add(caseStmt)
  else:
    propDispatch.add(buildPropIf(propFields, propSlots))

  # Build the per-child dispatch (used inside the ceChildrenBegin loop).
  let nextEvSym = ident("nextEv")
  let childPeekSym = ident("childPeek")
  var childDispatchBody: NimNode
  if childFields.len > 0:
    var rootIf: NimNode = nil
    for i, cf in childFields:
      let fName = cf.name
      let kind = cf.kind
      let wireName = cf.wireName
      let pathExpr = cf.pathExpr
      let keyLit = newStrLitNode(wireName)
      let cond = quote do:
        bytesEqLit(`cSym`, `childPeekSym`.nodeNameTok, `keyLit`)
      let mark = markSlot(childSlots[i])
      let fNameLit = newStrLitNode(fName)   # field-path enrichment (rfc §10)
      let body =
        case kind
        of ckSingle:
          quote do:
            let r = kdlDecode(`pathExpr`, `cSym`)
            if r.isErr: return err[void, ParseError](r.getErr.withField(`fNameLit`))
            `mark`
        of ckSeq:
          let elemSym = genSym(nskVar, "childElem")
          let elemType = childFields[i].elemType
          quote do:
            var `elemSym`: `elemType`
            let r = kdlDecode(`elemSym`, `cSym`)
            if r.isErr: return err[void, ParseError](r.getErr.withField(`fNameLit`))
            `pathExpr`.add(`elemSym`)
        of ckOption:
          let elemSym = genSym(nskVar, "childElem")
          let elemType = childFields[i].elemType
          quote do:
            var `elemSym`: `elemType`
            let r = kdlDecode(`elemSym`, `cSym`)
            if r.isErr: return err[void, ParseError](r.getErr.withField(`fNameLit`))
            `pathExpr` = some(`elemSym`)
            `mark`
      if rootIf.isNil:
        rootIf = newNimNode(nnkIfStmt)
        rootIf.add(newNimNode(nnkElifBranch).add(cond).add(body))
      else:
        rootIf.add(newNimNode(nnkElifBranch).add(cond).add(body))
    rootIf.add(newNimNode(nnkElse).add(quote do:
      skip(`cSym`)))
    childDispatchBody = rootIf
  else:
    childDispatchBody = quote do:
      skip(`cSym`)

  let requiredMaskLit = newLit(requiredMask)
  let wireNameLit = newStrLitNode(wireName)
  let body = quote do:
    block:
      var `seenSym`: uint64 = 0
      `refInit`
      let `evSym` = advance(`cSym`)
      if `evSym`.kind == ceError:
        return err[void, ParseError](`evSym`.err[])
      if `evSym`.kind != ceNodeBegin:
        return err[void, ParseError](
          initError(peParseExpected, `evSym`.span,
                    "expected node begin"))
      if not bytesEqLit(`cSym`, `evSym`.nodeNameTok, `wireNameLit`):
        return err[void, ParseError](
          initError(peParseExpected, `evSym`.span,
                    "expected node named '" & `wireNameLit` & "'"))
      var `argIdxSym` = 0
      var `sdDepthSym` = 0
      while true:
        let `evSym2` = advance(`cSym`)
        # Inside a `/-` slashdash bracket all decoding is suppressed; we
        # only track Begin/End nesting to find the matching close. The
        # cursor still emits the slashdashed entry/children events, so a
        # naive loop would decode them as real (the bug this guards). Cat 3
        # `buildDoc` does the identical thing — the two surfaces must agree.
        if `sdDepthSym` > 0:
          case `evSym2`.kind
          of ceSlashdashBegin: inc `sdDepthSym`
          of ceSlashdashEnd:   dec `sdDepthSym`
          of ceError: return err[void, ParseError](`evSym2`.err[])
          of ceEof:
            return err[void, ParseError](
              initError(peParseExpected, `evSym2`.span,
                        "unexpected EOF inside slashdash"))
          else: discard
          continue
        case `evSym2`.kind
        of ceArg:
          `argCase`
          inc `argIdxSym`
        of ceProp:
          `propDispatch`
        of ceSlashdashBegin:
          inc `sdDepthSym`
        of ceChildrenBegin:
          # Inner child-loop: drives until ceChildrenEnd. For each
          # ceNodeBegin we peek (so the recursive kdlDecode can read
          # the ceNodeBegin itself), dispatch by wire-name, and
          # recurse. Unknown names get skip()'d.
          while true:
            let `childPeekSym` = peek(`cSym`)
            case `childPeekSym`.kind
            of ceChildrenEnd:
              discard advance(`cSym`)
              break
            of ceNodeBegin:
              `childDispatchBody`
            of ceSlashdashBegin:
              # A `/-` slashdashed child node (or block) inside a real
              # children block: consume the whole slashdashed span without
              # dispatching, tracking nesting to its matching close.
              discard advance(`cSym`)
              var `sdDepthSym` = 1
              while `sdDepthSym` > 0:
                let `evSym2` = advance(`cSym`)
                case `evSym2`.kind
                of ceSlashdashBegin: inc `sdDepthSym`
                of ceSlashdashEnd:   dec `sdDepthSym`
                of ceError: return err[void, ParseError](`evSym2`.err[])
                of ceEof:
                  return err[void, ParseError](
                    initError(peParseExpected, `evSym2`.span,
                              "unexpected EOF inside slashdash"))
                else: discard
            of ceEof:
              return err[void, ParseError](
                initError(peParseExpected, `childPeekSym`.span,
                          "unexpected EOF in children block"))
            of ceError:
              discard advance(`cSym`)
              return err[void, ParseError](`childPeekSym`.err[])
            else:
              discard advance(`cSym`)
        of ceNodeEnd:
          break
        of ceError:
          return err[void, ParseError](`evSym2`.err[])
        of ceEof:
          return err[void, ParseError](
            initError(peParseExpected, `evSym2`.span,
                      "unexpected EOF inside node"))
        else:
          discard
      # Required-field validation. Each non-Option / non-seq field set
      # its bit during decode; if the bitmap doesn't cover the mask,
      # report the first missing field.
      if (`seenSym` and `requiredMaskLit`) != `requiredMaskLit`:
        return err[void, ParseError](
          initError(peTypeMissingRequired, `evSym`.span,
                    "missing required field"))
      return ok(void, ParseError)

  result = newProc(
    name = newIdentNode("kdlDecode"),
    params = @[
      newIdentDefs(ident("__unused_result"), newEmptyNode(),
                   newEmptyNode())  # placeholder; replaced below
    ],
    body = body
  )
  # Re-build params with the correct shape (avoids fighting newProc's
  # awkward result-type-as-first-param convention).
  result.params = newTree(nnkFormalParams,
    nnkBracketExpr.newTree(ident("Result"), ident("void"), ident("ParseError")),
    newIdentDefs(vSym, nnkVarTy.newTree(typeSym)),
    newIdentDefs(cSym, nnkVarTy.newTree(ident("StringCursor")))
  )
  # noSideEffect lets the macro-emitted proc run in NimVM at compile
  # time. `embed[T](staticSrc)` uses this to materialize a `const T`
  # baked into the binary with zero runtime parse cost. The substrate
  # is pure Nim everywhere (bytesEqLit emits inline byte compares, not
  # FFI), so the VM has nothing it can't interpret.
  result.pragma = newTree(nnkPragma, ident("noSideEffect"))

# embed[T] lives in src/api.nim — single canonical compile-time decode
# path that delegates to decode[T]. Kept out of derive_decode so this
# module stays focused on macro emission.
