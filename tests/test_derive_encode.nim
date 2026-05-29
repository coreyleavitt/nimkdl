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
