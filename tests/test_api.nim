## Stage E2 — public typed entry points (decode / encode / decodeAll).
##
## Behavior tests for the headline API. Tracer first; expand one
## suite per cycle.

import std/unittest
import std/strutils
import std/os

import ../src/api
import ../src/kdl_block
import ../src/pragmas
import ../src/spans
import ../src/node          # KdlNode / KdlDoc for the H1 raises compile-proof
import ../src/parser        # parse — to obtain a real doc/node in the proof
import ../src/value         # KdlValue — coerce leg of the proof

# kdl: at module scope so the emitted kdlDecode is visible to the
# `decode[Service]` generic instantiation site below.
kdl:
  type Service {.kdlNode: "service".} = object
    name {.kdlArg.}: string
    port {.kdlProp.}: int

suite "decode[T] — E2 tracer (single node)":

  test "single typed object decodes":
    let r = decode[Service]("service \"web\" port=80")
    check r.isOk
    check r.get.name == "web"
    check r.get.port == 80

suite "encode[T] — single node":

  test "single typed object encodes to wire bytes":
    let bytes: string = encode(Service(name: "web", port: 80))
    let r = decode[Service](bytes)
    check r.isOk
    check r.get.name == "web"
    check r.get.port == 80

suite "decode[seq[T]] — top-level node list":

  test "empty input decodes to empty seq":
    let r = decode[seq[Service]]("")
    check r.isOk
    check r.get.len == 0

  test "multiple nodes decode to populated seq":
    let src = "service \"web\" port=80\nservice \"api\" port=443\n"
    let r = decode[seq[Service]](src)
    check r.isOk
    check r.get.len == 2
    check r.get[0].name == "web"
    check r.get[1].name == "api"
    check r.get[1].port == 443

suite "encode[seq[T]] — multi-node":

  test "seq encodes to multiple nodes that decode back":
    let v0 = @[Service(name: "web", port: 80),
               Service(name: "api", port: 443)]
    let bytes: string = encode(v0)
    let r = decode[seq[Service]](bytes)
    check r.isOk
    check r.get.len == 2
    check r.get[0].name == "web"
    check r.get[1].name == "api"

suite "decode[T] in NimVM (compile-time)":

  # If these consts evaluate, decode[T] is VM-compatible. The whole
  # pipeline (lex → cursor → kdlDecode → Result wrap) ran at compile
  # time.
  const ctOne = decode[Service]("service \"web\" port=80").get
  const ctMany = decode[seq[Service]](
    "service \"web\" port=80\nservice \"api\" port=443").get

  test "single-node decode[T] runs at compile time":
    check ctOne.name == "web"
    check ctOne.port == 80

  test "seq[T] decode[T] runs at compile time":
    check ctMany.len == 2
    check ctMany[0].name == "web"
    check ctMany[1].port == 443

suite "decode[T] — error propagation":

  test "wrong node name surfaces ParseError":
    let r = decode[Service]("other \"web\"")
    check r.isErr

  test "missing required field surfaces ParseError":
    # `name` is a required kdlArg — absent → peMissingRequired
    let r = decode[Service]("service port=80")
    check r.isErr

  test "decode error is enriched with line/col at the boundary (B1)":
    # Bad value on line 2 → enriched error must carry real coordinates.
    let r = decode[seq[Service]]("service \"web\" port=80\nservice \"api\" port=notanint")
    check r.isErr
    let e = r.getErr
    check e.line == 2          # error is on the second line
    check e.sourcePath == "<input>"
    check e.col > 0

suite "decodeAll[seq[T]] — multi-error":

  test "all-good input matches decode[seq[T]]":
    let src = "service \"web\" port=80\nservice \"api\" port=443"
    let res = decodeAll[seq[Service]](src)
    check res.errors.len == 0
    check res.value.len == 2
    check res.value[0].name == "web"
    check res.value[1].name == "api"

  test "one bad node mid-stream — partial value + one error":
    let src = "service \"web\" port=80\n" &
              "service port=999\n" &              # missing required name
              "service \"api\" port=443\n"
    let res = decodeAll[seq[Service]](src)
    check res.errors.len >= 1
    # Good nodes flank the bad one — both should land in the value.
    check res.value.len == 2
    check res.value[0].name == "web"
    check res.value[1].name == "api"

  test "decodeAll returns a Parsed[T] (isComplete usable)":
    let src = "service \"web\" port=80\nservice \"api\" port=443"
    let res: Parsed[seq[Service]] = decodeAll[seq[Service]](src)
    check res.isComplete
    check res.value.len == 2

suite "C1 — source attribution (sourcePath param)":

  test "decode threads sourcePath into the error":
    let r = decode[seq[Service]](
      "service \"web\" port=notanint", "config.kdl")
    check r.isErr
    let e = r.getErr
    check e.sourcePath == "config.kdl"
    check ($e).startsWith("config.kdl:")

  test "decode default sourcePath stays <input>":
    let r = decode[seq[Service]]("service \"web\" port=notanint")
    check r.isErr
    check r.getErr.sourcePath == "<input>"

  test "decodeAll threads sourcePath into every error":
    let src = "service port=999\n"   # missing required name
    let res = decodeAll[seq[Service]](src, "svc.kdl")
    check res.errors.len >= 1
    for e in res.errors:
      check e.sourcePath == "svc.kdl"

suite "C2 — decodeFile[T]":

  test "decodeFile reads + decodes a real file":
    let path = getTempDir() / "nkdl_c2_ok.kdl"
    writeFile(path, "service \"web\" port=80")
    defer: removeFile(path)
    let r = decodeFile[Service](path)
    check r.isOk
    check r.get.name == "web"
    check r.get.port == 80

  test "parse error renders with the file path as sourcePath":
    let path = getTempDir() / "nkdl_c2_bad.kdl"
    writeFile(path, "service \"web\" port=notanint")
    defer: removeFile(path)
    let r = decodeFile[Service](path)
    check r.isErr
    let e = r.getErr
    check e.sourcePath == path
    check ($e).startsWith(path & ":")
    check e.line > 0
    check e.col > 0

  test "missing file yields peIOError with the path in the hint":
    let path = "does/not/exist.kdl"
    let r = decodeFile[Service](path)
    check r.isErr
    let e = r.getErr
    check e.code == peIOError
    check path in e.hint

  test "decodeFile is callable in a {.raises:[].} context":
    # Compile-proof: if decodeFile leaked an exception, this proc would
    # fail the raises pragma at compile time.
    proc onlyResults(p: string): bool {.raises: [].} =
      decodeFile[Service](p).isErr
    check onlyResults("does/not/exist.kdl")

suite "H1 — whole public surface is {.raises:[].} (rfc-consumer-api §4.5/§7)":
  # The "test" of H1 is compile-driven: `useSurface` is a {.raises:[].} proc
  # that exercises EVERY public api.nim entry — decode (source), encode (the
  # triaged emit chain), the node↔T bridge (decodeNode both overloads,
  # decodeChild, decodeOr, reEmitDecodeNode), and the value leg (coerce). It
  # compiles ONLY if every one of them is genuinely non-raising; a single
  # raises-leaky callee anywhere in the encode/emit chain would fail this proc
  # at compile time. Mirrors the C2 {.raises:[].} wrapper-proof pattern.
  proc useSurface(src: string, val: KdlValue) {.raises: [].} =
    # encode[T] — the H1 deferral's centerpiece (emit chain triaged to raises:[])
    let bytes = encode(Service(name: "web", port: 80))
    # decode[T] — source → T
    discard decode[Service](bytes)
    discard decode[Service](src)
    # node↔T bridge. Parse to obtain a real doc + node.
    let pr = parse(src)
    if pr.isOk:
      let doc = pr.get
      if doc.rootNodes.len > 0:
        let n = doc.rootNodes[0]
        discard decodeNode[Service](doc, n)              # source-slice path
        discard decodeNode[Service](n)                   # doc-less re-emit overload
        discard reEmitDecodeNode[Service](n)             # explicit re-emit fallback
        discard decodeChild[Service](doc, n, "service")  # child lookup leg
        discard decodeOr[Service](doc, n, Service(name: "fallback", port: 0))
    # coerce — value → T (scalar leg)
    discard coerce[string](val)

  test "useSurface compiles + runs (proof the whole surface is raises-clean)":
    useSurface("service \"web\" port=80", newKdlString("hi"))
