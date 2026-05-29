## kdl_block — the `kdl:` orchestrator macro.
##
## Wraps a region of type definitions. For every type declared with
## `{.kdlNode.}`, emits `deriveEncode(T)` + `deriveDecode(T)`
## immediately after the type section. Non-`{.kdlNode.}` types
## (helpers, enums, sub-records) and non-type statements (imports,
## constants) pass through unchanged.
##
## Both derives are always emitted. Symmetry is the right default —
## emitting only one direction silently when the user expected both
## is a footgun. The Nim compiler dead-code-elims any unused proc.
##
## ```nim
## kdl:
##   type Service {.kdlNode: "service".} = object
##     name {.kdlArg.}: string
##     port {.kdlProp.}: int
## ```
##
## becomes
##
## ```nim
## type Service {.kdlNode: "service".} = object
##   name {.kdlArg.}: string
##   port {.kdlProp.}: int
## deriveEncode(Service)
## deriveDecode(Service)
## ```

import std/macros

import ./derive_decode
import ./derive_encode

export derive_decode, derive_encode

proc extractKdlTypeSym(typeDef: NimNode): NimNode {.compileTime.} =
  ## Pull the type identifier out of a typedef. Handles bare,
  ## exported (`T*`), and pragma-wrapped (`T {.pragma.}`) name slots.
  let nameNode = typeDef[0]
  case nameNode.kind
  of nnkIdent, nnkSym: nameNode
  of nnkPostfix:       nameNode[1]
  of nnkPragmaExpr:
    let inner = nameNode[0]
    if inner.kind == nnkPostfix: inner[1] else: inner
  else:
    error("kdl block: cannot extract type ident from " & $nameNode.kind, nameNode)
    newEmptyNode()

proc hasKdlNodePragma(typeDef: NimNode): bool {.compileTime.} =
  ## True iff the typedef's name slot carries a `{.kdlNode: "name".}`
  ## pragma — the marker that identifies a type as KDL-mapped.
  if typeDef[0].kind != nnkPragmaExpr: return false
  for p in typeDef[0][1]:
    if p.kind in {nnkExprColonExpr, nnkCall} and p.len >= 2:
      if $p[0] == "kdlNode": return true
  false

macro kdl*(body: untyped): untyped =
  ## Scope a region of KDL type definitions. Every
  ## `type T {.kdlNode: "name".} = object ...` in the block gets
  ## `deriveEncode(T)` + `deriveDecode(T)` emitted after the type
  ## section. Types without `{.kdlNode.}` pass through unchanged.
  result = newStmtList()
  let inner =
    if body.kind == nnkStmtList: body
    else: newStmtList(body)
  for stmt in inner:
    case stmt.kind
    of nnkTypeSection:
      result.add(stmt)
      for typeDef in stmt:
        if typeDef.kind == nnkTypeDef and hasKdlNodePragma(typeDef):
          let typeSym = extractKdlTypeSym(typeDef)
          result.add(newCall(bindSym"deriveEncode", typeSym))
          result.add(newCall(bindSym"deriveDecode", typeSym))
    else:
      result.add(stmt)

  when defined(dumpKdlGen):
    echo "=== kdl block: output ==="
    echo result.repr
