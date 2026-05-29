## Stage F5 / F12 / F13 — substrate-level properties.
##
## - **P3: cursor safety under arbitrary bytes.** Random byte input
##   never crashes, always terminates in ceEof or ceError. The
##   strongest robustness claim a parser substrate can make.
##
## - **P1: cursor ↔ emitter event round-trip** (lands in F12, needs
##   F11 grammar-aware generator).
##
## - **P2: source → events → bytes → events idempotence** (lands in
##   F13, needs F11).
##
## Gated by NKDL_PROPTEST=1.

import std/unittest

import proptest

import ../src/cursor
import ../src/intern
import ../src/lexer

proc driveToEof(src: string): bool =
  ## Drive a cursor over `src`. Returns true iff the cursor reached
  ## ceEof or emitted a ceError without raising. The strong claim is
  ## "completes without raising" — if any exception escapes, proptest
  ## fails the property.
  var interner = initInterner()
  var sref: ref TokenStream
  new(sref)
  sref[] = lex(src, interner)
  var c = initStringCursor(addr sref[], src)
  var steps = 0
  while true:
    let ev = advance(c)
    inc steps
    # Bounded-step guard: a cursor that emits more than ~10× the
    # input length per byte is almost certainly in a stall pattern.
    # If we ever trip this, it's a bug — not a property failure.
    if steps > 10 + src.len * 50:
      doAssert false, "cursor did not converge on input of length " &
                      $src.len
    if ev.kind == ceEof: return true
    # ceError is fine for arbitrary bytes; the property is only that
    # the cursor terminates without raising. Single-shot mode is the
    # default and ceError halts the stream.

suite "P3 — cursor safety on arbitrary bytes":

  property "cursor terminates without raising on any string input":
    with Settings(maxExamples: 300, testId: "p3-printable")
    given src in strings(0, 500)
    ensure driveToEof(src)

  property "cursor terminates on KDL-syntax-rich byte alphabets":
    # Bias toward bytes that drive lex/grammar special paths:
    # control codes (newlines, slashdash precursors), brackets,
    # slashes, quotes, hash, equals, parens, semicolons, dot.
    with Settings(maxExamples: 500, testId: "p3-kdl-rich")
    given src in strings(intervals([
      (0x09'i32, 0x0d'i32),
      (0x20'i32, 0x7e'i32),
      (0x00a0'i32, 0x00ff'i32)
    ]), 0, 500)
    ensure driveToEof(src)
