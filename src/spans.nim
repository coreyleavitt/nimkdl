## spans — source positions, spans, structured parse errors, and a
## no-exception `Result[T, E]` sum-type.
##
## The parser surface is exception-free by design: every fallible operation
## returns `Result[T, ParseError]`. This is what lets the parser run at
## compile time via `{.noSideEffect.}` — Nim's effect tracking forbids
## raising across a noSideEffect boundary, so an exception-based parser
## couldn't fuel the `parse[T]` / `embed[T]` macros (#528, #529).
##
## All public procs in this module are `{.noSideEffect, raises: [].}`.

import std/strutils

type
  Position* = object
    ## Source position. `line` and `col` are 1-based for human-readable
    ## diagnostics; `offset` is 0-based byte index for tooling that needs
    ## to slice the source.
    line*: int
    col*: int
    offset*: int

  Span* = object
    ## Half-open source range `[start, finish)`. `finish == start` is a
    ## point span used when an error is associated with a single position
    ## (e.g. "expected something here") rather than a span of source.
    start*: Position
    finish*: Position

  ParseErrorCode* = enum
    ## Stable categorization of parse failures. Extend as new failure
    ## modes appear in subsequent lib/kdl subsystems — the wire shape
    ## (code + span + hint) stays constant.

    # Lexer (#521)
    peLexUnexpectedChar       ## byte the lexer can't classify
    peLexUnterminatedString   ## ran off end of input mid-string
    peLexInvalidEscape        ## bad escape sequence inside a string
    peLexInvalidNumber        ## malformed numeric literal
    peLexInvalidIdentifier    ## bare-word that can't form an identifier
    peLexReservedKeyword      ## bare ident matches a v2 reserved keyword
                              ## (true/false/null/inf/-inf/nan) — must be
                              ## quoted or `#`-prefixed per spec
    peReservedTypeInvalid     ## value content fails the standard
                              ## interpretation of its reserved type
                              ## annotation (RFC/ISO/IEEE per tag)

    # Parser (#523)
    peParseUnexpected         ## token where none was expected
    peParseExpected           ## hole where a specific shape was expected
    peParseDepthExceeded      ## recursion past MaxParserDepth

    # Type-driven codegen (#528, #529)
    peTypeUnknownField        ## KDL field absent from the target Nim type
    peTypeMismatch            ## KDL value's type incompatible with field
    peTypeMissingRequired     ## required field omitted, no default
    peTypeEnumInvalid         ## string doesn't match any enum member
    peTypeDiscriminatorBad    ## object-variant discriminator unrecognized

    # Generic catch-all (avoid in new code — add a specific code instead)
    peOther

  ParseError* = object
    ## Structured error. `hint` is human-readable supplementary text —
    ## "did you mean ..." style. Empty hint is fine; renderer just omits it.
    code*: ParseErrorCode
    span*: Span
    hint*: string

  ResultKind* = enum
    rkOk, rkErr

  Result*[T, E] = object
    ## Sum-typed `Ok(T)` / `Err(E)` result. Hand-rolled rather than pulling
    ## a results library — one file of stdlib-shaped surface vs a transitive
    ## dep we don't need elsewhere.
    ##
    ## `Result[void, E]` is a valid specialization: the `rkOk` branch has
    ## no payload, only the discriminator. Use `ok(void, E)` to construct.
    case kind*: ResultKind
    of rkOk:
      when T isnot void:
        value*: T
    of rkErr:
      error*: E

# ---------------------------------------------------------------------------
# Position / Span constructors and arithmetic
# ---------------------------------------------------------------------------

const StartPosition* = Position(line: 1, col: 1, offset: 0)
  ## Lexer's starting position before reading any input.

func initPosition*(line, col, offset: int): Position {.inline.} =
  Position(line: line, col: col, offset: offset)

func initSpan*(start, finish: Position): Span {.inline.} =
  Span(start: start, finish: finish)

func pointSpan*(p: Position): Span {.inline.} =
  ## Zero-width span at a single position — for "expected X here" errors.
  Span(start: p, finish: p)

func advance*(p: Position, ch: char): Position {.inline.} =
  ## Move past a single byte. Newline (`\n`) bumps line + resets col;
  ## carriage return (`\r`) is ignored on the column count — KDL v2's
  ## newline taxonomy is broader than just `\n` but the lexer (#521)
  ## will normalize before reaching this helper.
  if ch == '\n':
    Position(line: p.line + 1, col: 1, offset: p.offset + 1)
  else:
    Position(line: p.line, col: p.col + 1, offset: p.offset + 1)

func advance*(p: Position, s: string): Position =
  ## Advance through a multi-character string. Used by the lexer when
  ## consuming a token whose internal bytes don't matter for position
  ## tracking (e.g. an identifier).
  result = p
  for ch in s:
    result = result.advance(ch)

func `$`*(p: Position): string {.inline.} =
  $p.line & ":" & $p.col

func `$`*(s: Span): string =
  if s.start == s.finish:
    $s.start
  else:
    $s.start & "-" & $s.finish

# ---------------------------------------------------------------------------
# ParseError constructors + rendering
# ---------------------------------------------------------------------------

func initError*(code: ParseErrorCode, span: Span, hint = ""): ParseError {.inline.} =
  ParseError(code: code, span: span, hint: hint)

func initError*(code: ParseErrorCode, pos: Position, hint = ""): ParseError {.inline.} =
  ParseError(code: code, span: pointSpan(pos), hint: hint)

func codeMessage*(code: ParseErrorCode): string =
  ## One-line human-readable summary per code. Kept inline (not localized,
  ## not table-driven) so adding a new code lights up a non-exhaustive-case
  ## warning here as a forcing function.
  case code
  of peLexUnexpectedChar:    "unexpected character"
  of peLexUnterminatedString:"unterminated string literal"
  of peLexInvalidEscape:     "invalid escape sequence"
  of peLexInvalidNumber:     "malformed number literal"
  of peLexInvalidIdentifier: "invalid identifier"
  of peLexReservedKeyword:   "reserved keyword used as bare identifier"
  of peReservedTypeInvalid:  "value does not match its reserved type annotation"
  of peParseUnexpected:      "unexpected token"
  of peParseExpected:        "expected token not found"
  of peParseDepthExceeded:   "nesting depth exceeded"
  of peTypeUnknownField:     "unknown field for target type"
  of peTypeMismatch:         "value type mismatch"
  of peTypeMissingRequired:  "required field missing"
  of peTypeEnumInvalid:      "value not in declared enum"
  of peTypeDiscriminatorBad: "unrecognized variant discriminator"
  of peOther:                "parse error"

func lineSlice(source: string, line: int): string =
  ## Extract the Nth (1-based) line of `source`, without the terminator.
  ## Returns empty string when line is out of range — caller decides
  ## whether to render anything in that case.
  if line < 1: return ""
  var current = 1
  var start = 0
  for i, ch in source:
    if current == line and ch == '\n':
      return source[start ..< i]
    if ch == '\n':
      inc current
      start = i + 1
  if current == line:
    return source[start ..< source.len]
  result = ""

func formatError*(err: ParseError, source: string, filename = ""): string =
  ## Render a caret-pointer diagnostic:
  ##
  ##   error: <code message>
  ##     --> <filename>:<line>:<col>
  ##      |
  ##    N | <source line>
  ##      |       ^^^^ <hint>
  ##
  ## Mirrors rustc's compact style — easy to read in terminal output
  ## and easy to parse for editor integrations later.
  let pos = err.span.start
  let lineText = lineSlice(source, pos.line)
  let codeMsg = codeMessage(err.code)
  let location =
    if filename.len > 0: filename & ":" & $pos
    else: $pos
  let gutter = $pos.line
  let pad = " ".repeat(gutter.len)

  # Caret width: clamp to the line's bounds, default to 1 for zero-width spans.
  let caretStart = max(0, pos.col - 1)
  let caretEnd = if err.span.finish.line == pos.line:
                   max(caretStart + 1, err.span.finish.col - 1)
                 else:
                   max(caretStart + 1, lineText.len)
  let caretWidth = max(1, caretEnd - caretStart)

  var buf = "error: " & codeMsg & "\n"
  buf.add("  --> " & location & "\n")
  buf.add(pad & " |\n")
  buf.add(gutter & " | " & lineText & "\n")
  buf.add(pad & " | " & " ".repeat(caretStart) & "^".repeat(caretWidth))
  if err.hint.len > 0:
    buf.add(" " & err.hint)
  buf.add("\n")
  buf

# ---------------------------------------------------------------------------
# Result helpers — generic, inline, no-overhead
# ---------------------------------------------------------------------------

func ok*[T, E](value: T): Result[T, E] {.inline.} =
  Result[T, E](kind: rkOk, value: value)

func ok*[E](_: typedesc[void]; _: typedesc[E]): Result[void, E] {.inline.} =
  ## Construct `Result[void, E].Ok` — for procs that signal "success
  ## without a payload, or this error". Use as `ok(void, MyErr)`.
  Result[void, E](kind: rkOk)

func err*[T, E](error: E): Result[T, E] {.inline.} =
  Result[T, E](kind: rkErr, error: error)

func isOk*[T, E](r: Result[T, E]): bool {.inline.} = r.kind == rkOk
func isErr*[T, E](r: Result[T, E]): bool {.inline.} = r.kind == rkErr

func get*[T, E](r: Result[T, E]): T {.inline.} =
  ## Unwrap. Caller is responsible for checking `isOk` first; misuse is
  ## a programmer error (FieldDefect from the variant access).
  r.value

func getErr*[T, E](r: Result[T, E]): E {.inline.} =
  r.error

# ---------------------------------------------------------------------------
# Combinators on Result — the applicative-style ergonomics that callers
# previously had to write inline. `try?` is the workhorse: it turns
# `if r.isErr: return err[U, E](r.getErr); ... use r.get ...` into one
# line. `map` / `flatMap` / `mapErr` cover the rest.
# ---------------------------------------------------------------------------

func map*[T, U, E](r: Result[T, E], fn: proc(v: T): U {.noSideEffect.}):
    Result[U, E] {.inline.} =
  ## Apply `fn` to the Ok payload; pass Err through unchanged.
  if r.isErr: err[U, E](r.error)
  else: ok[U, E](fn(r.value))

func mapErr*[T, E, F](r: Result[T, E], fn: proc(e: E): F {.noSideEffect.}):
    Result[T, F] {.inline.} =
  ## Apply `fn` to the Err payload; pass Ok through unchanged.
  if r.isOk: ok[T, F](r.value)
  else: err[T, F](fn(r.error))

func flatMap*[T, U, E](r: Result[T, E],
                       fn: proc(v: T): Result[U, E] {.noSideEffect.}):
    Result[U, E] {.inline.} =
  ## Sequence two Result-returning steps; aka `andThen` in some
  ## ecosystems.
  if r.isErr: err[U, E](r.error)
  else: fn(r.value)

# Note: a `?`-style early-return template (e.g. `let v = tryGet
# someCall()`) was considered. Nim's template hygiene around `result`-
# typed inference made the void / non-void cases require two separate
# templates with different signatures — more complexity than the
# explicit `if r.isErr: return err(...)` form, which is also more
# greppable. Keeping the explicit form; `map` / `flatMap` / `mapErr`
# above cover the chained-pure-functions case where you don't want
# to early-return.
