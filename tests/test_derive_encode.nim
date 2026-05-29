## Tests for deriveEncode — per-type macro emitting kdlEncode procs.
##
## Cycles C1-C10 of the clean-core rebuild fill this out one shape at
## a time. Each test defines a type, derives kdlEncode, constructs a
## value, runs it through a BufferEmitter, and asserts the wire bytes.

import std/unittest

import ../src/derive_encode
import ../src/emitter
import ../src/pragmas

suite "derive_encode — C1: tracer (one kdlArg string field)":

  type Service {.kdlNode: "service".} = object
    name {.kdlArg.}: string

  deriveEncode(Service)

  test "single string kdlArg emits node + arg":
    var s = Service(name: "web")
    var e = newBufferEmitter()
    kdlEncode(s, e)
    check e.finish() == "service \"web\"\n"

suite "derive_encode — C2: multi-field typed args":

  type Edge {.kdlNode: "edge".} = object
    label {.kdlArg.}: string
    weight {.kdlArg.}: int
    bidir {.kdlArg.}: bool

  deriveEncode(Edge)

  test "string + int + bool emit in field order":
    var v = Edge(label: "hot", weight: 7, bidir: true)
    var e = newBufferEmitter()
    kdlEncode(v, e)
    check e.finish() == "edge \"hot\" 7 #true\n"

  type Pt {.kdlNode: "pt".} = object
    x {.kdlArg.}: float
    y {.kdlArg.}: float

  deriveEncode(Pt)

  test "two floats emit with .0 marker":
    var p = Pt(x: 1.5, y: 2.0)
    var e = newBufferEmitter()
    kdlEncode(p, e)
    check e.finish() == "pt 1.5 2.0\n"

  type Empty {.kdlNode: "empty".} = object

  deriveEncode(Empty)

  test "node with no fields emits bare name":
    var v = Empty()
    var e = newBufferEmitter()
    kdlEncode(v, e)
    check e.finish() == "empty\n"

suite "derive_encode — C3: kdlProp":

  type Sv {.kdlNode: "sv".} = object
    host {.kdlProp.}: string
    port {.kdlProp.}: int
    enabled {.kdlProp.}: bool

  deriveEncode(Sv)

  test "three typed props emit key=value in field order":
    var s = Sv(host: "a.b", port: 443, enabled: true)
    var e = newBufferEmitter()
    kdlEncode(s, e)
    check e.finish() == "sv host=\"a.b\" port=443 enabled=#true\n"

  type Mixed {.kdlNode: "mixed".} = object
    name {.kdlArg.}: string
    count {.kdlProp.}: int
    ratio {.kdlProp.}: float

  deriveEncode(Mixed)

  test "kdlArg before kdlProp emits in declaration order":
    var m = Mixed(name: "first", count: 3, ratio: 1.5)
    var e = newBufferEmitter()
    kdlEncode(m, e)
    check e.finish() == "mixed \"first\" count=3 ratio=1.5\n"
