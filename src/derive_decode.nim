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
  # S2b: type-level {.kdlRenameAll: kcX.} convention string (e.g.
  # "kcKebabCase"), or "" if absent. Threaded into every field's wireKey
  # via wireKeyOf. Affects prop keys only — never the node name above.
  let typeConvention = typeConventionOf(typeSym)
  # S4: type-level {.kdlIgnoreUnknown.} relaxes the default strict-unknown
  # behavior. When false (default), an unknown prop or child node errors with
  # peTypeUnknownField; when true, both are skipped/consumed and ignored.
  let ignoreUnknown = typeHasFlagPragma(typeSym, "kdlIgnoreUnknown")
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
  # `default` (S5): the field's native default expression (`field = expr`),
  # or `nnkEmpty` when absent. A defaulted field claims a slot WITHOUT
  # entering requiredMask, and its default is spliced post-decode iff the
  # field's slot bit stayed unset (absent from the wire). `isBranchField`
  # excludes variant-branch fields from the global default post-loop
  # (assigning an inactive branch's field corrupts the object).
  type ArgField = tuple[name: string, typ: NimNode, reservedTag: string,
                        scalar: bool, pathExpr: NimNode,
                        requiresUncheckedAssign: bool,
                        default: NimNode, isBranchField: bool]
  # `aliases` (rfc S6): extra DECODE-ONLY exact wire-key literals. Each gets an
  # additional `bytesEqLit` arm routing to this same field's decode body; encode
  # ignores them entirely (canonical `wireKey` only). Aliases are NEVER run
  # through `kdlRenameAll` — they are verbatim literals (§3.5.3).
  type PropField = tuple[name: string, typ: NimNode, wireKey: string,
                         reservedTag: string, scalar: bool, pathExpr: NimNode,
                         requiresUncheckedAssign: bool,
                         default: NimNode, isBranchField: bool,
                         aliases: seq[string]]
  type ChildField = tuple[name: string, elemType: NimNode,
                          kind: ChildKind, wireName: string, pathExpr: NimNode,
                          requiresUncheckedAssign: bool,
                          default: NimNode, isBranchField: bool]
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
                fieldDefault: NimNode = nil;
                isBranchField: bool = false;
                baseExpr: NimNode = nil) =
    # S5: the field's native default (`field = expr`), `nnkEmpty`/nil when
    # none. The macro splices it post-decode for top-level fields absent
    # from the wire.
    #
    # embed[T]/VM safety: the RFC (§4 S5) called for a Call/Command-head
    # {.noSideEffect.} guard here. That guard is unreachable as specced —
    # by the time deriveDecode runs on a typed `T`, Nim has already
    # const-folded every object-field default initializer (verified:
    # `port: int = sideEffecting()` arrives as `nnkIntLit 1`, the VM having
    # evaluated the call at type-definition time). A default that is *not*
    # VM-evaluable (e.g. an FFI/importc call) fails at the `type` definition
    # itself with "cannot 'importc' ... at compile time", strictly before
    # this macro sees it. So the VM-safety property the guard wanted is
    # already structurally enforced one phase earlier by Nim's own folding;
    # emitting a guard that can never fire would be dead code. The defaults
    # we receive are always VM-evaluable literals, exactly what embed[T]
    # needs.
    let fDefault =
      if fieldDefault == nil: newEmptyNode() else: fieldDefault
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
    # S6: decode-only alias keys (exact literals, never convention-transformed).
    let aliases = pragmaStrArgs(pragmas, "kdlAlias")
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
                   requiresUncheckedAssign: needsUnchecked,
                   default: fDefault, isBranchField: isBranchField))
    elif hasPragma(pragmas, "kdlProp") or (scalar and
         not hasPragma(pragmas, "kdlChild")):
      # S2b: kdlRename wins; else the type-level convention is applied.
      let wireKey = wireKeyOf(fieldName, pragmas, typeConvention)
      propSink.add((name: fieldName, typ: fieldType, wireKey: wireKey,
                    reservedTag: reservedTag, scalar: scalar,
                    pathExpr: pathExpr,
                    requiresUncheckedAssign: needsUnchecked,
                    default: fDefault, isBranchField: isBranchField,
                    aliases: aliases))
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
                     requiresUncheckedAssign: needsUnchecked,
                     default: fDefault, isBranchField: isBranchField))
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
                         requiresUncheckedAssign: needsUnchecked,
                         default: fDefault, isBranchField: isBranchField))
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
                       requiresUncheckedAssign: needsUnchecked,
                       default: fDefault, isBranchField: isBranchField))
      else:
        # primitive / enum (incl. Option[primitive]) → prop; key via
        # wireKeyOf (S2b: type-level convention, or field name verbatim).
        propSink.add((name: fieldName, typ: fieldType,
                      wireKey: wireKeyOf(fieldName, pragmas, typeConvention),
                      reservedTag: reservedTag, scalar: false,
                      pathExpr: pathExpr,
                      requiresUncheckedAssign: needsUnchecked,
                      default: fDefault, isBranchField: isBranchField,
                      aliases: aliases))

  let recList = objectRecList(typeSym)
  for (fieldName, fieldType, pragmas, fieldDefault) in regularFields(recList):
    classify(fieldName, fieldType, pragmas, argFields, propFields, childFields,
             fieldDefault, isBranchField = false)
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
        for (bf, bt, bp, bd) in regularFields(branchRecList):
          classify(bf, bt, bp, args2, props2, children2, bd,
                   isBranchField = true)
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

  # S6: validate the canonical∪alias union is globally unique (§3.5.3 ordering:
  # canonical keys resolved above, now fold the aliases in and check). A
  # collision — an alias shadowing another field's canonical key, or two fields
  # claiming the same alias — would make prop dispatch ambiguous, so reject it
  # at macro time. The check spans the prop set actually visible during a given
  # decode: the flat propFields for a non-variant type, and (top-level props ∪
  # one branch's props) for each variant branch.
  proc checkKeyUnion(props: seq[PropField]) =
    var seen = initHashSet[string]()
    for pf in props:
      if pf.wireKey in seen:
        error("{.kdlProp.}/{.kdlAlias.} key collision: '" & pf.wireKey &
              "' is claimed by more than one field on this type. Wire keys " &
              "(canonical + aliases) must be globally unique.")
      seen.incl(pf.wireKey)
      for a in pf.aliases:
        if a in seen:
          error("{.kdlAlias.} '" & a & "' on field '" & pf.name &
                "' collides with another field's wire key or alias. Alias " &
                "keys must be globally unique across the type.")
        seen.incl(a)
  if hasVariant:
    for (_, props) in branchProps:
      checkKeyUnion(propFields & props)
  else:
    checkKeyUnion(propFields)

  # Required-field bitmap. Each non-Option / non-seq kdlArg / kdlProp /
  # kdlChild gets a slot bit; final mask compare emits
  # peTypeMissingRequired when any required field was missed. Branch
  # fields (variant) are conditionally required per branch — current
  # implementation marks them as not-required to avoid the per-branch
  # mask complexity; a later cycle adds branch-aware tracking.
  let seenSym = ident("__slotsSeen")
  var requiredMask: uint64 = 0
  var nextSlot = 0
  # S5: slot→wireKey for REQUIRED slots only — drives the named missing-required
  # error (scan for the first unset required slot, report its wire key).
  var requiredSlotKeys: seq[tuple[slot: int, wireKey: string]]
  # S5: defaulted top-level fields, indexed by SLOT (not declaration order —
  # optional fields get slot -1 and would misalign a declaration-indexed array).
  # Post-decode: for each, if its slot bit stayed unset, splice the default.
  var defaultedFields: seq[tuple[slot: int, pathExpr: NimNode, defaultExpr: NimNode]]
  proc claimSlot(required: bool): int =
    if nextSlot >= 64:
      # The bitmap is a uint64; slots past 63 would silently lose their bit
      # (missing-required would never fire / a default would never apply).
      # Fail loud (§8.7).
      error("deriveDecode: type has more than 64 required/defaulted fields — " &
            "make some Option[T] / {.kdlSkip.}, or split the type")
    result = nextSlot
    # A defaulted field (required = false) still claims a slot so seenSym
    # tracks whether it appeared — but its bit stays OUT of requiredMask, so
    # its absence is not a missing-required error (it gets the default instead).
    if required:
      requiredMask = requiredMask or (1'u64 shl result)
    inc nextSlot

  proc isOptionalKdlArgOrProp(typ: NimNode): bool =
    isOptionType(typ)

  # Pre-allocate slots in declaration order. Discriminator field doesn't
  # need a required-slot — the case-object machinery itself ensures the
  # discriminator is set; the cursor either provided it or the decode
  # already errored at the type level. A field carrying a native default
  # (S5) claims a non-required slot and registers in `defaultedFields`
  # (top-level only — branch defaults apply inside the per-branch path).
  proc hasDefault(d: NimNode): bool = d != nil and d.kind != nnkEmpty
  var argSlots: seq[int]
  for af in argFields:
    if isOptionalKdlArgOrProp(af.typ) or (hasVariant and af.name == discName):
      argSlots.add(-1)
    elif hasDefault(af.default):
      let s = claimSlot(required = false)
      argSlots.add(s)
      if not af.isBranchField:
        defaultedFields.add((slot: s, pathExpr: af.pathExpr,
                             defaultExpr: af.default))
    else:
      let s = claimSlot(required = true)
      argSlots.add(s)
      requiredSlotKeys.add((slot: s, wireKey: af.name))  # positional → field name
  var propSlots: seq[int]
  for pf in propFields:
    if isOptionalKdlArgOrProp(pf.typ) or (hasVariant and pf.name == discName):
      propSlots.add(-1)
    elif hasDefault(pf.default):
      let s = claimSlot(required = false)
      propSlots.add(s)
      if not pf.isBranchField:
        defaultedFields.add((slot: s, pathExpr: pf.pathExpr,
                             defaultExpr: pf.default))
    else:
      let s = claimSlot(required = true)
      propSlots.add(s)
      requiredSlotKeys.add((slot: s, wireKey: pf.wireKey))
  var childSlots: seq[int]
  for cf in childFields:
    if cf.kind in {ckSeq, ckOption}:
      childSlots.add(-1)  # empty seq / absent Option is fine
    elif hasDefault(cf.default):
      let s = claimSlot(required = false)
      childSlots.add(s)
      if not cf.isBranchField:
        defaultedFields.add((slot: s, pathExpr: cf.pathExpr,
                             defaultExpr: cf.default))
    else:
      let s = claimSlot(required = true)
      childSlots.add(s)
      requiredSlotKeys.add((slot: s, wireKey: cf.wireName))

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

  # S4: an unknown prop key. Strict by default; under {.kdlIgnoreUnknown.}
  # the ceProp event (key + value) is already consumed by the loop's advance,
  # so ignoring is a no-op that falls through to the next event. Built fresh
  # per call site (the same node is spliced into several else branches).
  proc unknownProp(): NimNode =
    if ignoreUnknown:
      newStmtList(quote do: discard)
    else:
      quote do:
        return err[void, ParseError](
          initError(peTypeUnknownField, `evSym2`.span,
                    "unknown property"))

  proc buildPropIf(fields: seq[PropField], slots: seq[int]): NimNode =
    ## ≤8 fields → bytesEqLit if-elif chain (compiler-folded inline).
    ## >8 fields with no macro-time hash collisions → case-on-FNV-32
    ## dispatch with bytesEqLit confirmation per branch.
    ##
    ## bytesEqLit takes the literal directly (no lifted-let plumbing);
    ## the macro expands to per-byte compares the compiler folds.
    if fields.len == 0:
      return unknownProp()
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
    # S6 (#41): the FNV perfect-hash table maps ONE key → ONE field and is
    # alias-blind — it has no slot for a field's extra `kdlAlias` keys. The
    # conservative fix is to disable the hash path for the WHOLE type as soon as
    # ANY field carries an alias, falling back to the if-elif chain (which emits
    # an explicit `bytesEqLit` arm per alias). This degrades prop lookup from
    # O(1) hashed dispatch to O(n) linear `bytesEqLit` scanning on a wide
    # aliased type. Acceptable for now; the full fix (folding alias keys into
    # the hash table as additional key→field entries) is tracked as #41.
    if useHash:
      for f in fields:
        if f.aliases.len > 0:
          useHash = false
          break
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
        let confirmed = newTree(nnkIfStmt,
          newTree(nnkElifBranch,
            quote do: bytesEqLit(`cSym`, `evSym2`.propKeyTok, `keyLit`),
            decodeBlock),
          newTree(nnkElse, unknownProp()))
        caseStmt.add(newTree(nnkOfBranch, hLit, confirmed))
      caseStmt.add(newTree(nnkElse, unknownProp()))
      return caseStmt
    # Default: if-elif chain. Each field emits its canonical-key arm, then one
    # extra `bytesEqLit` arm per `kdlAlias` (S6) — all routing to the SAME
    # field decode body. Aliases are exact literals (never convention-renamed).
    var ifNode = newNimNode(nnkIfStmt)
    for i in 0 ..< fields.len:
      let keyLit = newStrLitNode(fields[i].wireKey)
      let cond = quote do: bytesEqLit(`cSym`, `evSym2`.propKeyTok, `keyLit`)
      ifNode.add(newNimNode(nnkElifBranch).add(cond).add(branchBodyFor(i)))
      for alias in fields[i].aliases:
        let aliasLit = newStrLitNode(alias)
        let aCond = quote do: bytesEqLit(`cSym`, `evSym2`.propKeyTok, `aliasLit`)
        ifNode.add(newNimNode(nnkElifBranch).add(aCond).add(branchBodyFor(i)))
    ifNode.add(newNimNode(nnkElse).add(unknownProp()))
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
    # S4: a real ceNodeBegin matching no kdlChild field. Strict by default
    # (peTypeUnknownField); skip()'d only under {.kdlIgnoreUnknown.}. The
    # separate slashdash branch in the caller is unaffected.
    let unknownChild =
      if ignoreUnknown:
        quote do: skip(`cSym`)
      else:
        quote do:
          return err[void, ParseError](
            initError(peTypeUnknownField, `childPeekSym`.span,
                      "unknown child node"))
    rootIf.add(newNimNode(nnkElse).add(unknownChild))
    childDispatchBody = rootIf
  else:
    # No kdlChild fields: any child node is unknown. Same strict-by-default
    # rule as the unmatched-else above.
    childDispatchBody =
      if ignoreUnknown:
        quote do: skip(`cSym`)
      else:
        quote do:
          return err[void, ParseError](
            initError(peTypeUnknownField, `childPeekSym`.span,
                      "unknown child node"))

  let requiredMaskLit = newLit(requiredMask)
  let wireNameLit = newStrLitNode(wireName)

  # S5: name the first unset required field by its WIRE key (post-rename).
  # `__missing` is computed by an if-elif scan over required slots in slot
  # order; the macro folds the per-slot bit test. Falls back to "" only if
  # the scan finds none (unreachable when the mask compare already failed).
  let missingSym = ident("__missing")
  var missingScan = newStmtList()
  block:
    var ifNode = newNimNode(nnkIfStmt)
    for rk in requiredSlotKeys:
      let bit = newLit(1'u64 shl rk.slot)
      let nameLit = newStrLitNode(rk.wireKey)
      let cond = quote do: (`seenSym` and `bit`) == 0'u64
      ifNode.add(newNimNode(nnkElifBranch).add(cond).add(
        newAssignment(missingSym, nameLit)))
    if ifNode.len > 0:
      ifNode.add(newNimNode(nnkElse).add(
        newAssignment(missingSym, newStrLitNode(""))))
      missingScan.add(ifNode)
    else:
      missingScan.add(newAssignment(missingSym, newStrLitNode("")))

  # S5: apply native defaults to top-level fields absent from the wire. By
  # SLOT (each field's own bit), AFTER the required-validation returns (so a
  # genuinely-missing required field still errors first). Branch fields are
  # excluded (assigning an inactive branch's field corrupts the object).
  var defaultApply = newStmtList()
  for f in defaultedFields:
    let bit = newLit(1'u64 shl f.slot)
    let pathExpr = f.pathExpr
    let defExpr = f.defaultExpr
    defaultApply.add(quote do:
      if (`seenSym` and `bit`) == 0'u64:
        `pathExpr` = `defExpr`)

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
      # Required-field validation. Each non-Option / non-seq / non-defaulted
      # field set its bit during decode; if the bitmap doesn't cover the
      # required mask, name the first missing field by its wire key (S5).
      if (`seenSym` and `requiredMaskLit`) != `requiredMaskLit`:
        var `missingSym`: string
        `missingScan`
        return err[void, ParseError](
          initError(peTypeMissingRequired, `evSym`.span,
                    "missing required field '" & `missingSym` & "'"))
      # S5: apply native defaults for any defaulted field absent from the
      # wire (its slot bit stayed unset). Runs only after required-validation
      # passes, so ordering matches the spec (defaults never mask a missing
      # required field).
      `defaultApply`
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
