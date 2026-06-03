## derive_encode — per-type macro emitting `kdlEncode(v, e)` procs.
##
## The Cat 2 OUT codegen path. `deriveEncode(T)` inspects T's structure
## at compile time and emits a proc specialized to T's specific
## field shape, calling the established `pushArg* / pushProp* /
## pushChild*` API on a `BufferEmitter`.
##
## ## Why per-type codegen (perf-first framing)
##
## The macro is justified because it emits *shape-specialized* code
## for each user type — direct typed pushes (no KdlValue allocation),
## inlined pragma-derived bytes (no runtime pragma lookup), and field
## ordering known at compile time. A generic `kdlEncode[T]` walking
## `fieldPairs` would give the optimizer the same monomorphized code
## *if* it could see through every layer — but the macro guarantees
## the laydown without optimizer luck.
##
## ## Target type — concrete BufferEmitter
##
## Emitted procs take `var BufferEmitter` concretely, not generic
## `[E: KdlEmitter]`. The typed-primitive push surface (pushArgInt,
## pushArgString, etc.) lives outside the KdlEmitter concept so
## tracing/size impls aren't forced to handle every value kind. If a
## use case for codegen-against-tracing-emitter emerges, extract a
## `KdlValueEmitter` sub-concept then.
##
## ## Stage C buildout
##
## - C1: tracer — one kdlArg string field
## - C2-C10: per docs/branch-rebuild-plan.md

import std/macros

import ./derive_common  # shared macro helpers (rfc-derive-vocabulary.md S0a)
import ./emitter
# Pragma identifiers (kdlNode / kdlArg / kdlProp / kdlChild / kdlSkip /
# kdlRename / kdlReserved) live in src/pragmas.nim. We don't import it
# here — the macro only LOOKS at pragmas by name as strings in the AST,
# never references the pragma templates themselves. User code imports
# pragmas to ATTACH them; derive_encode just inspects.

proc nodeNameOf(typeSym: NimNode): string =
  ## Read the `kdlNode` pragma value off the type's pragma list, or
  ## fall back to the type name lowercased. Type-level pragmas live
  ## on the TypeDef's pragma node (TypeDef.0 if pragmas attached).
  ##
  ## The pragma `{.kdlNode: "name".}` parses as `ExprColonExpr(kdlNode,
  ## "name")` inside the pragma list — NOT as a Call. (`{.kdlNode("name").}`
  ## with parens would be a Call, but the colon form is idiomatic.)
  let impl = typeSym.getImpl
  expectKind(impl, nnkTypeDef)
  let nameNode = impl[0]
  if nameNode.kind == nnkPragmaExpr:
    let pragmas = nameNode[1]
    for p in pragmas:
      let head = if p.kind in {nnkCall, nnkExprColonExpr}: p[0] else: p
      let arg  = if p.kind in {nnkCall, nnkExprColonExpr} and p.len >= 2:
                   p[1] else: nil
      if $head == "kdlNode" and arg != nil and arg.kind == nnkStrLit:
        return arg.strVal
  # Fallback: type-name lowercased.
  result = $typeSym
  for i in 0 ..< result.len:
    if result[i] in {'A' .. 'Z'}:
      result[i] = char(uint8(result[i]) + 32)

proc objectRecList(typeSym: NimNode): NimNode =
  let impl = typeSym.getImpl
  let objTy =
    if impl[2].kind == nnkObjectTy: impl[2]
    elif impl[2].kind == nnkRefTy and impl[2][0].kind == nnkObjectTy: impl[2][0]
    else: nil
  doAssert objTy != nil, "deriveEncode: expected an object or ref object type"
  objTy[2]

proc isOptionType(t: NimNode): bool {.inline.} =
  ## Detect `Option[T]` by AST shape: BracketExpr with head `Option`.
  t.kind == nnkBracketExpr and $t[0] == "Option"

proc isEnumType(t: NimNode): bool =
  ## True iff `t`'s underlying type is an enum.
  ##
  ## Inputs may arrive as:
  ##   - The enum AST itself (nnkEnumTy) — direct hit
  ##   - A type symbol that resolves to nnkEnumTy via getTypeImpl
  ##   - A `typeDesc[T]` wrapper (this happens when `t` is the inner
  ##     of a BracketExpr like `Option[E]` — getTypeImpl returns
  ##     `typeDesc[E]` rather than E's impl). Unwrap and re-resolve.
  if t.kind == nnkEnumTy: return true
  var impl: NimNode
  try:
    impl = t.getTypeImpl
  except:
    return false
  if impl.kind == nnkEnumTy: return true
  if impl.kind == nnkBracketExpr and impl.len >= 2 and
     $impl[0] == "typeDesc":
    try:
      let innerImpl = impl[1].getTypeImpl
      if innerImpl.kind == nnkEnumTy: return true
    except:
      discard
  false

proc emitArgPushDirect(pushBody: var NimNode, eSym, valueExpr: NimNode,
                       fieldType: NimNode, annoLit: NimNode,
                       scalar: bool = false) =
  ## Inner of the arg-push dispatch: emit the typed push for an
  ## already-resolved value expression. `annoLit` is a string literal
  ## node ("" for "no annotation", non-empty for kdlReserved tags) —
  ## inlined at macro time so the emitter's bareword/quoted decider
  ## runs once per push call site, not per encode call.
  if scalar:
    # kdlScalar: render via the user's `kdlEncodeValue(x): string` hook and
    # push as a string scalar (symmetric with the decode hook).
    pushBody.add quote do:
      `eSym`.pushArgString(kdlEncodeValue(`valueExpr`), `annoLit`)
    return
  case baseTypeName(fieldType)
  of "string":
    pushBody.add quote do:
      `eSym`.pushArgString(`valueExpr`, `annoLit`)
  of "int", "int8", "int16", "int32", "int64":
    pushBody.add quote do:
      `eSym`.pushArgInt(int64(`valueExpr`), `annoLit`)
  of "uint", "uint8", "uint16", "uint32", "uint64":
    pushBody.add quote do:
      `eSym`.pushArgInt(int64(`valueExpr`), `annoLit`)
  of "float", "float32", "float64":
    pushBody.add quote do:
      `eSym`.pushArgFloat(float64(`valueExpr`), `annoLit`)
  of "bool":
    pushBody.add quote do:
      `eSym`.pushArgBool(`valueExpr`, `annoLit`)
  else:
    if isEnumType(fieldType):
      pushBody.add quote do:
        `eSym`.pushArgString($`valueExpr`, `annoLit`)
    else:
      error("deriveEncode: kdlArg field type " & $fieldType &
            " not yet supported (cycles C2/C8 cover string/int/float/" &
            "bool/enum)")

proc emitArgPush(pushBody: var NimNode, vSym: NimNode, eSym: NimNode,
                 fieldName: string, fieldType: NimNode, annoLit: NimNode,
                 scalar: bool = false) =
  ## Append a `pushArg*` call appropriate to the field's static type.
  ## For Option[T], wrap in `if v.field.isSome:` and push the inner
  ## value; None means the field is absent and emits nothing.
  let fieldIdent = ident(fieldName)
  if isOptionType(fieldType):
    let inner = innerOfOption(fieldType)
    var inner_body = newStmtList()
    let getExpr = quote do: get(`vSym`.`fieldIdent`)
    emitArgPushDirect(inner_body, eSym, getExpr, inner, annoLit, scalar)
    let cond = quote do: isSome(`vSym`.`fieldIdent`)
    pushBody.add newIfStmt((cond, inner_body))
  else:
    let fullExpr = quote do: `vSym`.`fieldIdent`
    emitArgPushDirect(pushBody, eSym, fullExpr, fieldType, annoLit, scalar)

proc emitPropPushDirect(pushBody: var NimNode, eSym, keyLit, valueExpr,
                        fieldType, annoLit: NimNode, scalar: bool = false) =
  if scalar:
    pushBody.add quote do:
      `eSym`.pushPropString(`keyLit`, kdlEncodeValue(`valueExpr`), `annoLit`)
    return
  case baseTypeName(fieldType)
  of "string":
    pushBody.add quote do:
      `eSym`.pushPropString(`keyLit`, `valueExpr`, `annoLit`)
  of "int", "int8", "int16", "int32", "int64":
    pushBody.add quote do:
      `eSym`.pushPropInt(`keyLit`, int64(`valueExpr`), `annoLit`)
  of "uint", "uint8", "uint16", "uint32", "uint64":
    pushBody.add quote do:
      `eSym`.pushPropInt(`keyLit`, int64(`valueExpr`), `annoLit`)
  of "float", "float32", "float64":
    pushBody.add quote do:
      `eSym`.pushPropFloat(`keyLit`, float64(`valueExpr`), `annoLit`)
  of "bool":
    pushBody.add quote do:
      `eSym`.pushPropBool(`keyLit`, `valueExpr`, `annoLit`)
  else:
    if isEnumType(fieldType):
      pushBody.add quote do:
        `eSym`.pushPropString(`keyLit`, $`valueExpr`, `annoLit`)
    else:
      error("deriveEncode: kdlProp field type " & $fieldType &
            " not yet supported (cycles C3/C8 cover string/int/float/" &
            "bool/enum)")

proc emitPropPush(pushBody: var NimNode, vSym: NimNode, eSym: NimNode,
                  fieldName: string, wireKey: string,
                  fieldType: NimNode, annoLit: NimNode, scalar: bool = false) =
  ## Append a `pushProp*` call appropriate to the field's static type.
  ## `wireKey` is the bytes used on the wire — `fieldName` by default,
  ## or the kdlRename pragma value when present. Key bytes inline at
  ## macro time. Option[T] wraps in `if isSome:`.
  let fieldIdent = ident(fieldName)
  let keyLit = newStrLitNode(wireKey)
  if isOptionType(fieldType):
    let inner = innerOfOption(fieldType)
    var inner_body = newStmtList()
    let getExpr = quote do: get(`vSym`.`fieldIdent`)
    emitPropPushDirect(inner_body, eSym, keyLit, getExpr, inner, annoLit, scalar)
    let cond = quote do: isSome(`vSym`.`fieldIdent`)
    pushBody.add newIfStmt((cond, inner_body))
  else:
    let fullExpr = quote do: `vSym`.`fieldIdent`
    emitPropPushDirect(pushBody, eSym, keyLit, fullExpr, fieldType, annoLit,
                       scalar)

macro deriveEncode*(T: typedesc): untyped =
  ## Emit `proc kdlEncode*(v: T; e: var BufferEmitter)` specialized to
  ## T's field shape. Each kdlArg field generates a direct typed push;
  ## kdlProp / kdlChild / annotation / variant handling lands in
  ## subsequent cycles.
  let typeSym = T.getTypeInst[1]
  let wireName = nodeNameOf(typeSym)
  let vSym = ident("v")
  let eSym = ident("e")
  var body = newStmtList()
  body.add quote do:
    `eSym`.pushNodeBegin(`wireName`)
  # Two-pass: args and props inline within the node head; children
  # collected for a single ChildrenBegin/End block. The block is
  # conditionally emitted at runtime — if every kdlChild field is a
  # runtime-empty container (seq with len 0, Option with isNone), no
  # `{}` appears in the output. Single nested types always count as
  # present.
  type ChildKind = enum ckSingle, ckSeq, ckOption
  var childFields: seq[tuple[name: string, typ: NimNode, kind: ChildKind]]
  proc dispatchField(fieldName: string, fieldType: NimNode,
                     pragmas: seq[NimNode], targetBody: var NimNode) =
    # Annotation: emit `(tag)` before the value when `{.kdlReserved: ...}`.
    # Tag bytes inlined at macro time — no runtime pragma lookup.
    let annoArg = pragmaArg(pragmas, "kdlReserved")
    let annoLit =
      if annoArg != nil and annoArg.kind == nnkStrLit:
        newStrLitNode(annoArg.strVal)
      else:
        newStrLitNode("")
    # Wire key: kdlRename overrides the field name (for kdlProp).
    let renameArg = pragmaArg(pragmas, "kdlRename")
    let wireKey =
      if renameArg != nil and renameArg.kind == nnkStrLit:
        renameArg.strVal
      else:
        fieldName
    let scalar = hasPragma(pragmas, "kdlScalar")
    if hasPragma(pragmas, "kdlArg"):
      emitArgPush(targetBody, vSym, eSym, fieldName, fieldType, annoLit, scalar)
    elif hasPragma(pragmas, "kdlProp") or
         (scalar and not hasPragma(pragmas, "kdlChild")):
      # bare kdlScalar defaults to a prop (key = field name), symmetric
      # with the decode classifier.
      emitPropPush(targetBody, vSym, eSym, fieldName, wireKey, fieldType,
                   annoLit, scalar)
    elif hasPragma(pragmas, "kdlChild"):
      if fieldType.kind == nnkBracketExpr and $fieldType[0] == "seq":
        childFields.add((name: fieldName, typ: fieldType[1], kind: ckSeq))
      elif isOptionType(fieldType):
        childFields.add((name: fieldName, typ: innerOfOption(fieldType),
                         kind: ckOption))
      else:
        childFields.add((name: fieldName, typ: fieldType, kind: ckSingle))
  let topRecList = objectRecList(typeSym)
  # Plain non-variant fields first (in declaration order).
  for (fieldName, fieldType, pragmas) in regularFields(topRecList):
    dispatchField(fieldName, fieldType, pragmas, body)
  # Variant discriminator + per-branch dispatch.
  let recCase = findRecCase(topRecList)
  if recCase != nil:
    # recCase[0] is the discriminator IdentDefs. Emit the discriminator
    # field itself like a normal kdlArg/kdlProp at its declared position.
    let discDefs = recCase[0]
    let discType = discDefs[^2]
    let (discName, discPragmas) = fieldInfo(discDefs, 0)
    dispatchField(discName, discType, discPragmas, body)
    # Build a `case v.<disc>: of <branchVal>: <branch body>` dispatch.
    # Per-branch fields emit their kdlArg/kdlProp/kdlChild contributions
    # inside the matching branch body.
    let discIdent = ident(discName)
    var caseStmt = newTree(nnkCaseStmt, newDotExpr(vSym, discIdent))
    for i in 1 ..< recCase.len:
      let branch = recCase[i]
      var branchBody = newStmtList()
      let branchRecList =
        if branch.kind == nnkOfBranch: branch[^1]
        elif branch.kind == nnkElse:   branch[0]
        else: newEmptyNode()
      if branchRecList.kind == nnkRecList:
        for (fName, fType, fPragmas) in regularFields(branchRecList):
          dispatchField(fName, fType, fPragmas, branchBody)
      if branchBody.len == 0:
        # Empty branches must still appear in the case to be exhaustive.
        branchBody.add newNimNode(nnkDiscardStmt).add(newEmptyNode())
      if branch.kind == nnkOfBranch:
        var ofBranch = newNimNode(nnkOfBranch)
        for j in 0 ..< branch.len - 1:
          ofBranch.add(branch[j])
        ofBranch.add(branchBody)
        caseStmt.add(ofBranch)
      elif branch.kind == nnkElse:
        var elseBranch = newNimNode(nnkElse)
        elseBranch.add(branchBody)
        caseStmt.add(elseBranch)
    body.add(caseStmt)
  if childFields.len > 0:
    # Build the runtime "any present" predicate.
    var anyPresent: NimNode = nil
    for (childName, _, childKind) in childFields:
      let childIdent = ident(childName)
      var term: NimNode
      case childKind
      of ckSingle:
        term = newLit(true)
      of ckSeq:
        term = quote do:
          `vSym`.`childIdent`.len > 0
      of ckOption:
        term = quote do:
          isSome(`vSym`.`childIdent`)
      if anyPresent.isNil: anyPresent = term
      else:                anyPresent = infix(anyPresent, "or", term)
    # Build the children-emit body.
    var childBody = newStmtList()
    childBody.add quote do:
      `eSym`.pushChildrenBegin()
    for (childName, _, childKind) in childFields:
      let childIdent = ident(childName)
      case childKind
      of ckSingle:
        childBody.add quote do:
          kdlEncode(`vSym`.`childIdent`, `eSym`)
      of ckSeq:
        let elemSym = genSym(nskForVar, "child")
        childBody.add quote do:
          for `elemSym` in `vSym`.`childIdent`:
            kdlEncode(`elemSym`, `eSym`)
      of ckOption:
        childBody.add quote do:
          if isSome(`vSym`.`childIdent`):
            kdlEncode(get(`vSym`.`childIdent`), `eSym`)
    childBody.add quote do:
      `eSym`.pushChildrenEnd()
    body.add newIfStmt((anyPresent, childBody))
  body.add quote do:
    `eSym`.pushNodeEnd()
  # Emitted unexported because deriveEncode may be invoked inside a
  # suite / block scope (e.g. test files) where `*` is illegal. Users
  # wanting cross-module export wrap their type + deriveEncode call in
  # their own module and re-export `kdlEncode` from there.
  result = newProc(
    name = newIdentNode("kdlEncode"),
    params = @[newEmptyNode(),
               newIdentDefs(vSym, typeSym),
               newIdentDefs(eSym, nnkVarTy.newTree(ident("BufferEmitter")))],
    body = body
  )
