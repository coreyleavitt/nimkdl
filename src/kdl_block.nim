## kdl_block — the `kdl:` orchestrator macro.
##
## Wraps a region of type definitions. For every type declared with
## `{.kdlNode.}`, emits `deriveEncode(T)` + `deriveDecode(T)`
## immediately after the type section. Non-`{.kdlNode.}` types
## (helpers, enums, sub-records) and non-type statements (imports,
## constants) pass through unchanged.
##
## Both derives are emitted by default. Symmetry is the right default —
## emitting only one direction silently when the user expected both
## is a footgun. The Nim compiler dead-code-elims any unused proc.
##
## A type may opt out of one direction with a type-level pragma:
## `{.kdlEncodeOnly.}` emits only `deriveEncode(T)` (no `kdlDecode`);
## `{.kdlDecodeOnly.}` emits only `deriveDecode(T)` (no `kdlEncode`).
## Carrying both is a compile-time `{.error.}` (contradictory).
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
import ./emitter

# Re-export the substrate symbols the emitted derive bodies reference
# at the user's call site: BufferEmitter / pushArg* / pushProp* etc.
# from emitter; StringCursor + advance + Result/ParseError flow via
# derive_decode's own re-exports. Without these the user would need
# to import them by hand whenever they use a `kdl:` block.
export derive_decode, derive_encode, emitter

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

proc hasTypePragma(typeDef: NimNode; name: string): bool {.compileTime.} =
  ## True iff the typedef's name slot carries a bare `{.name.}` type-level
  ## pragma. Matches both the call-form (`kdlNode: "x"`) and the bare-ident
  ## form (`kdlDecodeOnly`) the marker pragmas use.
  if typeDef[0].kind != nnkPragmaExpr: return false
  for p in typeDef[0][1]:
    case p.kind
    of nnkIdent, nnkSym:
      if $p == name: return true
    of nnkExprColonExpr, nnkCall:
      if p.len >= 1 and $p[0] == name: return true
    else: discard
  false

proc hasKdlNodePragma(typeDef: NimNode): bool {.compileTime.} =
  ## True iff the typedef's name slot carries a `{.kdlNode: "name".}`
  ## pragma — the marker that identifies a type as KDL-mapped.
  hasTypePragma(typeDef, "kdlNode")

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
          let encodeOnly = hasTypePragma(typeDef, "kdlEncodeOnly")
          let decodeOnly = hasTypePragma(typeDef, "kdlDecodeOnly")
          if encodeOnly and decodeOnly:
            error("kdl block: type " & $typeSym &
              " carries both {.kdlEncodeOnly.} and {.kdlDecodeOnly.} — " &
              "contradictory; keep at most one (or neither for both directions)",
              typeDef)
          if not decodeOnly:
            result.add(newCall(bindSym"deriveEncode", typeSym))
          if not encodeOnly:
            result.add(newCall(bindSym"deriveDecode", typeSym))
    else:
      result.add(stmt)

  when defined(dumpKdlGen):
    echo "=== kdl block: output ==="
    echo result.repr
