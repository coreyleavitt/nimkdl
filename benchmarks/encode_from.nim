import std/[os, times, monotimes]
import kdl

type Service {.kdlNode: "service".} = object
  name {.kdlArg.}: string
  port {.kdlProp.}: int
  replicas {.kdlProp.}: int = 1
  enabled {.kdlProp.}: bool = true

deriveDecode(Service)
deriveEncode(Service)

proc main() =
  let path = currentSourcePath().parentDir() / "fixtures" / "homogeneous-services-100.kdl"
  let src = readFile(path)
  const iters = 5_000
  let r = decode[seq[Service]](src)
  doAssert r.isOk
  let services = r.get

  # Legacy (KdlDoc) path
  for _ in 1..100: discard encode(services, emPretty)
  var start = getMonoTime()
  for _ in 1..iters: discard encode(services, emPretty)
  let elLegacy = (getMonoTime() - start).inNanoseconds.float / 1e9
  echo "legacy encode(seq):   ", int(elLegacy / float(iters) * 1e6), "us  ", int(float(iters) / elLegacy), " ops/s"

  # Direct path
  for _ in 1..100: discard encodeFrom(services)
  start = getMonoTime()
  for _ in 1..iters: discard encodeFrom(services)
  let elDirect = (getMonoTime() - start).inNanoseconds.float / 1e9
  echo "direct encodeFrom:    ", int(elDirect / float(iters) * 1e6), "us  ", int(float(iters) / elDirect), " ops/s"
  echo "speedup: ", elLegacy / elDirect, "x"
  echo "facet-kdl reference:  ~27.5K ops/s"

main()
