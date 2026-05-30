## Interleaved bench: runs Cat 1 / Cat 2 / Cat 3 round-robin in one
## process so all three see the same thermal + cache state. Reports
## min across many short rounds — the cleanest signal-to-noise for
## measuring small perf deltas.

import std/[os, monotimes, strutils, times]
import nkdl
import cursor as cur
import intern as itn
import lexer as lx

kdl:
  type Service {.kdlNode: "service".} = object
    name {.kdlArg.}: string
    port {.kdlProp.}: int
    replicas {.kdlProp.}: int = 1
    enabled {.kdlProp.}: bool = true

proc drainOnce(src: string): int =
  var interner = itn.initInterner()
  var stream = lx.lex(src, interner)
  var c = cur.initStringCursor(addr stream, src)
  while true:
    let ev = cur.advance(c)
    inc result
    if ev.kind == ceEof: return

proc decodeOnce(src: string) =
  discard decode[seq[Service]](src)

proc parseOnce(src: string) =
  discard parse(src)

const Rounds = 30
const PerRound = 2_000

proc main() =
  let src = readFile("benchmarks/fixtures/homogeneous-services-100.kdl")
  echo "fixture: ", src.len, " bytes"
  # Warmup all three
  for _ in 0 ..< 200:
    discard drainOnce(src)
    decodeOnce(src)
    parseOnce(src)
  var minCat1, minCat2, minCat3 = float(1e18)
  for r in 0 ..< Rounds:
    # Cat 1 round
    let t0 = getMonoTime()
    var s = 0
    for _ in 0 ..< PerRound: s += drainOnce(src)
    let t1 = getMonoTime()
    # Cat 2 round
    for _ in 0 ..< PerRound: decodeOnce(src)
    let t2 = getMonoTime()
    # Cat 3 round
    for _ in 0 ..< PerRound: parseOnce(src)
    let t3 = getMonoTime()
    let us1 = inNanoseconds(t1 - t0).float / PerRound.float / 1e3
    let us2 = inNanoseconds(t2 - t1).float / PerRound.float / 1e3
    let us3 = inNanoseconds(t3 - t2).float / PerRound.float / 1e3
    if us1 < minCat1: minCat1 = us1
    if us2 < minCat2: minCat2 = us2
    if us3 < minCat3: minCat3 = us3
    if r mod 5 == 0:
      echo "round ", r, ": cat1=", us1.formatFloat(ffDecimal, 2),
           "  cat2=", us2.formatFloat(ffDecimal, 2),
           "  cat3=", us3.formatFloat(ffDecimal, 2)
  echo "=== MIN over ", Rounds, " rounds ==="
  echo "cat1 (drain):  ", minCat1.formatFloat(ffDecimal, 2), " μs"
  echo "cat2 (decode): ", minCat2.formatFloat(ffDecimal, 2), " μs"
  echo "cat3 (parse):  ", minCat3.formatFloat(ffDecimal, 2), " μs"

main()
