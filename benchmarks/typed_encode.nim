## Typed-encode bench. Apples-to-apples vs facet-kdl's
## `to_string(&value)` path. Parses once into a typed seq[Service],
## then times encode[seq[Service]](services) in a loop.
import std/[os, times, strformat, monotimes]
import nkdl

kdl:
  type Service {.kdlNode: "service".} = object
    name {.kdlArg.}: string
    port {.kdlProp.}: int
    replicas {.kdlProp.}: int = 1
    enabled {.kdlProp.}: bool = true

proc main() =
  let path = currentSourcePath().parentDir() / "fixtures" / "homogeneous-services-100.kdl"
  let src = readFile(path)
  const iters = 5_000

  let r = decode[seq[Service]](src)
  doAssert r.isOk
  let services = r.get

  # Warmup
  for _ in 1..100: discard encode(services, emPretty)

  let start = getMonoTime()
  for _ in 1..iters: discard encode(services, emPretty)
  let el = (getMonoTime() - start).inNanoseconds.float / 1e9
  let us = el / iters.float * 1e6
  let ops = iters.float / el

  echo &"nkdl encode(seq[Service], emPretty): {us:.1f}us avg   {ops/1000:.1f}K ops/s   {src.len} bytes in"

main()
