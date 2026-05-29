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
## bytesEq, tokenAsString) lives on StringCursor rather than the
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

import std/macros

import std/options  # the emitted decoder constructs `some(value)` for Option[T] fields
export options       # so user code doesn't need to import options separately

import ./ast
import ./cursor
import ./doc_build  # tokenAsString — single source of truth for token → string
import ./lexer      # TokenKind / KeywordKind dispatch in emitted code
import ./numlit     # decodeIntFromToken / decodeFloatFromToken
import ./spans

# Re-export the substrate identifiers the emitted decoder body references
# (Result, ParseError, ok, err, initError, peTypeMismatch, etc., plus the
# cursor/lexer token-kind enum cases). Without these the caller would need
# to import every substrate module by hand.
export ast, cursor, doc_build, lexer, numlit, spans

# ---------------------------------------------------------------------------
# Shared AST inspection helpers (mirror those in derive_encode)
# ---------------------------------------------------------------------------

proc pragmaHead(p: NimNode): NimNode {.inline.} =
  if p.kind in {nnkCall, nnkExprColonExpr}: p[0]
  else: p

proc hasPragma(pragmas: seq[NimNode], name: string): bool =
  for p in pragmas:
    if $pragmaHead(p) == name: return true
  false

proc pragmaArg(pragmas: seq[NimNode], name: string): NimNode =
  for p in pragmas:
    if $pragmaHead(p) == name and
       p.kind in {nnkCall, nnkExprColonExpr} and p.len >= 2:
      return p[1]
  nil

proc nodeNameOf(typeSym: NimNode): string =
  ## Read `kdlNode: "name"` pragma or fall back to lowercased type name.
  let impl = typeSym.getImpl
  expectKind(impl, nnkTypeDef)
  let nameNode = impl[0]
  if nameNode.kind == nnkPragmaExpr:
    let pragmas = nameNode[1]
    for p in pragmas:
      let head = pragmaHead(p)
      if $head == "kdlNode" and
         p.kind in {nnkCall, nnkExprColonExpr} and p.len >= 2 and
         p[1].kind == nnkStrLit:
        return p[1].strVal
  result = $typeSym
  for i in 0 ..< result.len:
    if result[i] in {'A'..'Z'}:
      result[i] = char(uint8(result[i]) + 32)

proc fieldInfo(identDefs: NimNode, fieldIdx: int):
    tuple[name: string, pragmas: seq[NimNode]] =
  let fieldNameNode = identDefs[fieldIdx]
  if fieldNameNode.kind == nnkPragmaExpr:
    result.name = $fieldNameNode[0]
    for p in fieldNameNode[1]:
      result.pragmas.add(p)
  else:
    result.name = $fieldNameNode

iterator regularFields(recList: NimNode):
    tuple[name: string, typ: NimNode, pragmas: seq[NimNode]] =
  for child in recList:
    if child.kind != nnkIdentDefs: continue
    let fieldType = child[^2]
    for i in 0 ..< child.len - 2:
      let info = fieldInfo(child, i)
      yield (name: info.name, typ: fieldType, pragmas: info.pragmas)

proc objectRecList(typeSym: NimNode): NimNode =
  let impl = typeSym.getImpl
  let objTy =
    if impl[2].kind == nnkObjectTy: impl[2]
    elif impl[2].kind == nnkRefTy and impl[2][0].kind == nnkObjectTy: impl[2][0]
    else: nil
  doAssert objTy != nil, "deriveDecode: expected an object or ref object type"
  objTy[2]

proc findRecCase(recList: NimNode): NimNode =
  for child in recList:
    if child.kind == nnkRecCase: return child
  nil

# ---------------------------------------------------------------------------
# Macro
# ---------------------------------------------------------------------------

proc isOptionType(t: NimNode): bool {.inline.} =
  t.kind == nnkBracketExpr and $t[0] == "Option"

proc innerOfOption(t: NimNode): NimNode {.inline.} =
  t[1]

proc isEnumType(t: NimNode): bool =
  if t.kind == nnkEnumTy: return true
  try:
    let impl = t.getTypeImpl
    if impl.kind == nnkEnumTy: return true
    if impl.kind == nnkBracketExpr and impl.len >= 2 and $impl[0] == "typeDesc":
      let innerImpl = impl[1].getTypeImpl
      if innerImpl.kind == nnkEnumTy: return true
  except: discard
  false

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

proc emitTypedDecode(targetIdent: NimNode, tokIndexExpr: NimNode,
                     fieldType: NimNode, cSym: NimNode): NimNode =
  ## Emit the typed decode of a token at `tokIndexExpr` into
  ## `targetIdent`. Used by both arg-positional dispatch and
  ## prop-by-key dispatch. For Option[T], decode the inner T and
  ## wrap the result in `some(...)`. For plain T, assign directly.
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
  case $fieldType
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
      let nPayload = `cSym`.stream[].numberPayloads[tok.numIdx]
      let decoded = decodeIntFromToken(nPayload, tok.span)
      if decoded.isErr:
        return err[void, ParseError](decoded.getErr)
      `targetIdent` = `typeNode`(decoded.get)
  of "float", "float32", "float64":
    let typeNode = fieldType
    return quote do:
      let tok = `cSym`.stream[].tokens[`tokIndexExpr`]
      case tok.kind
      of tkNumber:
        let nPayload = `cSym`.stream[].numberPayloads[tok.numIdx]
        let decoded = decodeFloatFromToken(nPayload, tok.span)
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
  let vSym = ident("v")
  let cSym = ident("c")
  let evSym = ident("ev")
  let evSym2 = ident("ev2")
  let argIdxSym = ident("argIdx")

  # Collect kdlArg + kdlProp + kdlChild fields by pragma role.
  type ChildKind = enum ckSingle, ckSeq
  type ArgField = tuple[name: string, typ: NimNode, reservedTag: string]
  type PropField = tuple[name: string, typ: NimNode, wireKey: string,
                         reservedTag: string]
  type ChildField = tuple[name: string, elemType: NimNode,
                          kind: ChildKind, wireName: string]
  var argFields: seq[ArgField]
  var propFields: seq[PropField]              # plain (non-variant) props
  var childFields: seq[ChildField]            # plain children
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
                childSink: var seq[ChildField]) =
    let reservedArg = pragmaArg(pragmas, "kdlReserved")
    let reservedTag =
      if reservedArg != nil and reservedArg.kind == nnkStrLit:
        reservedArg.strVal
      else: ""
    if hasPragma(pragmas, "kdlArg"):
      argSink.add((name: fieldName, typ: fieldType, reservedTag: reservedTag))
    elif hasPragma(pragmas, "kdlProp"):
      let renameArg = pragmaArg(pragmas, "kdlRename")
      let wireKey =
        if renameArg != nil and renameArg.kind == nnkStrLit:
          renameArg.strVal
        else: fieldName
      propSink.add((name: fieldName, typ: fieldType, wireKey: wireKey,
                    reservedTag: reservedTag))
    elif hasPragma(pragmas, "kdlChild"):
      var kind: ChildKind
      var elemType: NimNode
      if fieldType.kind == nnkBracketExpr and $fieldType[0] == "seq":
        kind = ckSeq
        elemType = fieldType[1]
      else:
        kind = ckSingle
        elemType = fieldType
      childSink.add((name: fieldName, elemType: elemType, kind: kind,
                     wireName: nodeNameOf(elemType)))

  let recList = objectRecList(typeSym)
  for (fieldName, fieldType, pragmas) in regularFields(recList):
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
        for (bf, bt, bp) in regularFields(branchRecList):
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
    result = nextSlot
    if result < 64:
      requiredMask = requiredMask or (1'u64 shl result)
    inc nextSlot

  proc isOptionalKdlArgOrProp(typ: NimNode): bool =
    isOptionType(typ)

  # Pre-allocate slots in declaration order. Discriminator field doesn't
  # need a required-slot — the case-object machinery itself ensures the
  # discriminator is set; the cursor either provided it or the decode
  # already errored at the type level.
  var argSlots: seq[int]
  for (fName, fType, _) in argFields:
    if isOptionalKdlArgOrProp(fType) or (hasVariant and fName == discName):
      argSlots.add(-1)
    else:
      argSlots.add(claimSlot())
  var propSlots: seq[int]
  for (fName, fType, _, _) in propFields:
    if isOptionalKdlArgOrProp(fType) or (hasVariant and fName == discName):
      propSlots.add(-1)
    else:
      propSlots.add(claimSlot())
  var childSlots: seq[int]
  for (_, _, kind, _) in childFields:
    if kind == ckSeq:
      childSlots.add(-1)  # empty seq is fine
    else:
      childSlots.add(claimSlot())

  proc markSlot(slot: int): NimNode =
    if slot < 0:
      newStmtList()
    else:
      let bit = newLit(1'u64 shl slot)
      quote do:
        `seenSym` = `seenSym` or `bit`

  # Build the proc-entry let bindings for keys + reserved tags BEFORE
  # the dispatch loops so the dispatch can reference them.
  # bytesEq's `unsafeAddr s[0]` needs an addressable location; each
  # literal is lifted to a `let` at proc entry once.
  var propKeyLets = newStmtList()
  var propKeySyms: seq[NimNode]
  for (_, _, wireKey, _) in propFields:
    let sym = genSym(nskLet, "expectedPropKey")
    let lit = newStrLitNode(wireKey)
    propKeyLets.add(quote do:
      let `sym` = `lit`)
    propKeySyms.add(sym)
  var branchPropKeySyms: seq[seq[NimNode]]
  for (_, props) in branchProps:
    var syms: seq[NimNode]
    for (_, _, wireKey, _) in props:
      let sym = genSym(nskLet, "expectedBranchPropKey")
      let lit = newStrLitNode(wireKey)
      propKeyLets.add(quote do:
        let `sym` = `lit`)
      syms.add(sym)
    branchPropKeySyms.add(syms)
  var argReservedSyms: seq[NimNode]
  for (_, _, reservedTag) in argFields:
    if reservedTag.len == 0:
      argReservedSyms.add(nil)
    else:
      let sym = genSym(nskLet, "expectedArgTag")
      let lit = newStrLitNode(reservedTag)
      propKeyLets.add(quote do:
        let `sym` = `lit`)
      argReservedSyms.add(sym)
  var propReservedSyms: seq[NimNode]
  for (_, _, _, reservedTag) in propFields:
    if reservedTag.len == 0:
      propReservedSyms.add(nil)
    else:
      let sym = genSym(nskLet, "expectedPropTag")
      let lit = newStrLitNode(reservedTag)
      propKeyLets.add(quote do:
        let `sym` = `lit`)
      propReservedSyms.add(sym)

  # Build the per-arg dispatch.
  var argCase = newTree(nnkCaseStmt, argIdxSym)
  for i, (fName, fType, _) in argFields:
    let fIdent = ident(fName)
    let idxLit = newIntLitNode(i)
    let tokIndexExpr = quote do: `evSym2`.argTok
    let target = quote do: `vSym`.`fIdent`
    var branchBody = emitTypedDecode(target, tokIndexExpr, fType, cSym)
    if hasVariant and fName == discName:
      let bodyCopy = branchBody
      branchBody = quote do:
        {.cast(uncheckedAssign).}:
          `bodyCopy`
    let mark = markSlot(argSlots[i])
    # kdlReserved tag check (if declared). Verify the cursor event's
    # arg-annotation matches the declared tag; mismatch → error.
    let tagSym = argReservedSyms[i]
    var reservedCheck = newStmtList()
    if tagSym != nil:
      reservedCheck = quote do:
        if `evSym2`.argAnnoTok < 0 or
           not bytesEq(`cSym`, `evSym2`.argAnnoTok, `tagSym`):
          return err[void, ParseError](
            initError(peTypeReservedMismatch, `evSym2`.span,
                      "expected (" & `tagSym` & ") annotation on value"))
    branchBody = quote do:
      `reservedCheck`
      `branchBody`
      `mark`
    argCase.add(newTree(nnkOfBranch, idxLit, branchBody))
  argCase.add(newTree(nnkElse,
    quote do:
      return err[void, ParseError](
        initError(peParseUnexpected, `evSym2`.span,
                  "unexpected extra positional argument"))))

  # Same lift for child wire-names — bytesEq against an addressable let.
  var childKeyLets = newStmtList()
  var childKeySyms: seq[NimNode]
  for (_, _, _, wireName) in childFields:
    let sym = genSym(nskLet, "expectedChildName")
    let lit = newStrLitNode(wireName)
    childKeyLets.add(quote do:
      let `sym` = `lit`)
    childKeySyms.add(sym)
  # Helper: build an if-elif-else for a list of (PropField, keySym, slot)
  # tuples. The slot-bit marker is appended to each branch's body so
  # the required-field check sees the prop as satisfied.
  proc buildPropIf(fields: seq[PropField], keys: seq[NimNode],
                   slots: seq[int], tags: seq[NimNode]): NimNode =
    if fields.len == 0:
      return quote do:
        return err[void, ParseError](
          initError(peTypeUnknownField, `evSym2`.span,
                  "unknown property"))
    var ifNode = newNimNode(nnkIfStmt)
    for i, (fName, fType, _, _) in fields:
      let fIdent = ident(fName)
      let keySym = keys[i]
      let tokIndexExpr = quote do: `evSym2`.propValueTok
      let target = quote do: `vSym`.`fIdent`
      let decodeBody = emitTypedDecode(target, tokIndexExpr, fType, cSym)
      let mark = markSlot(slots[i])
      let tagSym = tags[i]
      var reservedCheck = newStmtList()
      if tagSym != nil:
        reservedCheck = quote do:
          if `evSym2`.propAnnoTok < 0 or
             not bytesEq(`cSym`, `evSym2`.propAnnoTok, `tagSym`):
            return err[void, ParseError](
              initError(peTypeReservedMismatch, `evSym2`.span,
                        "expected (" & `tagSym` & ") annotation on value"))
      let fullBody = quote do:
        `reservedCheck`
        `decodeBody`
        `mark`
      let cond = quote do: bytesEq(`cSym`, `evSym2`.propKeyTok, `keySym`)
      ifNode.add(newNimNode(nnkElifBranch).add(cond).add(fullBody))
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
      var branchTags: seq[NimNode]
      for _ in props:
        branchSlots.add(-1)
        branchTags.add(nil)  # kdlReserved on branch fields not yet wired
      let perBranchIf = buildPropIf(props, branchPropKeySyms[i],
                                    branchSlots, branchTags)
      caseStmt.add(newTree(nnkOfBranch, branchVal, perBranchIf))
    propDispatch.add(caseStmt)
  else:
    propDispatch.add(buildPropIf(propFields, propKeySyms, propSlots,
                                 propReservedSyms))

  # Build the per-child dispatch (used inside the ceChildrenBegin loop).
  let nextEvSym = ident("nextEv")
  let childPeekSym = ident("childPeek")
  var childDispatchBody: NimNode
  if childFields.len > 0:
    var rootIf: NimNode = nil
    for i, (fName, _, kind, _) in childFields:
      let fIdent = ident(fName)
      let keySym = childKeySyms[i]
      let cond = quote do:
        bytesEq(`cSym`, `childPeekSym`.nodeNameTok, `keySym`)
      let mark = markSlot(childSlots[i])
      let body =
        case kind
        of ckSingle:
          quote do:
            let r = kdlDecode(`vSym`.`fIdent`, `cSym`)
            if r.isErr: return r
            `mark`
        of ckSeq:
          let elemSym = genSym(nskVar, "childElem")
          let elemType = childFields[i].elemType
          quote do:
            var `elemSym`: `elemType`
            let r = kdlDecode(`elemSym`, `cSym`)
            if r.isErr: return r
            `vSym`.`fIdent`.add(`elemSym`)
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
  let body = quote do:
    block:
      `propKeyLets`
      `childKeyLets`
      var `seenSym`: uint64 = 0
      let `evSym` = advance(`cSym`)
      if `evSym`.kind == ceError:
        return err[void, ParseError](`evSym`.err)
      if `evSym`.kind != ceNodeBegin:
        return err[void, ParseError](
          initError(peParseExpected, `evSym`.span,
                    "expected node begin"))
      let expectedNodeName = `wireName`
      if not bytesEq(`cSym`, `evSym`.nodeNameTok, expectedNodeName):
        return err[void, ParseError](
          initError(peParseExpected, `evSym`.span,
                    "expected node named '" & expectedNodeName & "'"))
      var `argIdxSym` = 0
      while true:
        let `evSym2` = advance(`cSym`)
        case `evSym2`.kind
        of ceArg:
          `argCase`
          inc `argIdxSym`
        of ceProp:
          `propDispatch`
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
            of ceEof:
              return err[void, ParseError](
                initError(peParseExpected, `childPeekSym`.span,
                          "unexpected EOF in children block"))
            of ceError:
              discard advance(`cSym`)
              return err[void, ParseError](`childPeekSym`.err)
            else:
              discard advance(`cSym`)
        of ceNodeEnd:
          break
        of ceError:
          return err[void, ParseError](`evSym2`.err)
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
