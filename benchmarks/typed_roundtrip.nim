## D-stage bench gate. Times the macro-emitted kdlEncode +
## kdlDecode on a 100-Service fixture; outputs ns/op.
##
## Compile with:
##   nim c -d:release --hints:off benchmarks/typed_roundtrip.nim
##
## Pre-rebuild baseline (the deleted visitor protocol's decode-only
## path on the same input shape): ~46.9 μs/doc. The rebuild routes
## through the cursor + macro-emitted typed dispatch — different
## machine code, so an exact match is not expected. Goal: same
## order of magnitude; flag a regression > 2×.

import std/[monotimes, strutils, times]

import ../src/cursor
import ../src/derive_decode
import ../src/derive_encode
import ../src/emitter
import ../src/intern
import ../src/lexer
import ../src/pragmas

type Service {.kdlNode: "service".} = object
  name {.kdlArg.}: string
  port {.kdlProp.}: int
  enabled {.kdlProp.}: bool

deriveEncode(Service)
deriveDecode(Service)

# Build a 100-Service source string once.
proc buildFixture(): string =
  result = ""
  for i in 0 .. 99:
    result.add("service \"svc-")
    result.add($i)
    result.add("\" port=")
    result.add($(8000 + i))
    result.add(" enabled=#true\n")

proc benchDecode(src: string, iter: int): float =
  ## Returns mean nanoseconds per (parse + decode) round-trip.
  var total: int64 = 0
  for _ in 0 ..< iter:
    var interner = initInterner()
    var stream = lex(src, interner)
    var c = initStringCursor(addr stream, src)
    let t0 = getMonoTime()
    var consumed = 0
    while true:
      let ev = peek(c)
      if ev.kind == ceEof: break
      var s: Service
      let r = kdlDecode(s, c)
      if r.isErr:
        echo "decode error: ", r.getErr.hint
        return -1
      inc consumed
    let t1 = getMonoTime()
    total += (t1 - t0).inNanoseconds
    doAssert consumed == 100
  total.float / iter.float

proc benchEncode(values: seq[Service], iter: int): float =
  var total: int64 = 0
  for _ in 0 ..< iter:
    var e = newBufferEmitter()
    let t0 = getMonoTime()
    for v in values:
      kdlEncode(v, e)
    discard e.finish()
    let t1 = getMonoTime()
    total += (t1 - t0).inNanoseconds
  total.float / iter.float

when isMainModule:
  let src = buildFixture()
  echo "fixture: ", src.len, " bytes, 100 nodes"
  # Warm up
  discard benchDecode(src, 50)
  # Decode side
  let decodeIter = 500
  let decodeNs = benchDecode(src, decodeIter)
  echo "decode (lex+cursor+kdlDecode×100): ",
       formatFloat(decodeNs / 1000.0, ffDecimal, 2), " μs/doc-set"
  echo "  ", formatFloat(decodeNs / 100.0, ffDecimal, 1), " ns/node"
  # Encode side
  var values: seq[Service]
  for i in 0 .. 99:
    values.add(Service(name: "svc-" & $i, port: 8000 + i, enabled: true))
  discard benchEncode(values, 50)
  let encodeIter = 1000
  let encodeNs = benchEncode(values, encodeIter)
  echo "encode (kdlEncode×100 into BufferEmitter): ",
       formatFloat(encodeNs / 1000.0, ffDecimal, 2), " μs/doc-set"
  echo "  ", formatFloat(encodeNs / 100.0, ffDecimal, 1), " ns/node"
