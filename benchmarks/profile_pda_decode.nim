## Sprint 1 bench gate: decodePDA[seq[ServiceP]] on
## homogeneous-services-100. Target ≤25 μs (2× hand-written ceiling
## per RFC). For comparison: cursor decode is ~50 μs, knus 47.7 μs.

import std/[os, monotimes, times]

import ../src/pda_decode
import ../src/pragmas

type Service {.kdlNode: "service".} = object
  name {.kdlArg.}: string
  port {.kdlProp.}: int = 0
  replicas {.kdlProp.}: int = 1
  enabled {.kdlProp.}: bool = true

derivePDADecode(Service)

const Iters = 100_000

proc main() =
  let path = if paramCount() > 0: paramStr(1)
             else: "benchmarks/fixtures/homogeneous-services-100.kdl"
  let src = readFile(path)
  echo "fixture: ", path, " (", src.len, " bytes)"
  # Sanity
  let r0 = decodePDA[seq[Service]](src)
  doAssert r0.isOk
  echo "decoded ", r0.get.len, " services; first = ", r0.get[0]
  # Warmup
  for _ in 0 ..< 1000: discard decodePDA[seq[Service]](src)
  let t0 = getMonoTime()
  for _ in 0 ..< Iters: discard decodePDA[seq[Service]](src)
  let t1 = getMonoTime()
  let dt = inNanoseconds(t1 - t0).float / 1e9
  let usPer = dt / Iters.float * 1e6
  echo Iters, " iters in ", dt, "s = ", usPer, " μs/decode"

main()
