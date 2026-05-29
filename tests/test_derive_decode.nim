## Tests for deriveDecode — per-type macro emitting kdlDecode procs.
##
## Cycles D1-D15 of the clean-core rebuild fill this out one shape at
## a time. Each test defines a type, derives kdlDecode, parses a KDL
## source through StringCursor, runs the macro-generated decoder, and
## asserts the populated value + outcome.

import std/unittest

import ../src/derive_decode
import ../src/cursor
import ../src/intern
import ../src/lexer
import ../src/pragmas
import ../src/spans

type CursorFixture = ref object
  stream*: ref TokenStream
  cursor*: StringCursor

proc mkCursor(src: string): CursorFixture =
  var interner = initInterner()
  var sref: ref TokenStream
  new(sref)
  sref[] = lex(src, interner)
  result = CursorFixture(stream: sref,
                         cursor: initStringCursor(addr sref[], src))

suite "derive_decode — D1: tracer (one kdlArg string field)":

  type Service {.kdlNode: "service".} = object
    name {.kdlArg.}: string

  deriveDecode(Service)

  test "single string kdlArg populates field":
    let f = mkCursor("service \"web\"")
    var s: Service
    let r = kdlDecode(s, f.cursor)
    check r.isOk
    check s.name == "web"

  test "wrong node name returns error":
    let f = mkCursor("other \"web\"")
    var s: Service
    let r = kdlDecode(s, f.cursor)
    check r.isErr

suite "derive_decode — D2: multi-field typed args":

  type Edge {.kdlNode: "edge".} = object
    label {.kdlArg.}: string
    weight {.kdlArg.}: int
    bidir {.kdlArg.}: bool

  deriveDecode(Edge)

  test "string + int + bool populate in field order":
    let f = mkCursor("edge \"hot\" 7 #true")
    var v: Edge
    let r = kdlDecode(v, f.cursor)
    check r.isOk
    check v.label == "hot"
    check v.weight == 7
    check v.bidir == true

  test "negative int decodes":
    let f = mkCursor("edge \"x\" -3 #false")
    var v: Edge
    let r = kdlDecode(v, f.cursor)
    check r.isOk
    check v.weight == -3
    check v.bidir == false

  type Pt {.kdlNode: "pt".} = object
    x {.kdlArg.}: float
    y {.kdlArg.}: float

  deriveDecode(Pt)

  test "float kdlArgs populate":
    let f = mkCursor("pt 1.5 2.0")
    var p: Pt
    let r = kdlDecode(p, f.cursor)
    check r.isOk
    check p.x == 1.5
    check p.y == 2.0

  type Empty {.kdlNode: "empty".} = object

  deriveDecode(Empty)

  test "node with no fields decodes from bare":
    let f = mkCursor("empty")
    var v: Empty
    let r = kdlDecode(v, f.cursor)
    check r.isOk

  test "too many positional args returns error":
    let f = mkCursor("pt 1.0 2.0 3.0")
    var p: Pt
    let r = kdlDecode(p, f.cursor)
    check r.isErr
