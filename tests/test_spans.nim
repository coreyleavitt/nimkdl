## Tests for spans.nim — Position/Span arithmetic, ParseError shape,
## Result helpers, and diagnostic formatting.

import std/[strutils, unittest]

import ../src/spans

suite "Position arithmetic":
  test "starting position":
    check StartPosition.line == 1
    check StartPosition.col == 1
    check StartPosition.offset == 0

  test "advance over non-newline byte":
    let p = StartPosition.advance('a')
    check p.line == 1
    check p.col == 2
    check p.offset == 1

  test "advance over newline":
    var p = StartPosition.advance('x').advance('y')
    p = p.advance('\n')
    check p.line == 2
    check p.col == 1
    check p.offset == 3

  test "advance over a string":
    let p = StartPosition.advance("foo\nbar")
    check p.line == 2
    check p.col == 4   # "bar" => col advances 3 from start-of-line
    check p.offset == 7

  test "$ on position is line:col (1-based)":
    check $initPosition(5, 12, 99) == "5:12"

suite "Span":
  test "point span has equal start/finish":
    let s = pointSpan(StartPosition)
    check s.start == s.finish

  test "$ on point span is single position":
    check $pointSpan(initPosition(3, 4, 10)) == "3:4"

  test "$ on multi-position span shows range":
    let s = initSpan(initPosition(1, 1, 0), initPosition(1, 5, 4))
    check $s == "1:1-1:5"

suite "ParseError":
  test "initError from span":
    let e = initError(peLexUnexpectedChar,
                      pointSpan(initPosition(2, 5, 14)),
                      "did you mean ';'?")
    check e.code == peLexUnexpectedChar
    check e.span.start.line == 2
    check e.hint == "did you mean ';'?"

  test "initError from position promotes to point span":
    let p = initPosition(1, 1, 0)
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
    # error on the '@' at line 1, col 12
    let e = initError(peLexUnexpectedChar,
                      pointSpan(initPosition(1, 12, 11)),
                      "did you mean ';' or '{'?")
    let rendered = formatError(e, src, "rules.kdl")
    check "error: unexpected character" in rendered
    check "rules.kdl:1:12" in rendered
    check "rule \"foo\" @action {" in rendered
    check "^" in rendered
    check "did you mean ';' or '{'?" in rendered

  test "renders without filename when omitted":
    let src = "abc\n"
    let e = initError(peLexUnexpectedChar, pointSpan(initPosition(1, 1, 0)))
    let rendered = formatError(e, src)
    check "1:1" in rendered
    check "rules.kdl" notin rendered

  test "caret width spans the error range":
    let src = "abcdef\n"
    let e = initError(peLexInvalidIdentifier,
                      initSpan(initPosition(1, 2, 1), initPosition(1, 5, 4)))
    let rendered = formatError(e, src)
    # Three carets for the span [2,5)
    check "^^^" in rendered

  test "out-of-range line still renders without crashing":
    let src = "only one line\n"
    let e = initError(peParseUnexpected,
                      pointSpan(initPosition(99, 1, 999)))
    let rendered = formatError(e, src)
    check "99:1" in rendered
    # Source line is empty; renderer shows what it can
    check rendered.contains("error:")

  test "hint is omitted from caret line when empty":
    let src = "abc\n"
    let e = initError(peLexInvalidNumber,
                      pointSpan(initPosition(1, 1, 0)))
    let rendered = formatError(e, src)
    # No trailing description on the caret row
    let lines = rendered.splitLines()
    let caretLine = lines[^2]   # last non-empty line is the caret row
    check caretLine.strip(chars = {' '}).endsWith("^")
