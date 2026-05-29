## Tests for the KdlEmitter primitive — symmetric OUT-side inverse of
## KdlCursor. Built in cycles A1-A11; this file grows one assertion at
## a time as the substrate fills in.

import std/unittest

import ../src/emitter

suite "emitter — A1: tracer":

  test "newBufferEmitter then finish returns empty string for no events":
    var e = newBufferEmitter()
    check e.finish() == ""

suite "emitter — A2: bare node":

  test "pushNodeBegin foo + pushNodeEnd yields foo\\n":
    var e = newBufferEmitter()
    e.pushNodeBegin("foo")
    e.pushNodeEnd()
    check e.finish() == "foo\n"

suite "emitter — A3: typed-value pushArg":

  test "pushArgInt 42 emits foo 42\\n":
    var e = newBufferEmitter()
    e.pushNodeBegin("foo")
    e.pushArgInt(42)
    e.pushNodeEnd()
    check e.finish() == "foo 42\n"

  test "pushArgInt -7 emits the negative sign":
    var e = newBufferEmitter()
    e.pushNodeBegin("n")
    e.pushArgInt(-7)
    e.pushNodeEnd()
    check e.finish() == "n -7\n"

  test "multiple pushArgInt emit space-separated":
    var e = newBufferEmitter()
    e.pushNodeBegin("seq")
    e.pushArgInt(1)
    e.pushArgInt(2)
    e.pushArgInt(3)
    e.pushNodeEnd()
    check e.finish() == "seq 1 2 3\n"
