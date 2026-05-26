## Typed-decode bench. Matches the knus typed path so we have a fair
## "parse + decode into a typed Vec<T>" head-to-head.
import std/[times, strformat, monotimes, strutils]
import kdl

type Service {.kdlNode: "service".} = object
  name {.kdlArg.}: string
  port {.kdlProp.}: int
  replicas {.kdlProp.}: int = 1
  enabled {.kdlProp.}: bool = true

deriveDecode(Service)

proc main() =
  var src = ""
  for i in 0 ..< 100:
    src.add(&"service \"svc-{i}\" port={8000 + i} replicas={(i mod 5) + 1}\n")

  const iters = 5_000

  # Warmup
  for _ in 1..100: discard decode[seq[Service]](src)

  let start = getMonoTime()
  for _ in 1..iters: discard decode[seq[Service]](src)
  let el = (getMonoTime() - start).inNanoseconds.float / 1e9
  let us = el / iters.float * 1e6
  let ops = iters.float / el

  echo &"nimkdl typed decode[seq[Service]]: {us:.1f}us avg   {ops/1000:.1f}K ops/s   {src.len} bytes"

main()
