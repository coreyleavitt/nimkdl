## Stage F1-F2 — safety properties.
##
## - **P11: deriveDecode never crashes on arbitrary bytes.** Random
##   string input goes through `decode[T]`; the contract is: returns
##   Ok or Err, never raises, never IndexDefects, never infinite-
##   loops.
## - **P12: emitter never produces unparseable bytes** (lands in F2).
##
## These tests run only when `NKDL_PROPTEST=1` is set so the default
## `nimble test` (and CI without the proptest dep) stays self-
## contained. Local dev: `milpa fetch` then
## `NKDL_PROPTEST=1 nimble test`.

import std/unittest

import proptest

import ../src/api
import ../src/cursor
import ../src/emitter
import ../src/intern
import ../src/kdl_block
import ../src/lexer
import ../src/pragmas

proc parseAllEventKinds(src: string): seq[CursorEventKind] =
  ## Drive a cursor over `src` to EOF, return the event-kind sequence.
  ## A ceError appearing means the bytes are unparseable — what P12
  ## must prevent.
  var interner = initInterner()
  var sref: ref TokenStream
  new(sref)
  sref[] = lex(src, interner)
  var c = initStringCursor(addr sref[], src)
  while true:
    let ev = advance(c)
    result.add(ev.kind)
    if ev.kind == ceEof: break

kdl:
  type Service {.kdlNode: "service".} = object
    name {.kdlArg.}: string
    port {.kdlProp.}: int
    enabled {.kdlProp.}: bool

suite "P11 — deriveDecode never crashes on arbitrary bytes":

  property "decode[Service] returns Ok or Err for any string input":
    with Settings(maxExamples: 200, testId: "p11-decode-service")
    given src in strings(0, 200)
    let r = decode[Service](src)
    ensure r.isOk or r.isErr

  property "decode[Service] survives KDL-syntax-rich byte alphabets":
    # Bias the alphabet toward characters that trigger KDL-special
    # lex paths: whitespace control codes, braces, slashes, quotes,
    # backslashes, equals, hash, semicolons, parens. This is where
    # crashes hide if any error-path is missing.
    with Settings(maxExamples: 300, testId: "p11-decode-service-kdl-rich")
    given src in strings(intervals([
      (0x09'i32, 0x0d'i32),    # TAB, LF, VT, FF, CR
      (0x20'i32, 0x7e'i32),    # printable ASCII (brackets, quotes, etc.)
      (0x00a0'i32, 0x00ff'i32) # Latin-1 supplement
    ]), 0, 200)
    let r = decode[Service](src)
    ensure r.isOk or r.isErr

  property "decode[seq[Service]] never crashes on arbitrary input":
    with Settings(maxExamples: 200, testId: "p11-decode-seq-service")
    given src in strings(0, 200)
    let r = decode[seq[Service]](src)
    ensure r.isOk or r.isErr

  property "decodeAll[seq[Service]] never crashes on arbitrary input":
    # decodeAll's recovery loop adds an additional crash surface
    # (checkpoint replay + skip mid-stream). Cover it explicitly.
    with Settings(maxExamples: 200, testId: "p11-decode-all")
    given src in strings(0, 200)
    let pair = decodeAll[seq[Service]](src)
    ensure pair.value.len >= 0  # no exception escaped the recovery loop

suite "P12 — emitter never produces unparseable bytes":

  property "bare node with arbitrary string arg round-trips through cursor":
    # Strings are the highest-risk arg type — escaping rules cover
    # backslash, quotes, control codes, and the bareword vs quoted
    # boundary. If pushArgString gets any escape wrong, the cursor
    # rejects the output.
    with Settings(maxExamples: 300, testId: "p12-arg-string")
    given s in strings(0, 100)
    var e = newBufferEmitter()
    e.pushNodeBegin("n")
    e.pushArgString(s)
    e.pushNodeEnd()
    let events = parseAllEventKinds(e.finish())
    ensure ceError notin events

  property "arbitrary int arg round-trips through cursor":
    with Settings(maxExamples: 200, testId: "p12-arg-int")
    given n in integers(low(int64), high(int64))
    var e = newBufferEmitter()
    e.pushNodeBegin("n")
    e.pushArgInt(n)
    e.pushNodeEnd()
    let events = parseAllEventKinds(e.finish())
    ensure ceError notin events

  property "arbitrary float arg round-trips through cursor":
    # Includes ±Inf and NaN. KDL has `#inf` / `#-inf` / `#nan`
    # keyword forms; pushArgFloat must route them correctly.
    with Settings(maxExamples: 200, testId: "p12-arg-float")
    given f in floats()
    var e = newBufferEmitter()
    e.pushNodeBegin("n")
    e.pushArgFloat(f)
    e.pushNodeEnd()
    let events = parseAllEventKinds(e.finish())
    ensure ceError notin events

  property "arbitrary string prop key + string value round-trip":
    # Property keys go through the same bareword-vs-quoted decision
    # as node names. Symmetrically risky.
    with Settings(maxExamples: 300, testId: "p12-prop-string-string")
    given key in strings(1, 32), val in strings(0, 64)
    var e = newBufferEmitter()
    e.pushNodeBegin("n")
    e.pushPropString(key, val)
    e.pushNodeEnd()
    let events = parseAllEventKinds(e.finish())
    ensure ceError notin events

  property "mixed args (int / string / bool / null) round-trip":
    with Settings(maxExamples: 200, testId: "p12-mixed-args")
    given i in integers(-1_000_000, 1_000_000),
          s in strings(0, 32),
          b in booleans()
    var e = newBufferEmitter()
    e.pushNodeBegin("n")
    e.pushArgInt(i)
    e.pushArgString(s)
    e.pushArgBool(b)
    e.pushArgNull()
    e.pushNodeEnd()
    let events = parseAllEventKinds(e.finish())
    ensure ceError notin events
