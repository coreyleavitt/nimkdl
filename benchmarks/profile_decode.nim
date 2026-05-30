## Profile-focused decode[T] bench — Cat 2 typed-direct only.
## NO buildDoc, NO KdlDoc — cursor events straight to typed Service slots.

import std/[os, monotimes, times]
import nkdl

kdl:
  type Service {.kdlNode: "service".} = object
    name {.kdlArg.}: string
    port {.kdlProp.}: int
    replicas {.kdlProp.}: int = 1
    enabled {.kdlProp.}: bool = true

const Iters = 100_000

proc main() =
  let path = if paramCount() > 0: paramStr(1)
             else: "benchmarks/fixtures/homogeneous-services-100.kdl"
  let src = readFile(path)
  echo "fixture: ", path, " (", src.len, " bytes)"
  for _ in 0 ..< 1000: discard decode[seq[Service]](src)  # warmup
  let t0 = getMonoTime()
  for _ in 0 ..< Iters: discard decode[seq[Service]](src)
  let t1 = getMonoTime()
  let dt = inNanoseconds(t1 - t0).float / 1e9
  let usPer = dt / Iters.float * 1e6
  echo Iters, " iters in ", dt, "s = ", usPer, " μs/decode"

main()
