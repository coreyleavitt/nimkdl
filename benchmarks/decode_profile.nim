## Decode profile. Splits decode[seq[Service]] into its two phases
## so we can see whether the 2x gap vs knus is in parse or in the
## per-node decode-walk after parse.
import std/[os, times, strformat, monotimes]
import kdl

type Service {.kdlNode: "service".} = object
  name {.kdlArg.}: string
  port {.kdlProp.}: int
  replicas {.kdlProp.}: int = 1
  enabled {.kdlProp.}: bool = true

deriveDecode(Service)

proc bench(name: string, iters: int, body: proc()): float =
  for _ in 1..min(100, iters div 10): body()
  let start = getMonoTime()
  for _ in 1..iters: body()
  result = (getMonoTime() - start).inNanoseconds.float / 1e9

proc main() =
  let path = currentSourcePath().parentDir() / "fixtures" / "homogeneous-services-100.kdl"
  let src = readFile(path)
  const iters = 5_000

  # Phase 1: parse only (no decode walk)
  let parseOnly = bench("parse only", iters, proc() = discard parse(src))
  let parseOps = iters.float / parseOnly
  let parseUs = parseOnly / iters.float * 1e6
  echo &"parse only:               {parseUs:.1f}us avg   {parseOps/1000:.1f}K ops/s"

  # Phase 2: full decode (parse + walk)
  let decodeAll = bench("decode", iters, proc() = discard decode[seq[Service]](src))
  let decodeOps = iters.float / decodeAll
  let decodeUs = decodeAll / iters.float * 1e6
  echo &"decode[seq[Service]]:     {decodeUs:.1f}us avg   {decodeOps/1000:.1f}K ops/s"

  # Phase 3: just the walk (parse once outside the loop)
  let r = parse(src)
  doAssert r.isOk
  var doc = r.get
  let nameKey = doc.interner.intern("service")
  let walkOnly = bench("walk", iters, proc() =
    var elems: seq[Service]
    for i in 0 ..< doc.nodes.len:
      if doc.nodes[i].name == nameKey:
        var elem: Service
        discard kdlDecodeImpl(elem, doc.nodes[i], doc)
        elems.add(elem))
  let walkOps = iters.float / walkOnly
  let walkUs = walkOnly / iters.float * 1e6
  echo &"walk only (parsed once):  {walkUs:.1f}us avg   {walkOps/1000:.1f}K ops/s"

  echo ""
  echo &"breakdown:  parse = {parseUs:.1f}us,  walk = {walkUs:.1f}us,  total = {parseUs + walkUs:.1f}us"
  echo &"decode adds {(decodeUs - parseUs):.1f}us over parse alone"

main()
