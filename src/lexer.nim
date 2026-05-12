## lexer — KDL v2 tokenizer (https://kdl.dev/spec/).
##
## Hand-written, no regex (per project_no_libpcre — std/re fails at runtime
## in the dev container, hand-written matchers are the convention).
##
## ## What's tokenized
##
## - Punctuation: `{`, `}`, `=`, `;`, `(`, `)`, `/-` (slashdash)
## - Newlines (any of LF, CRLF, CR — line-significant tokens for KDL)
## - Bare identifiers (per v2 spec's bare-ident charset)
## - Quoted identifiers (regular string syntax used as an identifier)
## - Strings: regular `"..."`, raw `#"..."#` (any `#` count), multi-line
##   `"""<NL>...<NL>"""` and raw multi-line `#"""<NL>...<NL>"""#`
## - Numbers: decimal (with underscores), hex `0x...`, octal `0o...`,
##   binary `0b...`, with optional `-`/`+` sign
## - Keywords: `#true`, `#false`, `#null`, `#inf`, `#-inf`, `#nan`
## - Escape sequences in regular strings: `\n \t \r \" \\ \s \b \f`
##   plus `\u{XXXX}` (1-6 hex digits, surrogate range rejected)
## - Line continuation `\` followed by newline (consumed; no token emitted)
##
## ## What's consumed but not emitted
##
## - ASCII whitespace (space, tab) between tokens
## - Single-line `//` comments
## - Block `/* ... */` comments (nested supported)
## - Line continuations (`\` + newline)
##
## ## Errors
##
## Lexer errors are emitted as `tkError` tokens carrying a `ParseError`.
## The lexer never raises and never returns Err — error recovery is the
## parser's job (it can re-sync and continue, surfacing all errors at once).

import std/[strutils, unicode]

import ./spans
import ./intern

const
  MaxRawStringHashes* = 255

  ReservedBarewords* = [
    "true", "false", "null", "inf", "-inf", "nan"
  ] ## KDL v2 forbids these as bare identifiers in *any* position (node
    ## name, property key, or value); they must be `#`-prefixed (booleans/
    ## null/special floats) or quoted (string values). Centralized here so
    ## parser, reference interpreter, and encoder agree.
    ## Maximum number of `#` characters allowed at the start of a raw
    ## string literal (`#"..."#`, `##"..."##`, …). KDL imposes no spec
    ## limit, but matching closing-hash scans are O(H * N) over the
    ## body and an unbounded `H` is an easy DoS vector against the
    ## lexer when parsing untrusted documents. KDL configs in the
    ## wild use 0–4 hashes; 255 is comfortably above any plausible
    ## use while keeping the scan bounded.

type
  TokenKind* = enum
    # Punctuation
    tkLBrace          ## `{`
    tkRBrace          ## `}`
    tkEquals          ## `=`
    tkSemicolon       ## `;`
    tkLParen          ## `(` — always a type-annotation open in KDL v2
    tkRParen          ## `)` — always a type-annotation close in KDL v2
    tkSlashDash       ## `/-` (rule/node/entry skip)
    tkNewline         ## one logical newline (LF, CRLF, CR all collapse to this)
    # Values
    tkIdent           ## bare or quoted identifier — value in `ident` (interned)
    tkString          ## regular or multi-line string — value in `strVal`
    tkRawString       ## raw or raw-multi-line string — value in `strVal`
    tkNumber          ## numeric literal — raw text + base + sign in fields
    tkKeyword         ## `#true` / `#false` / `#null` / `#inf` / `#-inf` / `#nan`
    # Sentinels
    tkError           ## diagnostics carried inline in the token stream
    tkEof             ## sentinel at end of input

  NumberBase* = enum
    nbDecimal, nbHex, nbOctal, nbBinary

  KeywordKind* = enum
    kwTrue, kwFalse, kwNull, kwInf, kwNegInf, kwNan

  Token* = object
    span*: Span
    precededByWs*: bool
      ## True if any whitespace, comment, newline-token, semicolon, or
      ## line-continuation preceded this token (or it is the first token
      ## in the stream). Set by the lexer; consumed by the parser at
      ## entry-position sites to enforce the v2 spec's token-adjacency
      ## rules (corpus `zero_space_before_*_fail`).
    case kind*: TokenKind
    of tkIdent:     ident*: InternedStr
    of tkString:    strVal*: string
    of tkRawString: rawVal*: string
    of tkNumber:
      numText*: string
      numBase*: NumberBase
      numNegative*: bool
    of tkKeyword:   keyword*: KeywordKind
    of tkError:     error*: ParseError
    else:           discard

  Lexer = object
    ## Lexer state during a `lex(source, interner)` call. The interner
    ## is NOT a field — it's threaded as a `var Interner` parameter
    ## through the few procs that intern. This keeps the Lexer
    ## `ptr`-free so the whole tokenization can run in Nim's VM at
    ## compile time (enables `embed[T]`'s real const evaluation).
    source: string
    pos: Position
    tokens: seq[Token]
    wsPending: bool
      ## True if the next emitted token should be marked precededByWs.
      ## Initial state and after consuming any whitespace/comment/newline/
      ## semicolon/line-continuation/slashdash. Cleared on each emit.

# ---------------------------------------------------------------------------
# Char classifiers
# ---------------------------------------------------------------------------

func isIdentStart(ch: char): bool {.inline.} =
  ## Bare identifiers in KDL v2 are quite permissive — almost anything
  ## that isn't punctuation, whitespace, or number-looking. The number-
  ## looking discrimination for `.` and `-` is handled at the call site
  ## via lookahead (lexOne). This implements the ASCII subset of the v2
  ## rule; full Unicode bare-ident coverage is filed as v0.2 work.
  case ch
  of '\0' .. ' ', '\x7f': false
  of '{', '}', '(', ')', '[', ']', '/', '\\', '"', '#', '=', ';', ',': false
  of '0' .. '9': false  # would look like the start of a number
  else: true

func isIdentCont(ch: char): bool {.inline.} =
  case ch
  of '\0' .. ' ', '\x7f': false
  of '{', '}', '(', ')', '[', ']', '/', '\\', '"', '#', '=', ';', ',': false
  else: true

func isAsciiWhitespace(ch: char): bool {.inline.} =
  ch == ' ' or ch == '\t'

func isWellFormedUtf8*(s: string): bool =
  ## Reject malformed UTF-8 sequences: over-long encodings, lone
  ## continuation bytes, truncated multi-byte sequences, surrogate
  ## halves encoded as 3-byte UTF-8, and codepoints above U+10FFFF.
  ##
  ## Pairs with `containsBidiControl` — the bidi denylist looks for
  ## the canonical 3-byte UTF-8 of forbidden codepoints. An attacker
  ## who encodes U+202E as the over-long 4-byte form `F0 82 80 AE`
  ## (leading byte 0xF0, not 0xE2) would bypass the denylist while
  ## any conforming renderer treats it identically. Reject the
  ## over-long form here so the denylist's coverage is sound.
  var i = 0
  while i < s.len:
    let b0 = uint8(s[i])
    if b0 < 0x80'u8:
      inc i
      continue
    var width: int
    var cp: int
    if (b0 and 0xE0'u8) == 0xC0'u8:
      width = 2; cp = int(b0 and 0x1F'u8)
      if b0 < 0xC2'u8: return false  # over-long 2-byte
    elif (b0 and 0xF0'u8) == 0xE0'u8:
      width = 3; cp = int(b0 and 0x0F'u8)
    elif (b0 and 0xF8'u8) == 0xF0'u8:
      width = 4; cp = int(b0 and 0x07'u8)
      if b0 > 0xF4'u8: return false  # > U+10FFFF
    else:
      return false  # continuation byte at lead position, or 5-/6-byte
    if i + width > s.len: return false
    for j in 1 ..< width:
      let bj = uint8(s[i + j])
      if (bj and 0xC0'u8) != 0x80'u8: return false  # not a continuation
      cp = (cp shl 6) or int(bj and 0x3F'u8)
    # Reject over-long encodings: codepoint must require the byte width
    # we just consumed.
    case width
    of 2:
      if cp < 0x80: return false
    of 3:
      if cp < 0x800: return false
      if cp >= 0xD800 and cp <= 0xDFFF: return false  # surrogate range
    of 4:
      if cp < 0x10000: return false
      if cp > 0x10FFFF: return false
    else: discard
    inc i, width
  true

func isDisallowedControl*(b: char): bool {.inline.} =
  ## True if `b` is a byte the KDL v2 spec forbids appearing literally
  ## anywhere in the document — including inside quoted/raw string bodies.
  ## The forbidden set is U+0000-U+0008, U+000E-U+001F, U+007F. (U+0009
  ## TAB and U+000A LF / U+000D CR are allowed; the latter are handled by
  ## newline taxonomy elsewhere; VT/FF are newline characters per the v2
  ## spec, not body bytes.)
  let u = uint8(b)
  (u <= 0x08'u8) or (u >= 0x0E'u8 and u <= 0x1F'u8) or (u == 0x7F'u8)

func containsBidiControl*(s: string): bool =
  ## True if `s` contains any of the 10 Unicode bidirectional control
  ## codepoints that the KDL v2 spec rejects in identifiers and most
  ## other source positions:
  ##
  ##   U+200E LEFT-TO-RIGHT MARK            E2 80 8E
  ##   U+200F RIGHT-TO-LEFT MARK            E2 80 8F
  ##   U+202A LEFT-TO-RIGHT EMBEDDING       E2 80 AA
  ##   U+202B RIGHT-TO-LEFT EMBEDDING       E2 80 AB
  ##   U+202C POP DIRECTIONAL FORMATTING    E2 80 AC
  ##   U+202D LEFT-TO-RIGHT OVERRIDE        E2 80 AD
  ##   U+202E RIGHT-TO-LEFT OVERRIDE        E2 80 AE
  ##   U+2066 LEFT-TO-RIGHT ISOLATE         E2 81 A6
  ##   U+2067 RIGHT-TO-LEFT ISOLATE         E2 81 A7
  ##   U+2068 FIRST STRONG ISOLATE          E2 81 A8
  ##   U+2069 POP DIRECTIONAL ISOLATE       E2 81 A9
  ##
  ## Scans the raw UTF-8 bytes — avoids pulling std/unicode for what's a
  ## small fixed denylist.
  var i = 0
  while i + 2 < s.len:
    if s[i] == '\xE2':
      if s[i+1] == '\x80':
        let b2 = uint8(s[i+2])
        if b2 == 0x8E or b2 == 0x8F or
           (b2 >= 0xAA and b2 <= 0xAE):
          return true
      elif s[i+1] == '\x81':
        let b2 = uint8(s[i+2])
        if b2 >= 0xA6 and b2 <= 0xA9:
          return true
    inc i
  false

func isHexDigit(ch: char): bool {.inline.} =
  case ch
  of '0'..'9', 'a'..'f', 'A'..'F': true
  else: false

func hexDigitVal(ch: char): int {.inline.} =
  case ch
  of '0'..'9': int(ord(ch) - ord('0'))
  of 'a'..'f': int(ord(ch) - ord('a') + 10)
  of 'A'..'F': int(ord(ch) - ord('A') + 10)
  else: -1

# ---------------------------------------------------------------------------
# Position helpers
# ---------------------------------------------------------------------------

func atEof(lx: Lexer): bool {.inline.} =
  lx.pos.offset >= lx.source.len

func peek(lx: Lexer, ahead = 0): char {.inline.} =
  let i = lx.pos.offset + ahead
  if i < lx.source.len: lx.source[i] else: '\0'

proc advanceOne(lx: var Lexer) =
  lx.pos = lx.pos.advance(lx.source[lx.pos.offset])

proc advanceNewline(lx: var Lexer) =
  ## Consume one logical newline. CRLF is treated as a single newline
  ## (one position bump, not two) so line numbers are stable across
  ## Windows-style files.
  let ch = lx.peek
  if ch == '\r' and lx.peek(1) == '\n':
    # CRLF: bump line via the LF, advance offset twice
    lx.pos = Position(line: lx.pos.line + 1, col: 1, offset: lx.pos.offset + 2)
  elif ch == '\r' or ch == '\n':
    lx.pos = Position(line: lx.pos.line + 1, col: 1, offset: lx.pos.offset + 1)
  else:
    discard

func isNewline(ch: char): bool {.inline.} =
  ch == '\n' or ch == '\r'

# ---------------------------------------------------------------------------
# Token emission
# ---------------------------------------------------------------------------

proc emit(lx: var Lexer, tok: sink Token) =
  var t = tok
  t.precededByWs = lx.wsPending
  lx.tokens.add(t)
  # Structural tokens that semantically end a "phrase" implicitly grant
  # the next token wsPending. tkNewline, tkSemicolon, and tkSlashDash all
  # act like whitespace as far as entry-adjacency is concerned.
  case t.kind
  of tkNewline, tkSemicolon, tkSlashDash:
    lx.wsPending = true
  else:
    lx.wsPending = false

proc emitError(lx: var Lexer, code: ParseErrorCode, span: Span, hint = "") =
  lx.emit(Token(kind: tkError, span: span,
                error: initError(code, span, hint)))

# ---------------------------------------------------------------------------
# Whitespace + comments
# ---------------------------------------------------------------------------

proc skipBlockComment(lx: var Lexer): bool =
  ## Caller has already consumed the opening `/*`. Consumes through the
  ## matching `*/`, handling nested comments per spec. Returns false (and
  ## emits an error token at the start) if EOF hits first.
  let start = lx.pos
  # Reposition `start` to the `/*` so the error span points there
  let startSpan = initSpan(
    Position(line: start.line, col: start.col - 2, offset: start.offset - 2),
    start)
  var depth = 1
  while depth > 0:
    if lx.atEof:
      lx.emitError(peLexUnterminatedString, startSpan,
                   "unterminated /* … */ block comment")
      return false
    let ch = lx.peek
    if ch == '/' and lx.peek(1) == '*':
      lx.advanceOne(); lx.advanceOne()
      inc depth
    elif ch == '*' and lx.peek(1) == '/':
      lx.advanceOne(); lx.advanceOne()
      dec depth
    elif isNewline(ch):
      lx.advanceNewline()
    else:
      lx.advanceOne()
  true

proc skipLineComment(lx: var Lexer) =
  ## Caller consumed `//`. Consume to end of line (not including the newline).
  while not lx.atEof and not isNewline(lx.peek):
    lx.advanceOne()

proc skipLineContinuation(lx: var Lexer): bool =
  ## At a `\` candidate. If followed by optional whitespace, an optional
  ## comment (line `//...` or block `/* ... */`), and a newline, consume
  ## the lot and return true. Otherwise rewind and return false — the
  ## caller will handle `\` as an unexpected character.
  let save = lx.pos
  if lx.peek != '\\': return false
  lx.advanceOne()
  while not lx.atEof and isAsciiWhitespace(lx.peek):
    lx.advanceOne()
  # Optional comment between `\` and the line break
  if not lx.atEof and lx.peek == '/' and lx.peek(1) == '/':
    lx.advanceOne(); lx.advanceOne()
    while not lx.atEof and not isNewline(lx.peek):
      lx.advanceOne()
  elif not lx.atEof and lx.peek == '/' and lx.peek(1) == '*':
    lx.advanceOne(); lx.advanceOne()
    if not lx.skipBlockComment():
      return false
  if not lx.atEof and isNewline(lx.peek):
    lx.advanceNewline()
    return true
  if lx.atEof:
    # `\` at EOF (possibly after intervening whitespace/comments) — spec
    # corpus `eof_after_escape.kdl` requires this to parse cleanly as if
    # the continuation ended at an implicit final newline.
    return true
  # Not a line continuation; rewind and let the caller error on `\`.
  lx.pos = save
  false

proc skipWhitespaceAndComments(lx: var Lexer) =
  ## Consume runs of whitespace + comments + line continuations. Stops
  ## at the first significant byte (or EOF). Newlines are NOT consumed
  ## here — they're significant tokens to KDL's grammar.
  ## Sets `wsPending` so the next emitted token records that whitespace
  ## preceded it (token-adjacency enforcement at the parser layer).
  let entryPos = lx.pos.offset
  while not lx.atEof:
    let ch = lx.peek
    if isAsciiWhitespace(ch):
      lx.advanceOne()
    elif ch == '/' and lx.peek(1) == '/':
      lx.advanceOne(); lx.advanceOne()
      lx.skipLineComment()
    elif ch == '/' and lx.peek(1) == '*':
      lx.advanceOne(); lx.advanceOne()
      if not lx.skipBlockComment(): return
    elif ch == '\\':
      if not lx.skipLineContinuation():
        if lx.pos.offset > entryPos: lx.wsPending = true
        return  # bare `\` — let caller handle as error
    else:
      if lx.pos.offset > entryPos: lx.wsPending = true
      return
  if lx.pos.offset > entryPos: lx.wsPending = true

# ---------------------------------------------------------------------------
# String escape decoding
# ---------------------------------------------------------------------------

proc decodeUnicodeEscape(lx: var Lexer, startSpan: Span): string =
  ## Caller has consumed `\u`. Expects `{XXXX}` with 1-6 hex digits.
  ## Rejects surrogate range (U+D800..U+DFFF) per spec.
  if lx.peek != '{':
    lx.emitError(peLexInvalidEscape, startSpan,
                 "\\u must be followed by {hex}")
    return ""
  lx.advanceOne()  # consume `{`
  var digits = 0
  var value = 0
  while not lx.atEof and lx.peek != '}':
    let ch = lx.peek
    if not isHexDigit(ch):
      lx.emitError(peLexInvalidEscape, startSpan,
                   "expected hex digit inside \\u{}")
      return ""
    value = value shl 4 or hexDigitVal(ch)
    inc digits
    if digits > 6:
      lx.emitError(peLexInvalidEscape, startSpan,
                   "\\u{} accepts at most 6 hex digits")
      return ""
    lx.advanceOne()
  if lx.atEof or lx.peek != '}':
    lx.emitError(peLexInvalidEscape, startSpan,
                 "unterminated \\u{} escape")
    return ""
  lx.advanceOne()  # consume `}`
  if digits == 0:
    lx.emitError(peLexInvalidEscape, startSpan,
                 "\\u{} requires at least one hex digit")
    return ""
  if value >= 0xD800 and value <= 0xDFFF:
    lx.emitError(peLexInvalidEscape, startSpan,
                 "surrogate code point in \\u{}; use the encoded codepoint instead")
    return ""
  if value > 0x10FFFF:
    lx.emitError(peLexInvalidEscape, startSpan,
                 "\\u{} codepoint above U+10FFFF")
    return ""
  result = $Rune(value)

type EscapeOutcome* = enum
  ## What `dispatchEscape` says about the escape sequence it just consumed:
  ##
  ## - `eoDecoded` — the escape produced bytes that have been appended to
  ##   the caller's accumulator (`\n`, `\t`, `\"`, `\u{…}`, etc.).
  ## - `eoWhitespaceEscape` — the byte after `\` is whitespace or a
  ##   newline. The caller is responsible for consuming the run; the
  ##   semantics differ between single-line strings (just drop the run)
  ##   and multi-line strings (split lines at newlines too).
  ## - `eoUnknown` — `\x` for some `x` that isn't a valid escape. An
  ##   error token has already been emitted; the caller advances past
  ##   the offending character.
  eoDecoded
  eoWhitespaceEscape
  eoUnknown

proc dispatchEscape*(lx: var Lexer, escSpan: Span,
                    acc: var string): EscapeOutcome =
  ## Handle one `\<x>` escape sequence shared between single-line and
  ## multi-line string decoding. The caller has already consumed the
  ## leading backslash; `escSpan` covers the two-byte `\<x>` span for
  ## error reporting.
  let esc = lx.peek
  case esc
  of 'n':  acc.add '\n'; lx.advanceOne(); eoDecoded
  of 't':  acc.add '\t'; lx.advanceOne(); eoDecoded
  of 'r':  acc.add '\r'; lx.advanceOne(); eoDecoded
  of '"':  acc.add '"';  lx.advanceOne(); eoDecoded
  of '\\': acc.add '\\'; lx.advanceOne(); eoDecoded
  of 'b':  acc.add '\b'; lx.advanceOne(); eoDecoded
  of 'f':  acc.add '\f'; lx.advanceOne(); eoDecoded
  of 's':  acc.add ' ';  lx.advanceOne(); eoDecoded
  of 'u':
    lx.advanceOne()
    acc.add lx.decodeUnicodeEscape(escSpan)
    eoDecoded
  of ' ', '\t', '\n', '\r':
    eoWhitespaceEscape
  else:
    lx.emitError(peLexInvalidEscape, escSpan, "unknown escape \\" & esc)
    lx.advanceOne()
    eoUnknown

proc decodeRegularString(lx: var Lexer, openSpan: Span,
                        terminator: char): string =
  ## Read a regular (non-raw) string body. Caller has already consumed
  ## the opening quote. Returns the decoded value; emits error token(s)
  ## on malformed escapes and on unterminated input.
  while true:
    if lx.atEof:
      lx.emitError(peLexUnterminatedString, openSpan,
                   "unterminated string literal")
      return result
    let ch = lx.peek
    if ch == terminator:
      lx.advanceOne()
      return result
    if isNewline(ch):
      lx.emitError(peLexUnterminatedString, openSpan,
                   "literal newline inside string; use \\n or \"\"\"…\"\"\"")
      return result
    if ch == '\\':
      let escStart = lx.pos
      lx.advanceOne()
      if lx.atEof:
        lx.emitError(peLexInvalidEscape, openSpan, "EOF after backslash")
        return result
      let escSpan = initSpan(escStart, Position(
        line: lx.pos.line, col: lx.pos.col + 1, offset: lx.pos.offset + 1))
      case lx.dispatchEscape(escSpan, result)
      of eoDecoded, eoUnknown:
        discard
      of eoWhitespaceEscape:
        # Single-line semantics: drop the whitespace run entirely.
        while not lx.atEof and
              (lx.peek == ' ' or lx.peek == '\t' or
               lx.peek == '\n' or lx.peek == '\r'):
          if isNewline(lx.peek): lx.advanceNewline() else: lx.advanceOne()
    else:
      if isDisallowedControl(ch):
        let s = lx.pos
        lx.advanceOne()
        lx.emitError(peLexUnexpectedChar, initSpan(s, lx.pos),
                     "disallowed literal control codepoint in string body")
        return result
      result.add ch
      lx.advanceOne()

# ---------------------------------------------------------------------------
# Strings: regular, raw, multi-line, raw multi-line
# ---------------------------------------------------------------------------

proc lexRegularOrMultiline(lx: var Lexer) =
  ## At the opening `"`. Distinguishes `"…"` from `"""…<NL>…<NL>…"""`.
  let start = lx.pos
  # Detect `"""` opening
  if lx.peek(1) == '"' and lx.peek(2) == '"':
    lx.advanceOne(); lx.advanceOne(); lx.advanceOne()
    # Multi-line: opening triple must be followed by a newline per spec.
    if not (not lx.atEof and isNewline(lx.peek)):
      let span = initSpan(start, lx.pos)
      lx.emitError(peLexInvalidIdentifier, span,
                   "opening \"\"\" must be followed by a newline")
      # Still try to consume to nearest """ to avoid runaway
      while not lx.atEof and
            not (lx.peek == '"' and lx.peek(1) == '"' and lx.peek(2) == '"'):
        if isNewline(lx.peek): lx.advanceNewline() else: lx.advanceOne()
      if not lx.atEof:
        lx.advanceOne(); lx.advanceOne(); lx.advanceOne()
      return
    lx.advanceNewline()
    # Accumulate raw line-text until we see the closing """
    var rawLines: seq[string] = @[]
    var currentLine = ""
    while not lx.atEof:
      if lx.peek == '"' and lx.peek(1) == '"' and lx.peek(2) == '"':
        rawLines.add(currentLine)
        lx.advanceOne(); lx.advanceOne(); lx.advanceOne()
        # Multi-line content per spec: strip the leading whitespace
        # matching the closing line's indentation from every prior line.
        let closingPrefix = rawLines[^1]
        # Validate the closing line is whitespace-only — if not, the
        # """ is mid-line which is malformed
        var valid = true
        for c in closingPrefix:
          if not (c == ' ' or c == '\t'):
            valid = false; break
        if not valid:
          let span = initSpan(start, lx.pos)
          lx.emitError(peLexUnterminatedString, span,
                       "closing \"\"\" must be on its own line")
          return
        # Strip closing-line indentation from each content line
        var decoded = ""
        for i in 0 ..< rawLines.len - 1:
          let line = rawLines[i]
          if i > 0: decoded.add('\n')
          if line.startsWith(closingPrefix):
            decoded.add(line[closingPrefix.len .. ^1])
          elif line.len == 0:
            # Empty lines keep being empty even if indent-shorter
            discard
          else:
            let span = initSpan(start, lx.pos)
            lx.emitError(peLexUnterminatedString, span,
                         "line content has less indent than closing \"\"\"")
            return
        lx.emit(Token(kind: tkString, strVal: decoded,
                      span: initSpan(start, lx.pos)))
        return
      if isNewline(lx.peek):
        rawLines.add(currentLine)
        currentLine = ""
        lx.advanceNewline()
      elif lx.peek == '\\':
        let escStart = lx.pos
        lx.advanceOne()
        if lx.atEof: break
        let escSpan = initSpan(escStart, Position(
          line: lx.pos.line, col: lx.pos.col + 1, offset: lx.pos.offset + 1))
        case lx.dispatchEscape(escSpan, currentLine)
        of eoDecoded, eoUnknown:
          discard
        of eoWhitespaceEscape:
          # Multi-line semantics: consume the whitespace run, but split
          # the accumulated line at every newline so the indentation-
          # strip pass treats them as separate source lines.
          while not lx.atEof and
                (lx.peek == ' ' or lx.peek == '\t' or
                 lx.peek == '\n' or lx.peek == '\r'):
            if isNewline(lx.peek):
              rawLines.add(currentLine)
              currentLine = ""
              lx.advanceNewline()
            else:
              lx.advanceOne()
      else:
        if isDisallowedControl(lx.peek):
          let sPos = lx.pos
          lx.advanceOne()
          lx.emitError(peLexUnexpectedChar, initSpan(sPos, lx.pos),
                       "disallowed literal control codepoint in string body")
          return
        currentLine.add lx.peek
        lx.advanceOne()
    # EOF before close
    let span = initSpan(start, lx.pos)
    lx.emitError(peLexUnterminatedString, span,
                 "unterminated multi-line string")
    return

  # Regular single-line string
  let openSpan = initSpan(start, Position(
    line: start.line, col: start.col + 1, offset: start.offset + 1))
  lx.advanceOne()  # consume opening "
  let decoded = lx.decodeRegularString(openSpan, '"')
  lx.emit(Token(kind: tkString, strVal: decoded,
                span: initSpan(start, lx.pos)))

proc lexRawString(lx: var Lexer) =
  ## At the opening `#`. Count `#`s, then either find `"` (raw string)
  ## or fall back to keyword/error handling in the caller.
  let start = lx.pos
  var hashCount = 0
  while lx.peek == '#':
    inc hashCount
    lx.advanceOne()
    # DoS guard: a crafted `####…###"<body>"` input with very large H and
    # body length N runs an O(H*N) inner loop on every `"` in the body
    # (security review H3). KDL has no realistic need for more than a
    # handful of `#`s — Rust's reference impl uses 4 max in practice.
    # Cap at 255; emit a structured error past the limit rather than
    # silently grinding.
    if hashCount > MaxRawStringHashes:
      let span = initSpan(start, lx.pos)
      lx.emitError(peLexInvalidIdentifier, span,
                   "raw string opener has more than " &
                   $MaxRawStringHashes & " '#' characters")
      # Consume any remaining hashes to avoid downstream tokenization
      # confusion on the same input.
      while lx.peek == '#': lx.advanceOne()
      return
  if lx.atEof or lx.peek != '"':
    # Not a raw string — rewind and let caller try keyword/error
    lx.pos = start
    return  # caller checks for `#` and decides
  lx.advanceOne()  # consume opening "
  # Check for `"""` for raw multi-line
  if lx.peek == '"' and lx.peek(1) == '"':
    lx.advanceOne(); lx.advanceOne()
    # Multi-line raw: must be followed by newline
    if not (not lx.atEof and isNewline(lx.peek)):
      let span = initSpan(start, lx.pos)
      lx.emitError(peLexInvalidIdentifier, span,
                   "opening #\"\"\"… must be followed by a newline")
      return
    lx.advanceNewline()
    var rawLines: seq[string] = @[]
    var currentLine = ""
    while not lx.atEof:
      # Check for terminator `"""` followed by `hashCount` `#`s
      if lx.peek == '"' and lx.peek(1) == '"' and lx.peek(2) == '"':
        # Verify the trailing # count matches
        var i = 3
        while i < 3 + hashCount and
              lx.pos.offset + i < lx.source.len and
              lx.source[lx.pos.offset + i] == '#':
          inc i
        if i == 3 + hashCount:
          rawLines.add(currentLine)
          for _ in 0 ..< 3 + hashCount:
            lx.advanceOne()
          let closingPrefix = rawLines[^1]
          var valid = true
          for c in closingPrefix:
            if not (c == ' ' or c == '\t'):
              valid = false; break
          if not valid:
            let span = initSpan(start, lx.pos)
            lx.emitError(peLexUnterminatedString, span,
                         "closing #\"\"\"… must be on its own line")
            return
          var decoded = ""
          for j in 0 ..< rawLines.len - 1:
            let line = rawLines[j]
            if j > 0: decoded.add('\n')
            if line.startsWith(closingPrefix):
              decoded.add(line[closingPrefix.len .. ^1])
            elif line.len == 0:
              discard
            else:
              let span = initSpan(start, lx.pos)
              lx.emitError(peLexUnterminatedString, span,
                           "line content has less indent than closing #\"\"\"…")
              return
          lx.emit(Token(kind: tkRawString, rawVal: decoded,
                        span: initSpan(start, lx.pos)))
          return
        else:
          # Not enough trailing hashes — treat as content
          currentLine.add lx.peek
          lx.advanceOne()
          continue
      if isNewline(lx.peek):
        rawLines.add(currentLine)
        currentLine = ""
        lx.advanceNewline()
      else:
        if isDisallowedControl(lx.peek):
          let sPos = lx.pos
          lx.advanceOne()
          lx.emitError(peLexUnexpectedChar, initSpan(sPos, lx.pos),
                       "disallowed literal control codepoint in raw string body")
          return
        currentLine.add lx.peek
        lx.advanceOne()
    let span = initSpan(start, lx.pos)
    lx.emitError(peLexUnterminatedString, span,
                 "unterminated raw multi-line string")
    return

  # Single-line raw string: read until `"` followed by hashCount `#`s
  var body = ""
  while not lx.atEof:
    if lx.peek == '"':
      var i = 1
      while i <= hashCount and
            lx.pos.offset + i < lx.source.len and
            lx.source[lx.pos.offset + i] == '#':
        inc i
      if i == hashCount + 1:
        for _ in 0 ..< 1 + hashCount:
          lx.advanceOne()
        lx.emit(Token(kind: tkRawString, rawVal: body,
                      span: initSpan(start, lx.pos)))
        return
    if isNewline(lx.peek):
      let span = initSpan(start, lx.pos)
      lx.emitError(peLexUnterminatedString, span,
                   "literal newline inside single-line raw string")
      return
    if isDisallowedControl(lx.peek):
      let sPos = lx.pos
      lx.advanceOne()
      lx.emitError(peLexUnexpectedChar, initSpan(sPos, lx.pos),
                   "disallowed literal control codepoint in raw string body")
      return
    body.add lx.peek
    lx.advanceOne()
  let span = initSpan(start, lx.pos)
  lx.emitError(peLexUnterminatedString, span,
               "unterminated raw string")

# ---------------------------------------------------------------------------
# Numbers
# ---------------------------------------------------------------------------

proc lexNumber(lx: var Lexer) =
  ## Caller's already determined this looks like a number. Reads the
  ## whole literal including optional sign, base prefix, digits, and
  ## (decimal-only) fractional / exponent parts. Underscores are allowed
  ## anywhere within digits as separators.
  let start = lx.pos
  var negative = false
  if lx.peek == '+' or lx.peek == '-':
    negative = lx.peek == '-'
    lx.advanceOne()

  var base = nbDecimal
  if lx.peek == '0' and lx.peek(1) in {'x', 'X', 'o', 'O', 'b', 'B'}:
    case lx.peek(1)
    of 'x', 'X': base = nbHex
    of 'o', 'O': base = nbOctal
    of 'b', 'B': base = nbBinary
    else: discard
    lx.advanceOne(); lx.advanceOne()
    var sawDigit = false
    # First digit after the base prefix may not be `_` (e.g. `0x_FF`
    # is invalid per v2).
    if not lx.atEof and lx.peek == '_':
      let span = initSpan(start, lx.pos)
      lx.emitError(peLexInvalidNumber, span,
                   "underscore not allowed immediately after base prefix")
      return
    while not lx.atEof:
      let ch = lx.peek
      if ch == '_':
        lx.advanceOne(); continue
      let ok =
        case base
        of nbHex:    isHexDigit(ch)
        of nbOctal:  ch >= '0' and ch <= '7'
        of nbBinary: ch == '0' or ch == '1'
        else:        false
      if not ok: break
      sawDigit = true
      lx.advanceOne()
    if not sawDigit:
      let span = initSpan(start, lx.pos)
      lx.emitError(peLexInvalidNumber, span,
                   "number literal has no digits")
      return
    # Reject `0xFFg` / `0o7a` / `0b10x` — non-base ident chars after a
    # base-prefixed literal. Same logic as the decimal path's trailing
    # ident-cont check.
    if not lx.atEof and isIdentCont(lx.peek):
      let span = initSpan(start, lx.pos.advance(lx.peek))
      lx.emitError(peLexInvalidNumber, span,
                   "non-base digit in numeric literal")
      return
    let span = initSpan(start, lx.pos)
    lx.emit(Token(kind: tkNumber, numText: lx.source[start.offset ..< lx.pos.offset],
                  numBase: base, numNegative: negative, span: span))
    return

  # Decimal integer part
  var sawDigit = false
  while not lx.atEof:
    let ch = lx.peek
    if ch == '_':
      lx.advanceOne(); continue
    if ch >= '0' and ch <= '9':
      sawDigit = true; lx.advanceOne()
    else:
      break

  # Optional fractional part. If the `.` is present, a digit MUST follow
  # (`1.` and `1.e10` are rejected; the v1 leniency of "trailing dot is OK"
  # is gone in v2).
  var hasFraction = false
  if lx.peek == '.':
    hasFraction = true
    lx.advanceOne()
    if lx.atEof or lx.peek < '0' or lx.peek > '9':
      let span = initSpan(start, lx.pos)
      lx.emitError(peLexInvalidNumber, span,
                   "fractional part requires a digit after '.'")
      return
    # Reject `1._5` (underscore at start of fraction)
    if lx.peek == '_':
      let span = initSpan(start, lx.pos)
      lx.emitError(peLexInvalidNumber, span,
                   "fraction cannot start with '_'")
      return
    while not lx.atEof:
      let ch = lx.peek
      if ch == '_':
        lx.advanceOne(); continue
      if ch >= '0' and ch <= '9':
        sawDigit = true; lx.advanceOne()
      else:
        break

  # Optional exponent. Same rules — at least one digit, no leading underscore.
  if lx.peek == 'e' or lx.peek == 'E':
    lx.advanceOne()
    if lx.peek == '+' or lx.peek == '-':
      lx.advanceOne()
    if lx.atEof or lx.peek < '0' or lx.peek > '9':
      let span = initSpan(start, lx.pos)
      lx.emitError(peLexInvalidNumber, span,
                   "exponent requires a digit")
      return
    # Reject `1e_5` (underscore at start of exponent)
    if lx.peek == '_':
      let span = initSpan(start, lx.pos)
      lx.emitError(peLexInvalidNumber, span,
                   "exponent cannot start with '_'")
      return
    var expDigit = false
    while not lx.atEof:
      let ch = lx.peek
      if ch == '_':
        lx.advanceOne(); continue
      if ch >= '0' and ch <= '9':
        expDigit = true; lx.advanceOne()
      else:
        break
    if not expDigit:
      let span = initSpan(start, lx.pos)
      lx.emitError(peLexInvalidNumber, span, "exponent has no digits")
      return

  if not sawDigit:
    let span = initSpan(start, lx.pos)
    lx.emitError(peLexInvalidNumber, span, "number literal has no digits")
    return

  # Reject a number immediately followed by ident-continuation bytes
  # (`12abc`, `1_a`, `1.5xyz`). These look like bareword-with-digit-prefix
  # which v2 forbids in either direction — bare idents can't start with
  # a digit, and number literals can't be followed by ident chars
  # without a separator.
  if not lx.atEof and isIdentCont(lx.peek):
    let span = initSpan(start, lx.pos.advance(lx.peek))
    lx.emitError(peLexInvalidNumber, span,
                 "number literal followed by identifier character " &
                 "without separator")
    return

  let span = initSpan(start, lx.pos)
  lx.emit(Token(kind: tkNumber,
                numText: lx.source[start.offset ..< lx.pos.offset],
                numBase: base, numNegative: negative, span: span))

# ---------------------------------------------------------------------------
# Identifiers + keywords
# ---------------------------------------------------------------------------

proc lexBareIdent(lx: var Lexer, interner: var Interner) =
  let start = lx.pos
  while not lx.atEof and isIdentCont(lx.peek):
    lx.advanceOne()
  let text = lx.source[start.offset ..< lx.pos.offset]
  let span = initSpan(start, lx.pos)
  # KDL v2 forbids Unicode bidirectional control codepoints inside
  # identifiers (and basically everywhere outside strings) — they
  # let an attacker render an identifier differently from its bytes.
  # See containsBidiControl for the 10 forbidden codepoints.
  if containsBidiControl(text):
    lx.emitError(peLexInvalidIdentifier, span,
                 "bidirectional control codepoint in identifier")
    return
  # Legacy KDL v1 raw-string syntax: `r"..."` / `r#"..."#`. v2 requires
  # raw strings to start with `#"`, not `r"`. If the lexed ident is
  # exactly `r` (or `R`) and the next byte is `"` or `#` with no
  # whitespace between, reject — silently treating `r` as an ident
  # would let v1 docs accidentally parse with broken semantics.
  if (text == "r" or text == "R") and not lx.atEof and
     (lx.peek == '"' or lx.peek == '#'):
    lx.emitError(peLexInvalidIdentifier, span,
                 "KDL v1 raw-string syntax `r\"...\"` is not valid in v2; " &
                 "use `#\"...\"#` instead")
    return
  let handle = interner.intern(text)
  lx.emit(Token(kind: tkIdent, ident: handle, span: span))

proc lexKeyword(lx: var Lexer) =
  ## At a `#` known not to start a raw string. Read identifier-like bytes
  ## and match against the six v2 keywords; emit tkError otherwise.
  let start = lx.pos
  lx.advanceOne()  # consume `#`
  # Optionally consume a `-` for `#-inf`
  let textStart = lx.pos
  if lx.peek == '-':
    lx.advanceOne()
  while not lx.atEof and isIdentCont(lx.peek):
    lx.advanceOne()
  let text = lx.source[textStart.offset ..< lx.pos.offset]
  let span = initSpan(start, lx.pos)
  var matched = true
  var kw: KeywordKind
  case text
  of "true":  kw = kwTrue
  of "false": kw = kwFalse
  of "null":  kw = kwNull
  of "inf":   kw = kwInf
  of "-inf":  kw = kwNegInf
  of "nan":   kw = kwNan
  else:       matched = false
  if matched:
    lx.emit(Token(kind: tkKeyword, keyword: kw, span: span))
  else:
    lx.emitError(peLexInvalidIdentifier, span,
                 "expected #true / #false / #null / #inf / #-inf / #nan")

# ---------------------------------------------------------------------------
# Top-level loop
# ---------------------------------------------------------------------------

proc lexOne(lx: var Lexer, interner: var Interner) =
  if lx.atEof:
    lx.emit(Token(kind: tkEof, span: pointSpan(lx.pos)))
    return
  # BOM mid-file: U+FEFF (EF BB BF) is only allowed as the very first
  # bytes of the source. By the time we reach lexOne, the offset-0 BOM
  # has been consumed in `lex()`. Anywhere else is a structural error.
  if lx.peek == '\xEF' and lx.peek(1) == '\xBB' and lx.peek(2) == '\xBF':
    let s = lx.pos
    lx.advanceOne(); lx.advanceOne(); lx.advanceOne()
    lx.emitError(peLexUnexpectedChar, initSpan(s, lx.pos),
                 "byte-order mark allowed only at start of file")
    return
  let ch = lx.peek
  case ch
  of '{':
    let s = lx.pos; lx.advanceOne()
    lx.emit(Token(kind: tkLBrace, span: initSpan(s, lx.pos)))
  of '}':
    let s = lx.pos; lx.advanceOne()
    lx.emit(Token(kind: tkRBrace, span: initSpan(s, lx.pos)))
  of '=':
    let s = lx.pos; lx.advanceOne()
    lx.emit(Token(kind: tkEquals, span: initSpan(s, lx.pos)))
  of ';':
    let s = lx.pos; lx.advanceOne()
    lx.emit(Token(kind: tkSemicolon, span: initSpan(s, lx.pos)))
  of '(':
    let s = lx.pos; lx.advanceOne()
    lx.emit(Token(kind: tkLParen, span: initSpan(s, lx.pos)))
  of ')':
    let s = lx.pos; lx.advanceOne()
    lx.emit(Token(kind: tkRParen, span: initSpan(s, lx.pos)))
  of '/':
    if lx.peek(1) == '-':
      let s = lx.pos; lx.advanceOne(); lx.advanceOne()
      lx.emit(Token(kind: tkSlashDash, span: initSpan(s, lx.pos)))
    else:
      let s = lx.pos; lx.advanceOne()
      lx.emitError(peLexUnexpectedChar, initSpan(s, lx.pos),
                   "expected '/-' (slashdash)")
  of '\n', '\r':
    let s = lx.pos
    lx.advanceNewline()
    lx.emit(Token(kind: tkNewline, span: initSpan(s, lx.pos)))
  of '"':
    lx.lexRegularOrMultiline()
  of '#':
    # Could be raw string `#"..."` (with N # prefixes) or keyword `#true` etc.
    let save = lx.pos
    lx.lexRawString()
    if lx.pos == save:
      lx.lexKeyword()
  of '0' .. '9':
    lx.lexNumber()
  of '+', '-':
    # Sign followed by a digit → number; otherwise bare ident
    if lx.peek(1) >= '0' and lx.peek(1) <= '9':
      lx.lexNumber()
    else:
      lx.lexBareIdent(interner)
  else:
    # `.` followed by a digit looks like a number-without-int-prefix
    # (`.0`), which v2 forbids — emit as an error rather than letting
    # it become a bare ident. `.` followed by anything else is a fine
    # ident start (e.g. `.` alone is a valid bare ident).
    if ch == '.' and lx.peek(1) >= '0' and lx.peek(1) <= '9':
      let s = lx.pos; lx.advanceOne()
      lx.emitError(peLexInvalidNumber, initSpan(s, lx.pos),
                   "number literals need an integer part before the '.'")
      return
    if isIdentStart(ch):
      lx.lexBareIdent(interner)
    else:
      let s = lx.pos; lx.advanceOne()
      lx.emitError(peLexUnexpectedChar, initSpan(s, lx.pos),
                   "unexpected character '" & $ch & "'")

proc lex*(source: string, interner: var Interner): seq[Token]
    {.noSideEffect.} =
  ## Tokenize `source`. Always returns a stream terminated by `tkEof`.
  ## Errors are surfaced as `tkError` tokens with embedded `ParseError`
  ## diagnostics; the parser handles re-sync.
  ##
  ## `interner` is threaded as a `var` parameter through the few internal
  ## procs that actually intern (just `lexBareIdent`). No `ptr` field in
  ## the Lexer struct — keeps the whole tokenizer VM-callable so the
  ## parser chain runs at compile time via `embed[T]`.
  var lx = Lexer(source: source, pos: StartPosition, tokens: @[],
                 wsPending: true)  # start of input counts as preceded by ws
  # Reject malformed UTF-8 up front — checked once over the whole input
  # so downstream lexing can assume byte-by-byte iteration is safe.
  # Pairs with `containsBidiControl` to prevent denylist bypass via
  # over-long encodings or surrogate halves.
  if not isWellFormedUtf8(source):
    lx.emitError(peLexUnexpectedChar, pointSpan(StartPosition),
                 "input is not well-formed UTF-8")
    lx.emit(Token(kind: tkEof, span: pointSpan(StartPosition)))
    return lx.tokens
  # Skip BOM (U+FEFF, encoded as EF BB BF) at start of input — per
  # KDL v2 spec it's silently consumed at position 0 but flagged as an
  # error if it appears later. We handle the start-of-input case here.
  if lx.source.len >= 3 and
     lx.source[0] == '\xEF' and lx.source[1] == '\xBB' and
     lx.source[2] == '\xBF':
    lx.pos = Position(line: 1, col: 1, offset: 3)
  while not lx.atEof:
    lx.skipWhitespaceAndComments()
    if lx.atEof: break
    lx.lexOne(interner)
  if lx.tokens.len == 0 or lx.tokens[^1].kind != tkEof:
    lx.emit(Token(kind: tkEof, span: pointSpan(lx.pos)))
  result = lx.tokens
