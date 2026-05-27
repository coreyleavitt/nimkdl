## perf-record driver for the typed-direct path. Tight loop on the
## same homogeneous-services-100.kdl fixture cycle 11 measures. Build
## with frame pointers (`--passC:-fno-omit-frame-pointer`) so the
## call graph is readable.
import std/os
import nkdl

type Service {.kdlNode: "service".} = object
  name {.kdlArg.}: string
  port {.kdlProp.}: int
  replicas {.kdlProp.}: int = 1
  enabled {.kdlProp.}: bool = true

deriveVisitor(Service)

proc main() =
  let path = currentSourcePath().parentDir() / "fixtures" / "homogeneous-services-100.kdl"
  let src = readFile(path)
  # ~30 seconds at ~57us/parse = ~500K iterations
  for _ in 1..500_000:
    discard parseInto[seq[Service]](src)

main()
