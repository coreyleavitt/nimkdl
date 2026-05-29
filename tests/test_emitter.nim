## Tests for the KdlEmitter primitive — symmetric OUT-side inverse of
## KdlCursor. Built in cycles A1-A11; this file grows one assertion at
## a time as the substrate fills in.

import std/unittest

import ../src/emitter

suite "emitter — A1: tracer":

  test "newBufferEmitter then finish returns empty string for no events":
    var e = newBufferEmitter()
    check e.finish() == ""
