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
import ./value           # withAnno + KdlValue — kdlScalar encode interchange (rfc §8)
export value             # emitted kdlEncode references withAnno/pushArgV in caller scope
# Pragma identifiers (kdlNode / kdlArg / kdlProp / kdlChild / kdlSkip /
# kdlRename / kdlReserved) live in src/pragmas.nim. We don't import it
# here — the macro only LOOKS at pragmas by name as strings in the AST,
# never references the pragma templates themselves. User code imports
# pragmas to ATTACH them; derive_encode just inspects.

# nodeNameOf / objectRecList / isOptionType / isEnumType /
# isObjectTypeResolved now live in derive_common (S0c unification).

proc emitArgPushDirect(pushBody: var NimNode, eSym, valueExpr: NimNode,
                       fieldType: NimNode, annoLit: NimNode,
                       scalar: bool = false) =
  ## Inner of the arg-push dispatch: emit the typed push for an
  ## already-resolved value expression. `annoLit` is a string literal
  ## node ("" for "no annotation", non-empty for kdlReserved tags) —
  ## inlined at macro time so the emitter's bareword/quoted decider
  ## runs once per push call site, not per encode call.
  if scalar:
    # kdlScalar: the user's `kdlEncodeValue(x): KdlValue` hook returns a typed
    # interchange value (rfc §8) — pushed via the value-typed `pushArgV`, not
    # handed the live emitter (a framing-corruption footgun). A non-empty
    # `annoLit` (kdlReserved tag) is layered onto the value's typeAnnotation.
    pushBody.add quote do:
      `eSym`.pushArgV(withAnno(kdlEncodeValue(`valueExpr`), `annoLit`))
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
      `eSym`.pushPropV(`keyLit`, withAnno(kdlEncodeValue(`valueExpr`), `annoLit`))
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
  # S2b: type-level {.kdlRenameAll: kcX.} convention string (or "" if
  # absent), threaded into every prop key via wireKeyOf. Node name above
  # is independent.
  let typeConvention = typeConventionOf(typeSym)
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
  # The single {.kdlVariadic.} field (rfc S1). Required invariant: the fixed
  # {.kdlArg.} fields emit FIRST (in declaration order), then the variadic
  # elements. We enforce the variadic field is declared after every fixed
  # kdlArg field, else declaration-order emission would interleave args and
  # corrupt the decode round-trip.
  var hasVariadic = false
  var variadicName: string
  var variadicElemType: NimNode = nil
  var sawArgAfterVariadic = false
  var variadicSeen = false
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
    # Wire key (for kdlProp): kdlRename wins, else the type-level
    # convention is applied to the field name (S2b, §3.5.3).
    let wireKey = wireKeyOf(fieldName, pragmas, typeConvention)
    let scalar = hasPragma(pragmas, "kdlScalar")
    let isSeqField =
      fieldType.kind == nnkBracketExpr and fieldType[0].eqIdent("seq")
    # S7: {.kdlSkipEncode.} (explicit, NOT via {.kdlSkip.}) on a positional
    # {.kdlArg.} field is a compile error — dropping one arg shifts every later
    # arg index, silently corrupting round-trips on decode (§3.5.5.1). The
    # symmetric {.kdlSkip.} (both directions) is allowed: the positional simply
    # vanishes from the wire in both directions, so nothing shifts.
    if hasPragma(pragmas, "kdlSkipEncode") and not hasPragma(pragmas, "kdlSkip") and
       hasPragma(pragmas, "kdlArg"):
      error("{.kdlSkipEncode.} on positional-arg field '" & fieldName &
            "' would shift arg indices and corrupt round-trips. Use {.kdlSkip.}.")
    # S7: {.kdlSkipEncode.} or {.kdlSkip.} excludes the field from encode — emit
    # nothing. (For a kdlArg this is reachable only via {.kdlSkip.}; the explicit
    # skipEncode+kdlArg combo errored just above.)
    if hasPragma(pragmas, "kdlSkipEncode") or hasPragma(pragmas, "kdlSkip"):
      return
    if hasPragma(pragmas, "kdlVariadic"):
      # Mirror decode's guards (rfc §3.5.5.1) so a misuse fails the same way
      # in either direction.
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
      variadicSeen = true
      variadicName = fieldName
      variadicElemType = elemT
      return
    if hasPragma(pragmas, "kdlArg") and isSeqField:
      error("{.kdlArg.} on a seq field '" & fieldName &
            "' consumes only one argument. Did you mean {.kdlVariadic.}?")
    if hasPragma(pragmas, "kdlArg"):
      if variadicSeen: sawArgAfterVariadic = true
      emitArgPush(targetBody, vSym, eSym, fieldName, fieldType, annoLit, scalar)
    elif hasPragma(pragmas, "kdlProp") or
         (scalar and not hasPragma(pragmas, "kdlChild")):
      # bare kdlScalar defaults to a prop (key = field name), symmetric
      # with the decode classifier.
      emitPropPush(targetBody, vSym, eSym, fieldName, wireKey, fieldType,
                   annoLit, scalar)
    elif hasPragma(pragmas, "kdlChild"):
      if fieldType.kind == nnkBracketExpr and fieldType[0].eqIdent("seq"):
        childFields.add((name: fieldName, typ: fieldType[1], kind: ckSeq))
      elif isOptionType(fieldType):
        childFields.add((name: fieldName, typ: innerOfOption(fieldType),
                         kind: ckOption))
      else:
        childFields.add((name: fieldName, typ: fieldType, kind: ckSingle))
    else:
      # No routing pragma — infer the slot from the field type (rfc §8.2 /
      # S0c), MIRRORING decode's classify exactly. Previously this fell
      # through with no else-branch, silently dropping the field from encode.
      var ft = fieldType
      if isOptionType(ft): ft = innerOfOption(ft)   # Option[X] inherits X's routing
      if ft.kind == nnkBracketExpr and ft[0].eqIdent("seq"):
        if isObjectTypeResolved(ft[1]):
          childFields.add((name: fieldName, typ: ft[1], kind: ckSeq))
        else:
          error("deriveEncode: cannot infer a KDL slot for seq field '" &
                fieldName & "' of primitive elements — annotate it with " &
                "{.kdlArg.} (variadic args) or {.kdlChild.}")
      elif isObjectTypeResolved(ft):
        # Option[object] infers to an optional child (absent → nothing);
        # plain object infers to a single child.
        let kind = if isOptionType(fieldType): ckOption else: ckSingle
        childFields.add((name: fieldName, typ: ft, kind: kind))
      else:
        # primitive / enum (incl. Option[primitive]) → prop; key = field name.
        emitPropPush(targetBody, vSym, eSym, fieldName, wireKey, fieldType,
                     annoLit, scalar)
  let topRecList = objectRecList(typeSym)
  # Plain non-variant fields first (in declaration order).
  for (fieldName, fieldType, pragmas, _) in regularFields(topRecList):
    dispatchField(fieldName, fieldType, pragmas, body)
  # Required invariant (rfc S1): a {.kdlArg.} declared after the {.kdlVariadic.}
  # would emit between the variadic elements on the wire — corrupting the
  # round-trip (decode binds the fixed args by position first). Reject it.
  if sawArgAfterVariadic:
    error("{.kdlArg.} field declared after the {.kdlVariadic.} field '" &
          variadicName & "' would shift positional indices and corrupt " &
          "round-trips. Declare every fixed {.kdlArg.} field before the " &
          "variadic field.")
  # Emit the variadic tail: fixed args are already in `body` (declaration
  # order); now append each variadic element as a positional push.
  if hasVariadic:
    let varIdent = ident(variadicName)
    let elemSym = genSym(nskForVar, "varg")
    var elemPush = newStmtList()
    emitArgPushDirect(elemPush, eSym, elemSym, variadicElemType,
                      newStrLitNode(""))
    body.add quote do:
      for `elemSym` in `vSym`.`varIdent`:
        `elemPush`
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
        for (fName, fType, fPragmas, _) in regularFields(branchRecList):
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
