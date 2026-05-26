## Typed-decode bench. Matches the knus typed path so we have a fair
## "parse + decode into a typed Vec<T>" head-to-head.
import std/[os, times, strformat, monotimes]
import kdl

type Service {.kdlNode: "service".} = object
  name {.kdlArg.}: string
  port {.kdlProp.}: int
  replicas {.kdlProp.}: int = 1
  enabled {.kdlProp.}: bool = true

deriveDecode(Service)

proc main() =
  # Read the vendored homogeneous-services fixture so every harness
  # (knus, facet-kdl, ours) consumes byte-identical input.
  let path = currentSourcePath().parentDir() / "fixtures" / "homogeneous-services-100.kdl"
  let src = readFile(path)
  const iters = 5_000

  for _ in 1..100: discard decode[seq[Service]](src)

  let start = getMonoTime()
  for _ in 1..iters: discard decode[seq[Service]](src)
  let el = (getMonoTime() - start).inNanoseconds.float / 1e9
  let us = el / iters.float * 1e6
  let ops = iters.float / el

  echo &"nimkdl typed decode[seq[Service]]: {us:.1f}us avg   {ops/1000:.1f}K ops/s   {src.len} bytes"

main()
