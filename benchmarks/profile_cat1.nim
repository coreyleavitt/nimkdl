## Profile-focused Cat 1 bench — pure event drain.
## NO buildDoc, NO kdlDecode, NO typed T, NO KdlDoc. Just lex + cursor.

import std/[os, monotimes, times]
import cursor
import intern
import lexer

const Iters = 100_000

proc drainEvents(src: string): int =
  var interner = initInterner()
  var stream = lex(src, interner)
  var c = initStringCursor(addr stream, src)
  while true:
    let ev = advance(c)
    inc result
    if ev.kind == ceEof: return

proc main() =
  let path = if paramCount() > 0: paramStr(1)
             else: "benchmarks/fixtures/homogeneous-services-100.kdl"
  let src = readFile(path)
  echo "fixture: ", path, " (", src.len, " bytes)"
  for _ in 0 ..< 1000: discard drainEvents(src)
  let t0 = getMonoTime()
  var total = 0
  for _ in 0 ..< Iters: total += drainEvents(src)
  let t1 = getMonoTime()
  let dt = inNanoseconds(t1 - t0).float / 1e9
  let usPer = dt / Iters.float * 1e6
  echo Iters, " iters in ", dt, "s = ", usPer, " μs/drain"
  echo "events drained: ", total div Iters, " per doc"

main()
