## Stage E2 — public typed entry points (decode / encode / decodeAll).
##
## Behavior tests for the headline API. Tracer first; expand one
## suite per cycle.

import std/unittest

import ../src/api
import ../src/kdl_block
import ../src/pragmas

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
    let bytes = encode(Service(name: "web", port: 80)).get
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
    let bytes = encode(v0).get
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
