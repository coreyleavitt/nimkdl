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
