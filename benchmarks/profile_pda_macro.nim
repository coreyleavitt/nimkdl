## PDA spike round 2: macro-generated single-pass fused parser.
## Goal: measure overhead of a generalized macro vs the hand-written
## ceiling. Same fixture (homogeneous-services-100).
##
## The macro takes a {.kdlNode.}-tagged type and emits a specialized
## proc that parses bytes → typed value(s) in one tight loop. No lex
## pass, no token stream, no event materialization.
##
## Scope of THIS spike's macro: enough to cover Service's shape
## (bareword node name, string arg, int props, bool prop with
## #true/#false). Not a full KDL grammar implementation. The point
## is to see if a general macro emits code close to the hand-written
## 5.92μs ceiling.

import std/[macros, os, monotimes, sequtils, strutils, times]

import ../src/pragmas

# ---------------------------------------------------------------------------
# Macro: pdaDecode[T]
# ---------------------------------------------------------------------------

proc nodeNameOf(typeSym: NimNode): string {.compileTime.} =
  let impl = typeSym.getImpl
  expectKind(impl, nnkTypeDef)
  let nameNode = impl[0]
  if nameNode.kind == nnkPragmaExpr:
    for p in nameNode[1]:
      let head = if p.kind in {nnkCall, nnkExprColonExpr}: p[0] else: p
      if $head == "kdlNode" and p.kind in {nnkCall, nnkExprColonExpr} and
         p.len >= 2 and p[1].kind == nnkStrLit:
        return p[1].strVal
  result = ($typeSym).toLowerAscii

type
  FieldKind = enum
    fkArg, fkProp
  FieldInfo = object
    name: string        # Nim field name
    wireName: string    # kdlRename or name
    typeStr: string     # "string" | "int" | "bool" | ...
    kind: FieldKind

proc collectFields(typeSym: NimNode): seq[FieldInfo] {.compileTime.} =
  let impl = typeSym.getImpl
  let recList = impl[2][2]
  expectKind(recList, nnkRecList)
  for identDefs in recList:
    if identDefs.kind != nnkIdentDefs: continue
    let typ = identDefs[^2]
    for j in 0 ..< identDefs.len - 2:
      let nameNode = identDefs[j]
      var fName: string
      var fKind = fkArg
      var fWire = ""
      if nameNode.kind == nnkPragmaExpr:
        fName = $nameNode[0]
        for p in nameNode[1]:
          let head = if p.kind in {nnkCall, nnkExprColonExpr}: p[0] else: p
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
                           typeStr: $typ, kind: fKind))

macro pdaDecodeSeq*(T: typed, src: typed): untyped =
  ## Emit a specialized single-pass parser for `seq[T]` over `src`.
  ## Returns `seq[T]`. Reads bytes directly; no lex / cursor / events.
  let wireName = newStrLitNode(nodeNameOf(T))
  let fields = collectFields(T)
  let argFields = fields.filterIt(it.kind == fkArg)
  let propFields = fields.filterIt(it.kind == fkProp)

  # Build the per-prop dispatch as an if-elif chain keyed by first
  # byte of the wire name (Service has p/r/e — distinct first bytes).
  # A real macro would emit perfect-hash for ≥8 props; for the spike
  # the first-byte trick gives 1-cycle dispatch for our 3-prop case.
  # Build prop dispatch as AST referring to outer-scope idents
  # (`pos`, `src`, `keyStart`, `keyLen`, `slot`). Each `ident("name")`
  # resolves to the matching declaration in the enclosing quote.
  let posI = ident"pos"
  let srcI = ident"src"
  let keyStartI = ident"keyStart"
  let keyLenI = ident"keyLen"
  let slotI = ident"slot"
  var propDispatch = newStmtList()
  for pf in propFields:
    let wireLit = newStrLitNode(pf.wireName)
    let fNameIdent = ident(pf.name)
    let valExpr =
      if pf.typeStr == "int":
        quote do:
          var v = 0
          while `posI` < `srcI`.len and `srcI`[`posI`] in {'0'..'9'}:
            v = v * 10 + (`srcI`[`posI`].int - '0'.int)
            inc `posI`
          v
      elif pf.typeStr == "bool":
        quote do:
          var v = false
          if `posI` + 4 < `srcI`.len and `srcI`[`posI` .. `posI`+4] == "#true":
            v = true
            `posI` += 5
          elif `posI` + 5 < `srcI`.len and `srcI`[`posI` .. `posI`+5] == "#false":
            v = false
            `posI` += 6
          v
      else:
        quote do:
          ""

    propDispatch.add(quote do:
      if `keyLenI` == `wireLit`.len and
         `srcI`[`keyStartI` ..< `keyStartI` + `keyLenI`] == `wireLit`:
        `slotI`.`fNameIdent` = `valExpr`
        continue)

  # `{.inject.}` opts out of quote-do's gensym for the loop variables
  # so the propDispatch AST (built above with literal idents) splices
  # in with matching names.
  result = quote do:
    block:
      var pos {.inject.} = 0
      var resultSeq = newSeqOfCap[`T`](100)
      while pos < src.len:
        while pos < src.len and src[pos] in {' ', '\t', '\n', '\r'}: inc pos
        if pos >= src.len: break
        let nameStart = pos
        while pos < src.len and src[pos] notin {' ', '\t', '\n', '\r', '=', '"'}:
          inc pos
        let nameLen = pos - nameStart
        if nameLen != `wireName`.len or
           src[nameStart..<nameStart+nameLen] != `wireName`:
          while pos < src.len and src[pos] != '\n': inc pos
          continue
        var slot {.inject.}: `T`
        while pos < src.len and src[pos] in {' ', '\t'}: inc pos
        if pos < src.len and src[pos] == '"':
          inc pos
          let argStart = pos
          while pos < src.len and src[pos] != '"': inc pos
          slot.name = src[argStart..<pos]
          inc pos
        while pos < src.len and src[pos] notin {'\n', '\r'}:
          while pos < src.len and src[pos] in {' ', '\t'}: inc pos
          if pos >= src.len or src[pos] in {'\n', '\r'}: break
          let keyStart {.inject.} = pos
          while pos < src.len and src[pos] notin {'=', ' ', '\n', '\r'}: inc pos
          let keyLen {.inject.} = pos - keyStart
          if pos >= src.len or src[pos] != '=': break
          inc pos
          `propDispatch`
          while pos < src.len and src[pos] notin {' ', '\t', '\n', '\r'}: inc pos
        while pos < src.len and src[pos] in {'\n', '\r'}: inc pos
        resultSeq.add(slot)
      resultSeq

# ---------------------------------------------------------------------------
# Bench
# ---------------------------------------------------------------------------

type
  Service {.kdlNode: "service".} = object
    name {.kdlArg.}: string
    port {.kdlProp.}: int
    replicas {.kdlProp.}: int
    enabled {.kdlProp.}: bool

const Iters = 100_000

proc main() =
  let path = if paramCount() > 0: paramStr(1)
             else: "benchmarks/fixtures/homogeneous-services-100.kdl"
  let src = readFile(path)
  echo "fixture: ", path, " (", src.len, " bytes)"
  # Sanity
  let svcs0 = pdaDecodeSeq(Service, src)
  echo "decoded ", svcs0.len, " services; first = ", svcs0[0]
  # Warmup
  for _ in 0 ..< 1000:
    let _ = pdaDecodeSeq(Service, src)
  let t0 = getMonoTime()
  for _ in 0 ..< Iters:
    let _ = pdaDecodeSeq(Service, src)
  let t1 = getMonoTime()
  let dt = inNanoseconds(t1 - t0).float / 1e9
  let usPer = dt / Iters.float * 1e6
  echo Iters, " iters in ", dt, "s = ", usPer, " μs/decode"

main()
