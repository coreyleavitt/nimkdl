import std/[os, times, monotimes]
import kdl

type Service {.kdlNode: "service".} = object
  name {.kdlArg.}: string
  port {.kdlProp.}: int
  replicas {.kdlProp.}: int = 1
  enabled {.kdlProp.}: bool = true

type Action {.kdlNode: "action".} = object
  tmpl {.kdlArg, kdlRename: "template".}: string

type Server {.kdlNode: "server".} = object
  name {.kdlArg.}: string
  port {.kdlProp.}: int
  actions {.kdlChild.}: seq[Action]

deriveDecode(Service)
deriveEncode(Service)
deriveEncode(Action)
deriveEncode(Server)

proc benchSeq[T](label: string, vs: seq[T]) =
  const iters = 5_000
  for _ in 1..100: discard encode(vs, emPretty)
  var start = getMonoTime()
  for _ in 1..iters: discard encode(vs, emPretty)
  let elLegacy = (getMonoTime() - start).inNanoseconds.float / 1e9
  for _ in 1..100: discard encodeFrom(vs)
  start = getMonoTime()
  for _ in 1..iters: discard encodeFrom(vs)
  let elDirect = (getMonoTime() - start).inNanoseconds.float / 1e9
  echo label
  echo "  legacy: ", int(elLegacy / float(iters) * 1e6), "us  ",
       int(float(iters) / elLegacy), " ops/s"
  echo "  direct: ", int(elDirect / float(iters) * 1e6), "us  ",
       int(float(iters) / elDirect), " ops/s   (", elLegacy / elDirect, "x)"

proc main() =
  let path = currentSourcePath().parentDir() / "fixtures" / "homogeneous-services-100.kdl"
  let src = readFile(path)
  let r = decode[seq[Service]](src)
  doAssert r.isOk
  let services = r.get
  benchSeq("simple shape (100 Service, no children)", services)

  # Same total node count, but as nested Server-with-Action children.
  # 25 servers x 4 actions each = 100 inner nodes + 25 outer = realistic shape.
  var servers = newSeq[Server](25)
  for i in 0 ..< 25:
    servers[i] = Server(name: "host-" & $i, port: 1000 + i, actions: @[
      Action(tmpl: "log"), Action(tmpl: "alert"),
      Action(tmpl: "metric"), Action(tmpl: "trace")])
  benchSeq("nested shape (25 Server + 100 Action children)", servers)
  echo ""
  echo "facet-kdl typed encode reference:  ~27.5K ops/s"

main()
