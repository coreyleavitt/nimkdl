## Comprehensive nkdl bench harness for the cross-impl comparison.
##
## Mirrors the layout of the Rust/C harnesses in this directory:
## one container build + one binary that times every measurable
## path against the same staged `/fixtures/` directory, with the
## same `{label} {us}us avg {K ops/s} {bytes}` line format so a
## reader can diff them column-by-column.
##
## Paths timed:
##   1. AST parse  — matches kdl-rs `KdlDocument::parse_v2`,
##                   ckdl event-drain, knus `parse_ast`.
##   2. Typed decode (legacy AST + walk) — matches the
##                   `decode[seq[Service]]` path in the API surface.
##   3. Typed decode (direct, issue #1)  — `parseInto[seq[Service]]`.
##                   The apples-to-apples for knus `parse::<Vec<T>>`
##                   and facet-kdl `from_str::<ServiceDoc>`.
##   4. Typed encode (legacy)  — encode(seq[Service], emPretty),
##                   via KdlNode/KdlDoc intermediate.
##   5. Typed encode (direct, issue #1) — `encodeFrom(seq[Service])`.
##                   Apples-to-apples for facet-kdl `to_string`.
##   6. Typed encode (direct, NESTED)  — `encodeFrom(seq[Server])`
##                   where Server has Action children. Same total
##                   inner-node count (100) but the indent + recursion
##                   path is exercised.
##
## The Service schema is identical to facet-kdl/main.rs and knus/main.rs
## (name arg + port/replicas/enabled props). Verify by reading those
## files side-by-side with this one.
##
## Fixture: /fixtures/homogeneous-services-100.kdl (staged by run.sh,
## same bytes every harness reads).
##
## Container: docker.io/nimlang/nim:2.2.0 (Debian trixie, glibc).
## Build flags: -d:release -d:nimCallDepthLimit=20000 -p:/work/src.

import std/[os, strutils, times, strformat, monotimes]
import nkdl

proc peakRssKb(): int =
  ## High-water-mark resident set size in KB. Reads /proc/self/status's
  ## VmPeak — Linux-only; returns -1 on other platforms.
  when defined(linux):
    for line in lines("/proc/self/status"):
      if line.startsWith("VmPeak:"):
        for tok in line.splitWhitespace():
          if tok.len > 0 and tok[0] in {'0'..'9'}: return parseInt(tok)
    return -1
  else:
    return -1

proc memReport(label: string, baselineKb, peakKb: int) =
  echo &"  {label:<45} baseline {baselineKb:>6} KB   peak {peakKb:>6} KB   delta {peakKb - baselineKb:>6} KB"

# Service: name arg + 3 typed props. Identical schema to:
#   facet-kdl/main.rs   (Service)
#   knus/main.rs        (Service)
type Service {.kdlNode: "service".} = object
  name {.kdlArg.}: string
  port {.kdlProp.}: int
  replicas {.kdlProp.}: int = 1
  enabled {.kdlProp.}: bool = true

# Nested shape for the encode bench: 25 Servers x 4 Actions = 100
# inner nodes (same total work as the flat 100-Service shape, but
# tests the indent + child-block recursion path).
type Action {.kdlNode: "action".} = object
  tmpl {.kdlArg, kdlRename: "template".}: string

type Server {.kdlNode: "server".} = object
  name {.kdlArg.}: string
  port {.kdlProp.}: int
  actions {.kdlChild.}: seq[Action]

deriveDecode(Service)
deriveVisitor(Service)
deriveEncode(Service)
deriveEncode(Action)
deriveEncode(Server)

proc report(name: string, contentLen: int, iters: int, elapsed: float) =
  let us = elapsed / iters.float * 1_000_000.0
  let ops = iters.float / elapsed
  echo &"  {name:<45} {us:>10.1f}us avg   {ops/1000:>10.1f}K ops/s   {contentLen} bytes"

template timeIt(iters: int, body: untyped): float =
  for _ in 0 ..< min(100, iters): body
  let start = getMonoTime()
  for _ in 0 ..< iters: body
  (getMonoTime() - start).inNanoseconds.float / 1e9

proc main() =
  let fixtureDir = "/fixtures"
  let svcPath = fixtureDir / "homogeneous-services-100.kdl"
  if not fileExists(svcPath):
    echo "homogeneous-services-100.kdl missing at ", svcPath
    return
  let src = readFile(svcPath)

  # 1. AST parse - shared corpus, matches kdl-rs/ckdl/knus parse_ast.
  echo "=== nkdl parse (AST build, release+orc) ===\n"
  let cases = @[
    ("realistic-config.kdl",         fixtureDir / "realistic-config.kdl",        5_000),
    ("Cargo.kdl",                    fixtureDir / "Cargo.kdl",                  10_000),
    ("ci.kdl",                       fixtureDir / "ci.kdl",                      5_000),
    ("website.kdl",                  fixtureDir / "website.kdl",                 5_000),
    ("flat-deps-100.kdl",            fixtureDir / "flat-deps-100.kdl",           2_000),
    ("tree-d8-b3.kdl",               fixtureDir / "tree-d8-b3.kdl",                200),
    ("deep-chain-100.kdl",           fixtureDir / "deep-chain-100.kdl",          1_000),
    ("unicode-heavy.kdl",            fixtureDir / "unicode-heavy.kdl",           2_000),
    ("homogeneous-services-100.kdl", fixtureDir / "homogeneous-services-100.kdl", 5_000),
  ]
  for (name, path, iters) in cases:
    if not fileExists(path): continue
    let c = readFile(path)
    let el = timeIt(iters):
      discard parse(c)
    report(name, c.len, iters, el)

  # 2 + 3. Typed decode: both paths, same fixture.
  echo "\n=== nkdl typed decode (homogeneous-services-100.kdl) ===\n"
  echo "  Service schema: same as facet-kdl/main.rs + knus/main.rs"
  echo "  (name arg, port u16/int prop, replicas prop, enabled prop)\n"
  block:
    let el = timeIt(5_000):
      discard decode[seq[Service]](src)
    report("nkdl decode[seq[Service]]  (AST + walk)", src.len, 5_000, el)
  block:
    let el = timeIt(5_000):
      discard parseInto[seq[Service]](src)
    report("nkdl parseInto[seq[Service]] (direct, #1)", src.len, 5_000, el)
  echo ""
  echo "  apples-to-apples competitors for the direct path:"
  echo "    knus       parse::<Vec<Service>>           (see knus/main.rs)"
  echo "    facet-kdl  from_str::<ServiceDoc>          (see facet-kdl/main.rs)"
  echo "    kdl-rs     -- n/a, no typed decode path --"
  echo "    ckdl       -- n/a, no typed decode path --"

  # 4 + 5. Typed encode on flat homogeneous shape.
  echo "\n=== nkdl typed encode FLAT (100 Service nodes, no children) ===\n"
  let svcs = decode[seq[Service]](src)
  doAssert svcs.isOk
  let services = svcs.get
  block:
    let el = timeIt(5_000):
      discard encode(services, emPretty)
    report("nkdl encode(seq[Service], emPretty)", src.len, 5_000, el)
  block:
    let el = timeIt(5_000):
      let r = encodeFrom(services)
      discard r.get
    report("nkdl encodeFrom(seq[Service])  (direct, #1)", src.len, 5_000, el)
  echo ""
  echo "  apples-to-apples competitors for typed encode:"
  echo "    facet-kdl  to_string(&doc)                 (see facet-kdl/main.rs)"
  echo "    knus       -- n/a, knus has no encode path --"
  echo "    kdl-rs     to_string (untyped, AST roundtrip — different path)"
  echo "    ckdl       streaming emitter only — not directly comparable"

  # 6. Typed encode on nested Server-with-Action children.
  echo "\n=== nkdl typed encode NESTED (25 Server x 4 Action children = 100 inner) ===\n"
  var servers = newSeq[Server](25)
  for i in 0 ..< 25:
    servers[i] = Server(name: "host-" & $i, port: 1000 + i, actions: @[
      Action(tmpl: "log"), Action(tmpl: "alert"),
      Action(tmpl: "metric"), Action(tmpl: "trace")])
  # synthetic input; report bytes-out instead of bytes-in.
  let encOut = encodeFrom(servers).get
  block:
    let el = timeIt(5_000):
      discard encode(servers, emPretty)
    report("nkdl encode(seq[Server], emPretty)", encOut.len, 5_000, el)
  block:
    let el = timeIt(5_000):
      let r = encodeFrom(servers)
      discard r.get
    report("nkdl encodeFrom(seq[Server])  (direct, #1)", encOut.len, 5_000, el)
  echo ""
  echo "  No directly comparable harness — facet-kdl's bench is flat-only."
  echo "  This row exists to defend against \"flat-only encode\" critique."

  echo ""

main()
