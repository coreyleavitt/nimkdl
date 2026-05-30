## Profile-focused parse bench: many iterations of a single fixture
## so perf can attribute time to the parser hot paths cleanly.

import std/[os, monotimes, times]
import nkdl

const Iters = 100_000

proc main() =
  let path = if paramCount() > 0: paramStr(1)
             else: "benchmarks/fixtures/homogeneous-services-100.kdl"
  let src = readFile(path)
  echo "fixture: ", path, " (", src.len, " bytes)"
  # Warmup
  for _ in 0 ..< 1000: discard parse(src)
  let t0 = getMonoTime()
  for _ in 0 ..< Iters: discard parse(src)
  let t1 = getMonoTime()
  let dt = inNanoseconds(t1 - t0).float / 1e9
  let usPer = dt / Iters.float * 1e6
  echo Iters, " iters in ", dt, "s = ", usPer, " μs/parse"

main()
