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
## - Escape sequences in regular strings: `\n \t \r \" \\ \/ \b \f`
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
    source: string
    pos: Position
    tokens: seq[Token]
    interner: ptr Interner

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
  lx.tokens.add(tok)

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
  # Not a line continuation; rewind and let the caller error on `\`.
  lx.pos = save
  false

proc skipWhitespaceAndComments(lx: var Lexer) =
  ## Consume runs of whitespace + comments + line continuations. Stops
  ## at the first significant byte (or EOF). Newlines are NOT consumed
  ## here — they're significant tokens to KDL's grammar.
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
        return  # bare `\` — let caller handle as error
    else:
      return

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
        lx.emitError(peLexInvalidEscape, openSpan,
                     "EOF after backslash")
        return result
      let esc = lx.peek
      let escSpan = initSpan(escStart, Position(
        line: lx.pos.line, col: lx.pos.col + 1, offset: lx.pos.offset + 1))
      case esc
      of 'n':  result.add '\n'; lx.advanceOne()
      of 't':  result.add '\t'; lx.advanceOne()
      of 'r':  result.add '\r'; lx.advanceOne()
      of '"':  result.add '"';  lx.advanceOne()
      of '\\': result.add '\\'; lx.advanceOne()
      of 'b':  result.add '\b'; lx.advanceOne()
      of 'f':  result.add '\f'; lx.advanceOne()
      of 's':  result.add ' ';  lx.advanceOne()
      of 'u':
        lx.advanceOne()
        result.add lx.decodeUnicodeEscape(escSpan)
      of ' ', '\t', '\n', '\r':
        # Whitespace-escape: `\` followed by any run of ASCII whitespace
        # (incl. newlines) is consumed entirely. Used in multi-line
        # string layouts where you want to break a line in source but
        # not in the decoded value.
        while not lx.atEof and
              (lx.peek == ' ' or lx.peek == '\t' or
               lx.peek == '\n' or lx.peek == '\r'):
          if isNewline(lx.peek): lx.advanceNewline() else: lx.advanceOne()
      else:
        lx.emitError(peLexInvalidEscape, escSpan,
                     "unknown escape \\" & esc)
        lx.advanceOne()
    else:
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
        # Process escape into currentLine
        let escStart = lx.pos
        lx.advanceOne()
        if lx.atEof: break
        let esc = lx.peek
        let escSpan = initSpan(escStart, Position(
          line: lx.pos.line, col: lx.pos.col + 1, offset: lx.pos.offset + 1))
        case esc
        of 'n':  currentLine.add '\n'; lx.advanceOne()
        of 't':  currentLine.add '\t'; lx.advanceOne()
        of 'r':  currentLine.add '\r'; lx.advanceOne()
        of '"':  currentLine.add '"';  lx.advanceOne()
        of '\\': currentLine.add '\\'; lx.advanceOne()
        of 'b':  currentLine.add '\b'; lx.advanceOne()
        of 'f':  currentLine.add '\f'; lx.advanceOne()
        of 's':  currentLine.add ' ';  lx.advanceOne()
        of 'u':
          lx.advanceOne()
          currentLine.add lx.decodeUnicodeEscape(escSpan)
        of ' ', '\t', '\n', '\r':
          # Whitespace-escape inside a multi-line string: consume the
          # run. Multi-line strings already split on newlines, so this
          # effectively joins consecutive lines without inserting a
          # newline in the decoded value.
          while not lx.atEof and
                (lx.peek == ' ' or lx.peek == '\t' or
                 lx.peek == '\n' or lx.peek == '\r'):
            if isNewline(lx.peek):
              # Push the current accumulated line, start a fresh blank.
              rawLines.add(currentLine)
              currentLine = ""
              lx.advanceNewline()
            else:
              lx.advanceOne()
        else:
          lx.emitError(peLexInvalidEscape, escSpan,
                       "unknown escape \\" & esc)
          lx.advanceOne()
      else:
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
    let span = initSpan(start, lx.pos)
    lx.emit(Token(kind: tkNumber, numText: lx.source[start.offset ..< lx.pos.offset],
                  numBase: base, numNegative: negative, span: span))
    return

  # Decimal
  var sawDigit = false
  while not lx.atEof:
    let ch = lx.peek
    if ch == '_':
      lx.advanceOne(); continue
    if ch >= '0' and ch <= '9':
      sawDigit = true; lx.advanceOne()
    else:
      break
  # Optional fractional part
  if lx.peek == '.' and lx.peek(1) >= '0' and lx.peek(1) <= '9':
    lx.advanceOne()
    while not lx.atEof:
      let ch = lx.peek
      if ch == '_':
        lx.advanceOne(); continue
      if ch >= '0' and ch <= '9':
        sawDigit = true; lx.advanceOne()
      else:
        break
  # Optional exponent
  if lx.peek == 'e' or lx.peek == 'E':
    lx.advanceOne()
    if lx.peek == '+' or lx.peek == '-':
      lx.advanceOne()
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
      lx.emitError(peLexInvalidNumber, span,
                   "exponent has no digits")
      return

  if not sawDigit:
    let span = initSpan(start, lx.pos)
    lx.emitError(peLexInvalidNumber, span, "number literal has no digits")
    return

  let span = initSpan(start, lx.pos)
  lx.emit(Token(kind: tkNumber,
                numText: lx.source[start.offset ..< lx.pos.offset],
                numBase: base, numNegative: negative, span: span))

# ---------------------------------------------------------------------------
# Identifiers + keywords
# ---------------------------------------------------------------------------

proc lexBareIdent(lx: var Lexer) =
  let start = lx.pos
  while not lx.atEof and isIdentCont(lx.peek):
    lx.advanceOne()
  let text = lx.source[start.offset ..< lx.pos.offset]
  let span = initSpan(start, lx.pos)
  let handle = lx.interner[].intern(text)
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

proc lexOne(lx: var Lexer) =
  if lx.atEof:
    lx.emit(Token(kind: tkEof, span: pointSpan(lx.pos)))
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
      lx.lexBareIdent()
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
      lx.lexBareIdent()
    else:
      let s = lx.pos; lx.advanceOne()
      lx.emitError(peLexUnexpectedChar, initSpan(s, lx.pos),
                   "unexpected character '" & $ch & "'")

proc lex*(source: string, interner: var Interner): seq[Token] =
  ## Tokenize `source`. Always returns a stream terminated by `tkEof`.
  ## Errors are surfaced as `tkError` tokens with embedded `ParseError`
  ## diagnostics; the parser handles re-sync.
  var lx = Lexer(source: source, pos: StartPosition,
                 tokens: @[], interner: addr interner)
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
    lx.lexOne()
  if lx.tokens.len == 0 or lx.tokens[^1].kind != tkEof:
    lx.emit(Token(kind: tkEof, span: pointSpan(lx.pos)))
  result = lx.tokens
