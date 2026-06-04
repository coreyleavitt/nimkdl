## spans — source positions, spans, structured parse errors, and a
## no-exception `Result[T, E]` sum-type.
##
## ## Compact-span design
##
## A `Position` is a single `uint32` byte offset into the source. A
## `Span` is `(offset: uint32, length: uint16)`. The (line, col)
## coordinates that humans see in error messages are reconstructed
## lazily from the offset via a `LineMap` built once per source.
##
## This shrinks `Position` from 24 → 4 bytes and `Span` from 48 → 8
## bytes vs the prior `{line, col, offset}` shape. The savings cascade
## into `Token`, `KdlNode`, `KdlValue` — each carries spans, all benefit.
##
## ## Compile-time parsing
##
## The parser surface is exception-free by design: every fallible
## operation returns `Result[T, ParseError]`. This is what lets the
## parser run at compile time via `{.noSideEffect.}` — Nim's effect
## tracking forbids raising across a noSideEffect boundary, so an
## exception-based parser couldn't fuel the `parse[T]` / `embed[T]`
## macros.

import std/strutils

type
  Position* = object
    ## 0-based byte offset into the source. Line and column are NOT
    ## stored — they're reconstructed by `LineMap.lineColOf` when
    ## error rendering needs them.
    ##
    ## Stored as `int` for ergonomic interop with `string.len` and
    ## other size types throughout the codebase. `Position` is a *view*
    ## type — it's NOT what gets packed into `Span` for the cache-line
    ## benefit (that's the raw fields on `Span` itself).
    offset*: int

  Span* = object
    ## Half-open source range `[offset, offset + length)`. `length == 0`
    ## is a point span used when an error is associated with a single
    ## position rather than a region.
    ##
    ## Storage: 4-byte offset + 4-byte length = 8 bytes exactly. The
    ## length was originally uint16 (capping a single token at 64 KiB)
    ## but real-world multiline strings can legitimately exceed that;
    ## promoting to uint32 costs zero storage (the alignment padding
    ## was already 8) and removes the silent-truncation edge case.
    offsetRaw*: uint32
    lengthRaw*: uint32

  LineMap* = object
    ## Maps byte offsets to (line, col). Built once per source by
    ## scanning for newlines; O(n) construction, O(log n) lookup.
    ## Owned by the parsed document (or the parser, for error paths).
    sourceLen*: int
    lineStarts*: seq[int]  ## byte offset of each line's first char.
                           ## Always `[0, ...]` (line 1 starts at 0).

  ParseErrorCode* = enum
    ## Stable categorization of parse failures. **The integer values are an
    ## explicit, stable wire/conformance contract (rfc-core-rebuild §10): new
    ## codes APPEND with the next free value — never renumber or insert in the
    ## middle. `test_error_codes` pins these.**
    peLexUnexpectedChar    = 0
    peLexUnterminatedString = 1
    peLexInvalidEscape     = 2
    peLexInvalidNumber     = 3
    peLexInvalidIdentifier = 4
    peLexReservedKeyword   = 5
    peReservedTypeInvalid  = 6
    peTypeReservedMismatch = 7
    peParseUnexpected      = 8
    peParseExpected        = 9
    peParseDepthExceeded   = 10
    peTypeUnknownField     = 11
    peTypeMismatch         = 12
    peTypeMissingRequired  = 13
    peTypeEnumInvalid      = 14
    peTypeDiscriminatorBad = 15
    peEncodeUnsupported    = 16  ## the typed encoder doesn't support this
                           ## Nim shape (e.g. variant case-object types,
                           ## Option[T] on a kdlArg). Distinct from
                           ## peTypeMismatch (which means a value's KDL
                           ## kind doesn't match its Nim field type) —
                           ## here the shape itself is the issue.
    peOther                = 17
    peTypeNoVariantMatch   = 18  ## a {.kdlUntagged.} case object's node matched
                           ## NONE of its `of`-branches: every branch's decode
                           ## attempt failed (wrong fields / wrong shape for that
                           ## branch). The discriminator is not on the wire, so
                           ## the decoder tried each branch in declaration order
                           ## and exhausted them. Distinct from
                           ## peTypeDiscriminatorBad (a TAGGED variant whose
                           ## explicit discriminator value names no branch).
    peIOError              = 19  ## the source could not be read from its backing
                           ## store (e.g. `decodeFile` on a missing/unreadable
                           ## path). Distinct from every lex/parse/type code:
                           ## the failure is at the I/O boundary, before any
                           ## bytes reached the lexer. Consumed by `decodeFile`
                           ## (rfc-consumer-api C2).

  ParseError* = object
    ## Structured error.
    ##
    ## Self-sufficient (rfc-consumer-api §4.4, gap B): `line`/`col`/`sourcePath`
    ## are filled **eagerly** at the outermost public entry point (via
    ## `enriched`) so the error is a value that outlives the source string —
    ## `$err` renders a full `path:line:col` location with no source re-pass.
    ## `Span` stays offset-only by design; (line, col) live on the *error*.
    code*: ParseErrorCode
    span*: Span
    line*, col*: int
      ## 1-based source coordinates. `0` until `enriched` fills them (the
      ## source-less state produced by `initError` at the ~168 call sites).
    sourcePath*: string
      ## Source attribution (e.g. `"config.kdl"`). Empty until `enriched`.
    hint*: string
    fieldPath*: seq[string]
      ## Typed-decode field path, outermost-first (e.g. `@["server", "listen"]`
      ## renders as `server.listen`). Empty for non-decode / top-level errors;
      ## enriched at each nested child-decode boundary (rfc §10).

  ResultKind* = enum
    rkOk, rkErr

  Result*[T, E] = object
    case kind*: ResultKind
    of rkOk:
      when T isnot void:
        value*: T
    of rkErr:
      error*: E

  Parsed*[T] = object
    ## Outcome of a recovering, multi-error parse (rfc-core-rebuild §8.1): a
    ## (possibly partial) value plus every error encountered while recovering.
    ## Replaces the bare `tuple[doc, errors]` so `decodeAll`/`buildDocAll` share
    ## one shape. `isComplete` iff no errors were collected.
    value*: T
    errors*: seq[ParseError]

func isComplete*[T](p: Parsed[T]): bool {.inline.} = p.errors.len == 0


# ---------------------------------------------------------------------------
# Position / Span constructors
# ---------------------------------------------------------------------------

const StartPosition* = Position(offset: 0)
  ## Position before reading any input.

func initPosition*(offset: int): Position {.inline.} =
  Position(offset: offset)

func offset*(s: Span): int {.inline.} = int(s.offsetRaw)
  ## Byte offset of span start.

func length*(s: Span): int {.inline.} = int(s.lengthRaw)
  ## Byte length of span. Zero-length = "point span".

func initSpan*(offset, length: int): Span {.inline.} =
  Span(offsetRaw: uint32(offset), lengthRaw: uint32(length))

func initSpan*(start, finish: Position): Span {.inline.} =
  ## Back-compat constructor — derive length from two endpoints.
  Span(offsetRaw: uint32(start.offset),
       lengthRaw: uint32(finish.offset - start.offset))

func pointSpan*(p: Position): Span {.inline.} =
  ## Zero-width span at a single position.
  Span(offsetRaw: uint32(p.offset), lengthRaw: 0)

func pointSpan*(offset: int): Span {.inline.} =
  Span(offsetRaw: uint32(offset), lengthRaw: 0)

func start*(s: Span): Position {.inline.} =
  ## Back-compat accessor — many callers wrote `span.start`.
  Position(offset: int(s.offsetRaw))

func finish*(s: Span): Position {.inline.} =
  ## Back-compat accessor — `span.finish` was the exclusive end.
  Position(offset: int(s.offsetRaw) + int(s.lengthRaw))

func endOffset*(s: Span): int {.inline.} =
  int(s.offsetRaw) + int(s.lengthRaw)

func advance*(p: Position, n: int = 1): Position {.inline.} =
  Position(offset: p.offset + n)

func advance*(p: Position, ch: char): Position {.inline.} =
  ## Single-byte advance. Newline handling is now a no-op at the
  ## Position layer — line tracking belongs to the LineMap, computed
  ## after lexing.
  Position(offset: p.offset + 1)

func advance*(p: Position, s: string): Position {.inline.} =
  Position(offset: p.offset + s.len)

func `==`*(a, b: Position): bool {.inline.} = a.offset == b.offset
func `==`*(a, b: Span): bool {.inline.} =
  a.offsetRaw == b.offsetRaw and a.lengthRaw == b.lengthRaw

func `<`*(a, b: Position): bool {.inline.} = a.offset < b.offset

func `$`*(p: Position): string {.inline.} =
  "@" & $p.offset

func `$`*(s: Span): string =
  if s.lengthRaw == 0:
    "@" & $s.offsetRaw
  else:
    "@" & $s.offsetRaw & "+" & $s.lengthRaw


# ---------------------------------------------------------------------------
# LineMap — offset → (line, col) reconstruction
# ---------------------------------------------------------------------------

func buildLineMap*(source: string): LineMap =
  ## Precompute line start offsets. O(n) once; subsequent lookups
  ## are O(log n) via binary search.
  result.sourceLen = source.len
  result.lineStarts = @[0]
  for i in 0 ..< source.len:
    if source[i] == '\n':
      result.lineStarts.add(i + 1)

func lineColOf*(lm: LineMap, offset: int): tuple[line: int, col: int] =
  ## Binary search for the line containing `offset`. Returns 1-based
  ## (line, col). Clamps to valid range — out-of-range offsets snap
  ## to source bounds rather than panicking.
  let n = lm.lineStarts.len
  if n == 0: return (1, 1)
  let off = max(0, offset)
  # Find largest lineStarts[i] <= off.
  var lo = 0
  var hi = n - 1
  while lo < hi:
    let mid = (lo + hi + 1) div 2
    if lm.lineStarts[mid] <= off: lo = mid
    else: hi = mid - 1
  return (lo + 1, off - lm.lineStarts[lo] + 1)

func lineColOf*(lm: LineMap, p: Position): tuple[line: int, col: int] {.inline.} =
  lm.lineColOf(int(p.offset))


# ---------------------------------------------------------------------------
# ParseError constructors + rendering
# ---------------------------------------------------------------------------

func initError*(code: ParseErrorCode, span: Span, hint = ""): ParseError {.inline.} =
  ParseError(code: code, span: span, hint: hint)

func initError*(code: ParseErrorCode, pos: Position, hint = ""): ParseError {.inline.} =
  ParseError(code: code, span: pointSpan(pos), hint: hint)

func withField*(e: ParseError, name: string): ParseError =
  ## Prepend `name` to the error's field path. Called at each nested child-decode
  ## boundary as the error unwinds, so the path reads outermost-first (rfc §10).
  result = e
  result.fieldPath.insert(name, 0)

func enriched*(err: ParseError, sourceText: string, sourcePath: string):
    ParseError {.raises: [].} =
  ## Fill `line`/`col`/`sourcePath` once, at the outermost public entry point
  ## (rfc-consumer-api §4.4 two-tier construction). `initError` keeps making a
  ## source-less error; `enriched` computes coordinates from the error's span
  ## offset against a freshly-built `LineMap` over `sourceText`. Error-path-only
  ## cost. Must stay `{.raises:[].}` — it is reachable from the decode surface.
  result = err
  let lm = buildLineMap(sourceText)
  let (line, col) = lm.lineColOf(err.span.offset)
  result.line = line
  result.col = col
  result.sourcePath = sourcePath

func enriched*(err: ParseError, lineMap: LineMap, sourcePath: string):
    ParseError {.raises: [].} =
  ## Same as `enriched(err, sourceText, sourcePath)` but reuses a **prebuilt**
  ## `LineMap` instead of scanning the source again. The node-by-node decode
  ## surface (`decodeNode(doc, node)`, `decodeChild`) calls this against the
  ## doc's once-built `doc.lineMap`, so decoding N nodes of an n-byte doc costs
  ## O(n + N·log n), not O(N·n) (review #3). Coordinates are identical to the
  ## source-text overload by construction — both compute `lineColOf(offset)`.
  result = err
  let (line, col) = lineMap.lineColOf(err.span.offset)
  result.line = line
  result.col = col
  result.sourcePath = sourcePath

func rebased*(err: ParseError, delta: int): ParseError {.raises: [].} =
  ## Return a copy whose span offset is shifted by `delta`. Used by N2 to turn
  ## a slice-local error offset into an absolute offset in the owning doc's
  ## source *before* `enriched` computes (line, col) — so coordinates reflect
  ## the original file position, not the slice. Length is preserved.
  result = err
  result.span = initSpan(err.span.offset + delta, err.span.length)

func codeMessage*(code: ParseErrorCode): string =
  case code
  of peLexUnexpectedChar:    "unexpected character"
  of peLexUnterminatedString:"unterminated string literal"
  of peLexInvalidEscape:     "invalid escape sequence"
  of peLexInvalidNumber:     "malformed number literal"
  of peLexInvalidIdentifier: "invalid identifier"
  of peLexReservedKeyword:   "reserved keyword used as bare identifier"
  of peReservedTypeInvalid:  "value does not match its reserved type annotation"
  of peTypeReservedMismatch: "source value's type annotation does not match the field's kdlReserved declaration"
  of peParseUnexpected:      "unexpected token"
  of peParseExpected:        "expected token not found"
  of peParseDepthExceeded:   "nesting depth exceeded"
  of peTypeUnknownField:     "unknown field for target type"
  of peTypeMismatch:         "value type mismatch"
  of peTypeMissingRequired:  "required field missing"
  of peTypeEnumInvalid:      "value not in declared enum"
  of peTypeDiscriminatorBad: "unrecognized variant discriminator"
  of peEncodeUnsupported:    "typed encoder does not support this Nim shape"
  of peOther:                "parse error"
  of peTypeNoVariantMatch:   "no untagged-variant branch matched the input"
  of peIOError:              "could not read source"

func lineSlice(source: string, line: int): string =
  if line < 1: return ""
  var current = 1
  var start = 0
  for i in 0 ..< source.len:
    let ch = source[i]
    if current == line and ch == '\n':
      return source[start ..< i]
    if ch == '\n':
      inc current
      start = i + 1
  if current == line:
    return source[start ..< source.len]
  result = ""

func formatError*(err: ParseError, source: string, filename = ""): string =
  ## Render a caret-pointer diagnostic. Builds a LineMap internally
  ## (error rendering is the rare path; the per-call O(n) scan is fine).
  let lm = buildLineMap(source)
  let (startLine, startCol) = lm.lineColOf(err.span.offset)
  let (finishLine, finishCol) = lm.lineColOf(err.span.offset + err.span.length)
  let lineText = lineSlice(source, startLine)
  let codeMsg = codeMessage(err.code)
  let location =
    if filename.len > 0: filename & ":" & $startLine & ":" & $startCol
    else: $startLine & ":" & $startCol
  let gutter = $startLine
  let pad = " ".repeat(gutter.len)

  let caretStart = max(0, startCol - 1)
  let caretEnd = if finishLine == startLine:
                   max(caretStart + 1, finishCol - 1)
                 else:
                   max(caretStart + 1, lineText.len)
  let caretWidth = max(1, caretEnd - caretStart)

  var buf = "error: " & codeMsg & "\n"
  buf.add("  --> " & location & "\n")
  if err.fieldPath.len > 0:
    buf.add("  in field: " & err.fieldPath.join(".") & "\n")
  buf.add(pad & " |\n")
  buf.add(gutter & " | " & lineText & "\n")
  buf.add(pad & " | " & " ".repeat(caretStart) & "^".repeat(caretWidth))
  if err.hint.len > 0:
    buf.add(" " & err.hint)
  buf.add("\n")
  buf

func `$`*(err: ParseError): string {.raises: [].} =
  ## Self-sufficient one-line rendering — no source argument needed
  ## (rfc-consumer-api §4.4). Renders `path:line:col: <message> (<dotted
  ## .fieldPath>)`, e.g. `config.kdl:14:5: expected int (daemon.server.listen)`.
  ## The message text is the error's `hint` when present, else the code's
  ## canonical message (matching `formatError`'s text without the caret block).
  ## `line`/`col`/`sourcePath` come from a prior `enriched` call; an
  ## un-enriched error renders `:0:0:` (the honest source-less state).
  let location = err.sourcePath & ":" & $err.line & ":" & $err.col
  let message = if err.hint.len > 0: err.hint else: codeMessage(err.code)
  result = location & ": " & message
  if err.fieldPath.len > 0:
    result.add(" (" & err.fieldPath.join(".") & ")")


# ---------------------------------------------------------------------------
# Result helpers
# ---------------------------------------------------------------------------

proc ok*[T, E](value: sink T): Result[T, E] {.inline.} =
  ## Sink parameter — the producer is at last-use of `value` here (it's
  ## almost always a freshly-built AST node) so we move it in. Without
  ## `sink`, every `ok(node)` deep-copied a KdlNode + its children
  ## subtree. Pair with `take` on the consumer side for end-to-end move.
  Result[T, E](kind: rkOk, value: value)

func ok*[E](_: typedesc[void]; _: typedesc[E]): Result[void, E] {.inline.} =
  Result[void, E](kind: rkOk)

proc err*[T, E](error: sink E): Result[T, E] {.inline.} =
  Result[T, E](kind: rkErr, error: error)

func isOk*[T, E](r: Result[T, E]): bool {.inline.} = r.kind == rkOk
func isErr*[T, E](r: Result[T, E]): bool {.inline.} = r.kind == rkErr

func get*[T, E](r: Result[T, E]): T {.inline.} = r.value
func getErr*[T, E](r: Result[T, E]): E {.inline.} = r.error

# Sink-explicit unwrap — caller asserts last-use of `r` so we move the
# payload out instead of copying. The discriminant on `case object`
# blocks ORC's automatic move-elision for `r.value`, so without this
# the parser's `nodes.add(nRes.get)` deep-copied the entire children
# subtree at every depth level — Σ N = O(N²) on a deep chain. Caught
# by perf record + flamegraph showing `eqcopy_(seq<KdlNode>)` at 19%
# of CPU on a deep-chain workload.
proc take*[T, E](r: sink Result[T, E]): T {.inline.} = move r.value
proc takeErr*[T, E](r: sink Result[T, E]): E {.inline.} = move r.error

func map*[T, U, E](r: Result[T, E], fn: proc(v: T): U {.noSideEffect.}):
    Result[U, E] {.inline.} =
  if r.isErr: err[U, E](r.error)
  else: ok[U, E](fn(r.value))

func mapErr*[T, E, F](r: Result[T, E], fn: proc(e: E): F {.noSideEffect.}):
    Result[T, F] {.inline.} =
  if r.isOk: ok[T, F](r.value)
  else: err[T, F](fn(r.error))

func flatMap*[T, U, E](r: Result[T, E],
                       fn: proc(v: T): Result[U, E] {.noSideEffect.}):
    Result[U, E] {.inline.} =
  if r.isErr: err[U, E](r.error)
  else: fn(r.value)
