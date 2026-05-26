## Tests for spans.nim — Position/Span arithmetic, ParseError shape,
## Result helpers, and diagnostic formatting.
##
## Post-compaction shape: Position is a single `uint32` offset; (line, col)
## is derived lazily from `LineMap.lineColOf(offset)`. Tests reflect that
## split — arithmetic verifies offsets; line/col verifies the LineMap.

import std/[strutils, unittest]

import ../src/spans

suite "Position arithmetic":
  test "starting position":
    check StartPosition.offset == 0

  test "advance over a single byte":
    let p = StartPosition.advance('a')
    check p.offset == 1

  test "advance over a string advances offset by len":
    let p = StartPosition.advance("foo\nbar")
    check p.offset == 7

  test "$ on position is byte offset":
    check $initPosition(99) == "@99"

suite "LineMap":
  test "single-line source: every offset is line 1":
    let lm = buildLineMap("hello world")
    let (line, col) = lm.lineColOf(6)
    check line == 1
    check col == 7

  test "multi-line source maps offsets to line/col":
    let lm = buildLineMap("abc\ndef\nghi")
    check lm.lineColOf(0) == (1, 1)
    check lm.lineColOf(2) == (1, 3)
    check lm.lineColOf(4) == (2, 1)   # first byte after first '\n'
    check lm.lineColOf(8) == (3, 1)

  test "offset past end clamps to last line":
    let lm = buildLineMap("abc")
    let (line, _) = lm.lineColOf(999)
    check line == 1

suite "Span":
  test "point span has equal start/finish":
    let s = pointSpan(StartPosition)
    check s.start == s.finish

  test "$ on point span renders single offset":
    let s = pointSpan(initPosition(10))
    check $s == "@10"

  test "$ on multi-position span shows range":
    let s = initSpan(initPosition(0), initPosition(4))
    check $s == "@0+4"   # span renders as offset+length

suite "ParseError":
  test "initError from span":
    let e = initError(peLexUnexpectedChar,
                      pointSpan(initPosition(14)),
                      "did you mean ';'?")
    check e.code == peLexUnexpectedChar
    check e.span.offset == 14
    check e.hint == "did you mean ';'?"

  test "initError from position promotes to point span":
    let p = initPosition(0)
    let e = initError(peParseExpected, p)
    check e.span == pointSpan(p)
    check e.hint == ""

  test "every code has a non-empty message":
    for code in ParseErrorCode.low .. ParseErrorCode.high:
      check codeMessage(code).len > 0

suite "Result[T, E]":
  test "ok carries value":
    let r = ok[int, string](42)
    check r.isOk
    check not r.isErr
    check r.get == 42

  test "err carries error":
    let r = err[int, string]("boom")
    check r.isErr
    check not r.isOk
    check r.getErr == "boom"

  test "ok/err distinguish by kind":
    let a = ok[string, int]("hello")
    let b = err[string, int](7)
    check a.kind == rkOk
    check b.kind == rkErr

suite "Result combinators (M4)":
  test "map: Ok composes":
    let r = ok[int, string](7)
    let mapped = r.map(proc(v: int): int = v * 2)
    check mapped.isOk
    check mapped.get == 14

  test "map: Err passes through unchanged":
    let r = err[int, string]("boom")
    let mapped = r.map(proc(v: int): int = v * 2)
    check mapped.isErr
    check mapped.getErr == "boom"

  test "mapErr: Err transforms":
    let r = err[int, string]("oops")
    let mapped = r.mapErr(proc(e: string): int = e.len)
    check mapped.isErr
    check mapped.getErr == 4

  test "mapErr: Ok passes through unchanged":
    let r = ok[int, string](7)
    let mapped = r.mapErr(proc(e: string): int = e.len)
    check mapped.isOk
    check mapped.get == 7

  test "flatMap: sequences two Result-returning steps":
    proc step(v: int): Result[string, string] =
      if v > 0: ok[string, string]("positive")
      else: err[string, string]("non-positive")
    let r = ok[int, string](5).flatMap(step)
    check r.isOk
    check r.get == "positive"
    let r2 = ok[int, string](-1).flatMap(step)
    check r2.isErr
    check r2.getErr == "non-positive"

  test "flatMap: initial Err short-circuits":
    proc step(v: int): Result[string, string] = ok[string, string]("never")
    let r = err[int, string]("upstream").flatMap(step)
    check r.isErr
    check r.getErr == "upstream"

suite "formatError diagnostic":
  test "renders code, location, source line, and caret":
    let src = "rule \"foo\" @action {\n  predicate true\n}\n"
    # error on the '@' at offset 11 (line 1, col 12)
    let e = initError(peLexUnexpectedChar,
                      pointSpan(initPosition(11)),
                      "did you mean ';' or '{'?")
    let rendered = formatError(e, src, "rules.kdl")
    check "error: unexpected character" in rendered
    check "rules.kdl:1:12" in rendered
    check "rule \"foo\" @action {" in rendered
    check "^" in rendered
    check "did you mean ';' or '{'?" in rendered

  test "renders without filename when omitted":
    let src = "abc\n"
    let e = initError(peLexUnexpectedChar, pointSpan(initPosition(0)))
    let rendered = formatError(e, src)
    check "1:1" in rendered
    check "rules.kdl" notin rendered

  test "caret width spans the error range":
    let src = "abcdef\n"
    let e = initError(peLexInvalidIdentifier,
                      initSpan(initPosition(1), initPosition(4)))
    let rendered = formatError(e, src)
    # Three carets for the span [1, 4)
    check "^^^" in rendered

  test "out-of-range offset still renders without crashing":
    let src = "only one line\n"
    let e = initError(peParseUnexpected,
                      pointSpan(initPosition(999)))
    let rendered = formatError(e, src)
    check rendered.contains("error:")

  test "hint is omitted from caret line when empty":
    let src = "abc\n"
    let e = initError(peLexInvalidNumber,
                      pointSpan(initPosition(0)))
    let rendered = formatError(e, src)
    let lines = rendered.splitLines()
    let caretLine = lines[^2]
    check caretLine.strip(chars = {' '}).endsWith("^")
