## Property tests for src/cursor.nim — the token-cursor primitive.
##
## Gated by NKDL_PROPTEST=1 (see nkdl.nimble), same as the other
## property suites. Invariants tested here exercise behaviors no
## example test can rigorously establish:
##
## 1. **Termination**: for any input, advance() called repeatedly
##    eventually returns ceEof. No infinite loop, no crash, no
##    unhandled exception. Tests against random bytes + against
##    deliberately-encoded KDL.
##
## 2. **Bracket balance**: NodeBegin/NodeEnd pairs match, as do
##    ChildrenBegin/ChildrenEnd and SlashdashBegin/SlashdashEnd
##    pairs. Holds unless ceError was emitted (single-shot mode
##    short-circuits — that's the contract).
##
## 3. **Idempotence at EOF**: once advance() returns ceEof, further
##    calls keep returning ceEof. The stream is monotonic in this
##    sense.
##
## 4. **Encode→cursor round-trip well-formedness**: for any value
##    decodable from a known type, encoding it produces text the
##    cursor traverses without error.

import std/unittest

import proptest except Span    # datasource.Span collides with spans.Span

import ../src/cursor
import ../src/encode
import ../src/codegen
import ../src/intern
import ../src/lexer

const MaxCursorSteps = 10_000  ## guard against unbounded advance loops

type Recorder = object
  events: seq[CursorEventKind]
  sawError: bool

proc run(src: string, mode = cmSingle): Recorder =
  ## Drive the cursor over `src` to completion (or step-cap),
  ## recording the event kinds.
  var interner = initInterner()
  var stream = new(TokenStream)
  stream[] = lex(src, interner)
  var c = initStringCursor(addr stream[], src, mode = mode)
  var n = 0
  while n < MaxCursorSteps:
    let ev = advance(c)
    result.events.add(ev.kind)
    inc n
    if ev.kind == ceEof: return
    if ev.kind == ceError: result.sawError = true

# Types under test for the encode-round-trip property.
kdl:
  type
    Box {.kdlNode: "box".} = object
      label {.kdlArg.}: string
      n {.kdlProp.}: int

suite "cursor properties — robustness over arbitrary bytes":
  property "advance() always terminates without throwing":
    given s in strings(intervals(@[(0'i32, 127'i32)]), 0, 64)
    let r = run(s)
    ensure r.events.len > 0
    ensure r.events[^1] == ceEof

  property "advance() terminates with ceEof in single-shot mode":
    given s in strings(intervals(@[(0'i32, 127'i32)]), 0, 64)
    let r = run(s)
    ensure r.events[^1] == ceEof

  property "advance() terminates in accumulating mode too":
    given s in strings(intervals(@[(0'i32, 127'i32)]), 0, 64)
    let r = run(s, mode = cmAccumulating)
    ensure r.events[^1] == ceEof

suite "cursor properties — bracket balance":
  property "NodeBegin / NodeEnd are balanced on clean inputs":
    given v in arbitrary(Box)
    let textR = encode(v); ensure textR.isOk
    let r = run(textR.get)
    ensure not r.sawError
    var nb, ne = 0
    for k in r.events:
      if k == ceNodeBegin: inc nb
      elif k == ceNodeEnd: inc ne
    ensure nb == ne

  property "ChildrenBegin / ChildrenEnd are balanced on clean inputs":
    given v in arbitrary(Box)
    let textR = encode(v); ensure textR.isOk
    let r = run(textR.get)
    ensure not r.sawError
    var cb, ce = 0
    for k in r.events:
      if k == ceChildrenBegin: inc cb
      elif k == ceChildrenEnd: inc ce
    ensure cb == ce

  property "SlashdashBegin / SlashdashEnd are balanced on clean inputs":
    given v in arbitrary(Box)
    let textR = encode(v); ensure textR.isOk
    let r = run(textR.get)
    ensure not r.sawError
    var sb, se = 0
    for k in r.events:
      if k == ceSlashdashBegin: inc sb
      elif k == ceSlashdashEnd: inc se
    ensure sb == se

suite "cursor properties — idempotence at EOF":
  property "advance() past ceEof keeps returning ceEof":
    given s in strings(intervals(@[(0'i32, 127'i32)]), 0, 32)
    var interner = initInterner()
    var stream = new(TokenStream)
    stream[] = lex(s, interner)
    var c = initStringCursor(addr stream[], s)
    # Drive until first ceEof.
    var n = 0
    while n < MaxCursorSteps:
      let ev = advance(c)
      inc n
      if ev.kind == ceEof: break
    # Now ceEof should keep being returned.
    for _ in 0 ..< 4:
      ensure advance(c).kind == ceEof
