## pda_decode — Phase 4 substrate (per docs/rfc-pda-substrate.md).
##
## Single-pass byte-level fused parser. `derivePDADecode(T)` emits
## a per-T specialized proc that walks the source bytes directly,
## producing a typed `T` with no intermediate lex / cursor / event
## materialization.
##
## Co-existence: lives alongside the cursor-based `src/derive_decode.nim`
## during Phase 4 transition (RFC Q1). Public API `decodePDA[T]`
## parallel to existing `decode[T]`. Cursor path deleted at end of
## Phase 4 Sprint 5.

import std/macros

import ./pragmas
import ./spans

export spans  # Result, ParseError visible to callers without extra import

# ---------------------------------------------------------------------------
# Macro-internal AST inspection
# ---------------------------------------------------------------------------

proc pragmaHead(p: NimNode): NimNode {.compileTime, inline.} =
  if p.kind in {nnkCall, nnkExprColonExpr}: p[0]
  else: p

proc hasPragma(pragmas: seq[NimNode], name: string): bool {.compileTime.} =
  for p in pragmas:
    if $pragmaHead(p) == name: return true
  false

proc nodeNameOf(typeSym: NimNode): string {.compileTime.} =
  ## Read `{.kdlNode: "name".}` off the type's pragma list, fall back
  ## to lower-cased type name. Mirrors derive_decode.nodeNameOf so
  ## ergonomics match (per RFC Q2 silent-swap promise).
  let impl = typeSym.getImpl
  expectKind(impl, nnkTypeDef)
  let nameNode = impl[0]
  if nameNode.kind == nnkPragmaExpr:
    for p in nameNode[1]:
      let head = pragmaHead(p)
      if $head == "kdlNode" and
         p.kind in {nnkCall, nnkExprColonExpr} and p.len >= 2 and
         p[1].kind == nnkStrLit:
        return p[1].strVal
  result = $typeSym
  for i in 0 ..< result.len:
    if result[i] in {'A'..'Z'}:
      result[i] = char(uint8(result[i]) + 32)

type
  FieldKind = enum
    fkArg, fkProp
  FieldInfo = object
    name*: string       # Nim field name
    wireName*: string   # kdlRename target or name
    typeStr*: string    # type signature stringified
    kind*: FieldKind
    hasDefault*: bool   # true iff declared as `name: T = expr`

proc collectFields(typeSym: NimNode): seq[FieldInfo] {.compileTime.} =
  let impl = typeSym.getImpl
  let recList = impl[2][2]
  expectKind(recList, nnkRecList)
  for identDefs in recList:
    if identDefs.kind != nnkIdentDefs: continue
    let typ = identDefs[^2]
    # `identDefs[^1]` is the default expression node; `nnkEmpty`
    # means "no default declared." Required-prop tracking keys off
    # this signal — fields without a default get a slot in the
    # post-parse "did this prop appear?" bitmap check.
    let hasDef = identDefs[^1].kind != nnkEmpty
    for j in 0 ..< identDefs.len - 2:
      let nameNode = identDefs[j]
      var fName: string
      var fKind = fkArg
      var fWire = ""
      if nameNode.kind == nnkPragmaExpr:
        fName = $nameNode[0]
        for p in nameNode[1]:
          let head = pragmaHead(p)
          case $head
          of "kdlArg":  fKind = fkArg
          of "kdlProp": fKind = fkProp
          of "kdlRename":
            if p.kind in {nnkCall, nnkExprColonExpr} and p.len >= 2 and
               p[1].kind == nnkStrLit:
              fWire = p[1].strVal
          else: discard
      else:
        fName = $nameNode
      if fWire.len == 0: fWire = fName
      result.add(FieldInfo(name: fName, wireName: fWire,
                           typeStr: $typ, kind: fKind,
                           hasDefault: hasDef))

# ---------------------------------------------------------------------------
# Public macro
# ---------------------------------------------------------------------------

macro derivePDADecode*(T: typed): untyped =
  ## Emit `proc pdaDecode(v: var T, src: string, pos: var int):
  ## Result[void, ParseError]`. The proc reads bytes starting at
  ## `pos`, fills `v`, and advances `pos` past the consumed bytes.
  let wireName = newStrLitNode(nodeNameOf(T))
  let fields = collectFields(T)

  # Walk all kdlArg fields in declaration order. Each becomes one
  # read-string-arg block emitted into the proc body in the same
  # order. Sprint 1 supports only string args.
  var argFields: seq[FieldInfo] = @[]
  for f in fields:
    if f.kind == fkArg: argFields.add(f)

  # Build per-prop dispatch arms. Sprint 1 cycle 3 supports int only.
  # `inject`-declared variables in the outer quote (pos, src, slot,
  # keyStart, keyLen) are visible by name to these AST-built arms.
  let posSym2 = ident"pos"
  let srcSym2 = ident"src"
  let slotSym = ident"v"
  let keyStartSym = ident"keyStart"
  let keyLenSym = ident"keyLen"
  # Build a required-prop bitmap. Each prop without a default gets a
  # slot bit in a uint64. Post-parse, if `seen & required != required`,
  # at least one required prop was missing → Err. Sprint 1 caps at
  # 64 props; a follow-on lifts to `array[ceilDiv(n, 64), uint64]`.
  var requiredMask: uint64 = 0
  var propSlot = 0
  var propIndices: seq[int] = @[]  # parallel index into propFields
  for f in fields:
    if f.kind != fkProp: continue
    propIndices.add(propSlot)
    if not f.hasDefault:
      requiredMask = requiredMask or (1'u64 shl propSlot)
    inc propSlot
  let requiredMaskLit = newLit(requiredMask)
  let seenSym = ident"seenProps"

  var propDispatch = newStmtList()
  var idxInArr = 0
  for f in fields:
    if f.kind != fkProp: continue
    let wireLit = newStrLitNode(f.wireName)
    let fIdent = ident(f.name)
    let slotBit = newLit(1'u64 shl propIndices[idxInArr])
    inc idxInArr
    let readVal =
      if f.typeStr == "int":
        quote do:
          var vTmp = 0
          while `posSym2` < `srcSym2`.len and
                `srcSym2`[`posSym2`] in {'0'..'9'}:
            vTmp = vTmp * 10 + (`srcSym2`[`posSym2`].int - '0'.int)
            inc `posSym2`
          vTmp
      elif f.typeStr == "bool":
        quote do:
          # Recognize the v2 keyword forms `#true` / `#false`.
          # No legacy `true`/`false` per KDL v2 — Sprint 2 narrows
          # error cases if some user writes the bareword form.
          var vTmp = false
          if `posSym2` + 4 < `srcSym2`.len and
             `srcSym2`[`posSym2` .. `posSym2` + 4] == "#true":
            vTmp = true
            `posSym2` += 5
          elif `posSym2` + 5 < `srcSym2`.len and
               `srcSym2`[`posSym2` .. `posSym2` + 5] == "#false":
            vTmp = false
            `posSym2` += 6
          vTmp
      else:
        # Other prop types land in later cycles; emit a stub so the
        # macro still compiles even with mixed schemas.
        quote do:
          default(typeof(`slotSym`.`fIdent`))
    propDispatch.add(quote do:
      if `keyLenSym` == `wireLit`.len and
         `srcSym2`[`keyStartSym` ..< `keyStartSym` + `keyLenSym`] == `wireLit`:
        `slotSym`.`fIdent` = `readVal`
        `seenSym` = `seenSym` or `slotBit`
        continue)

  let vSym = ident"v"
  let srcSym = ident"src"
  let posSym = ident"pos"
  let procName = ident"pdaDecode"
  var argBranch = newStmtList()
  for f in argFields:
    let fIdent = ident(f.name)
    argBranch.add(quote do:
      # Skip whitespace before this positional arg
      while `posSym` < `srcSym`.len and `srcSym`[`posSym`] in {' ', '\t'}:
        inc `posSym`
      # Read quoted string arg
      if `posSym` < `srcSym`.len and `srcSym`[`posSym`] == '"':
        inc `posSym`
        let argStart = `posSym`
        while `posSym` < `srcSym`.len and `srcSym`[`posSym`] != '"':
          inc `posSym`
        `vSym`.`fIdent` = `srcSym`[argStart ..< `posSym`]
        if `posSym` < `srcSym`.len: inc `posSym`)

  result = quote do:
    proc `procName`(`vSym` {.inject.}: var `T`,
                    `srcSym` {.inject.}: string,
                    `posSym` {.inject.}: var int):
        Result[void, ParseError] =
      var `seenSym` {.inject.}: uint64 = 0
      # Skip leading whitespace + newlines
      while `posSym` < `srcSym`.len and
            `srcSym`[`posSym`] in {' ', '\t', '\n', '\r'}:
        inc `posSym`
      if `posSym` >= `srcSym`.len:
        return err[void, ParseError](initError(peParseExpected,
          pointSpan(StartPosition), "unexpected EOF; expected node"))
      # Match node name bareword
      let nameStart = `posSym`
      while `posSym` < `srcSym`.len and
            `srcSym`[`posSym`] notin {' ', '\t', '\n', '\r', '=', '"'}:
        inc `posSym`
      let nameLen = `posSym` - nameStart
      if nameLen != `wireName`.len or
         `srcSym`[nameStart ..< nameStart + nameLen] != `wireName`:
        return err[void, ParseError](initError(peParseExpected,
          pointSpan(StartPosition), "expected node named '" & `wireName` & "'"))
      # Skip whitespace after node name
      while `posSym` < `srcSym`.len and `srcSym`[`posSym`] in {' ', '\t'}:
        inc `posSym`
      `argBranch`
      # Read 0..N props until end-of-line / EOF.
      while `posSym` < `srcSym`.len and
            `srcSym`[`posSym`] notin {'\n', '\r'}:
        while `posSym` < `srcSym`.len and
              `srcSym`[`posSym`] in {' ', '\t'}:
          inc `posSym`
        if `posSym` >= `srcSym`.len or
           `srcSym`[`posSym`] in {'\n', '\r'}: break
        let keyStart {.inject.} = `posSym`
        while `posSym` < `srcSym`.len and
              `srcSym`[`posSym`] notin {'=', ' ', '\t', '\n', '\r'}:
          inc `posSym`
        let keyLen {.inject.} = `posSym` - keyStart
        if `posSym` >= `srcSym`.len or `srcSym`[`posSym`] != '=':
          # Bareword that's not a prop key — Sprint 1 ignores; later
          # sprints distinguish positional args after props (illegal)
          # vs additional positional arg slots.
          break
        inc `posSym`  # past '='
        `propDispatch`
        # Unknown prop key — skip its value bytes to next whitespace
        while `posSym` < `srcSym`.len and
              `srcSym`[`posSym`] notin {' ', '\t', '\n', '\r'}:
          inc `posSym`
      # Required-prop check: missing any → Err.
      if (`seenSym` and `requiredMaskLit`) != `requiredMaskLit`:
        return err[void, ParseError](initError(peTypeMissingRequired,
          pointSpan(StartPosition), "missing required property"))
      ok(void, ParseError)

# ---------------------------------------------------------------------------
# Public wrapper
# ---------------------------------------------------------------------------

proc decodePDA*[T](src: string): Result[T, ParseError] =
  ## Public entry. Allocates a `T` using `default(T)` (which honors
  ## the user's `field: U = expr` defaults), invokes the per-T
  ## specialized `pdaDecode`, returns Result. For `seq[U]` static
  ## dispatches to a per-element loop. Same surface shape as the
  ## cursor-based `decode[T]` in src/api.nim per RFC Q2.
  mixin pdaDecode
  var pos = 0
  when T is seq:
    type Elem = typeof(default(T)[0])
    var values: T = @[]
    # Skip leading whitespace + newlines so an "empty-only-whitespace"
    # input yields an empty seq rather than spinning forever.
    while pos < src.len and src[pos] in {' ', '\t', '\n', '\r'}: inc pos
    while pos < src.len:
      var elem = default(Elem)
      let r = pdaDecode(elem, src, pos)
      if r.isErr: return err[T, ParseError](r.getErr)
      values.add(elem)
      # Skip trailing whitespace / newlines between top-level nodes
      while pos < src.len and src[pos] in {' ', '\t', '\n', '\r'}: inc pos
    ok[T, ParseError](values)
  else:
    var v = default(T)
    let r = pdaDecode(v, src, pos)
    if r.isErr: return err[T, ParseError](r.getErr)
    ok[T, ParseError](v)
