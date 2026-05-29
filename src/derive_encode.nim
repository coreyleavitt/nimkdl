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
  let impl = typeSym.getImpl
  expectKind(impl, nnkTypeDef)
  # impl is `Type{.pragmas.} = ObjectTy(...)` — pragmas hang off the
  # name section's pragma child.
  let nameNode = impl[0]
  if nameNode.kind == nnkPragmaExpr:
    let pragmas = nameNode[1]
    for p in pragmas:
      if p.kind == nnkCall and p.len == 2 and $p[0] == "kdlNode":
        return p[1].strVal
  # Fallback: type-name lowercased.
  result = $typeSym
  for i in 0 ..< result.len:
    if result[i] in {'A' .. 'Z'}:
      result[i] = char(uint8(result[i]) + 32)

iterator objectFields(typeSym: NimNode): tuple[name: string, typ: NimNode,
                                               pragmas: seq[NimNode]] =
  ## Walk the field list of T's object type, yielding (name, type, pragma-seq)
  ## for each field. Pragmas come from the field's IdentDefs[0] = PragmaExpr
  ## branch.
  let impl = typeSym.getImpl
  let objTy =
    if impl[2].kind == nnkObjectTy: impl[2]
    elif impl[2].kind == nnkRefTy and impl[2][0].kind == nnkObjectTy: impl[2][0]
    else: nil
  doAssert objTy != nil, "deriveEncode: expected an object or ref object type"
  let recList = objTy[2]
  for identDefs in recList:
    let fieldType = identDefs[^2]
    for i in 0 ..< identDefs.len - 2:
      let fieldNameNode = identDefs[i]
      var name: string
      var pragmas: seq[NimNode]
      if fieldNameNode.kind == nnkPragmaExpr:
        name = $fieldNameNode[0]
        for p in fieldNameNode[1]:
          pragmas.add(p)
      else:
        name = $fieldNameNode
      yield (name: name, typ: fieldType, pragmas: pragmas)

proc hasPragma(pragmas: seq[NimNode], name: string): bool =
  for p in pragmas:
    let head = if p.kind == nnkCall: p[0] else: p
    if $head == name: return true
  false

proc emitArgPush(pushBody: var NimNode, vSym: NimNode, eSym: NimNode,
                 fieldName: string, fieldType: NimNode) =
  ## Append a `pushArg*` call appropriate to the field's static type.
  ## Stage C1 handles `string` only; subsequent cycles widen the
  ## type universe.
  let fieldIdent = ident(fieldName)
  case $fieldType
  of "string":
    pushBody.add quote do:
      `eSym`.pushArgString(`vSym`.`fieldIdent`)
  else:
    error("deriveEncode (Stage C1): kdlArg field type " & $fieldType &
          " not yet supported")

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
  for (fieldName, fieldType, pragmas) in objectFields(typeSym):
    if hasPragma(pragmas, "kdlArg"):
      emitArgPush(body, vSym, eSym, fieldName, fieldType)
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
