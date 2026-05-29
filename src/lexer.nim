## lexer — KDL v2 tokenizer (https://kdl.dev/spec/).
##
## Hand-written, no regex.
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

import std/[strutils, unicode, bitops]

import ./spans
import ./intern
import ./spec_literals  # KdlKeyword + KdlKeywordLiterals — wire bytes

const
  MaxRawStringHashes* = 255

  ReservedBarewords* = [
    "true", "false", "null", "inf", "-inf", "nan"
  ] ## KDL v2 forbids these as bare identifiers in *any* position (node
    ## name, property key, or value); they must be `#`-prefixed (booleans/
    ## null/special floats) or quoted (string values). Centralized here so
    ## parser, reference interpreter, and encoder agree.
  MaxReservedBarewordLen* = 5
    ## Length of the longest entry in `ReservedBarewords` (`"false"`).
    ## Identifiers longer than this cannot match any reserved bareword,
    ## so the 6-string scan can be skipped entirely. Used by
    ## `isReservedBareword` below; hot on every parsed identifier.

  # (Earlier revisions of this file had a doc-comment block for
  # `MaxRawStringHashes` floating after `ReservedBarewords`; the
  # rationale moved up next to the constant where it belongs.)

func isReservedBareword*(s: openArray[char]): bool {.inline.} =
  ## Length-prefiltered membership test for `ReservedBarewords`.
  ## A 6-string scan per identifier was visible in profiling; this
  ## short-circuits on `s.len > 5` and skips the comparison loop
  ## entirely for the overwhelming majority of identifiers.
  if s.len > MaxReservedBarewordLen: return false
  for kw in ReservedBarewords:
    if kw.len != s.len: continue
    var matches = true
    for i in 0 ..< s.len:
      if kw[i] != s[i]: matches = false; break
    if matches: return true
  false

func isReservedBareword*(interner: Interner, handle: InternedStr): bool {.inline.} =
  ## Alloc-free version that scans the interned bytes directly. Saves
  ## one string allocation per `tkIdent` token on the parser's hot path
  ## (previously had to call `lookup(handle)` just to feed the openArray
  ## version, allocating ~10-20 bytes per call).
  let n = interner.entryByteLenOf(handle)
  if n > MaxReservedBarewordLen: return false
  for kw in ReservedBarewords:
    if kw.len != n: continue
    var matches = true
    for i in 0 ..< n:
      if kw[i] != interner.entryByteAtOf(handle, i): matches = false; break
    if matches: return true
  false

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
    ## Mirrors `spec_literals.KdlKeyword` in declaration order so a
    ## `KeywordKind` value can index `KdlKeywordLiterals`. A static
    ## block after the type section enforces the contract — break the
    ## parity and the build fails immediately, before any wire-byte
    ## drift can reach the lexer ↔ emitter round-trip.

  NumberPayload* = object
    ## Heavy data for a tkNumber token. Stored once per token in the
    ## owning `TokenStream`'s `numberPayloads` seq; the token holds a
    ## u32 index.
    text*: string
    base*: NumberBase
    negative*: bool

  Token* = object
    ## Compact token: 8-byte span + 1-byte flag + 1-byte kind + 4-byte
    ## payload = 14 bytes natural, padded to 24. Heavy payload (string
    ## bytes, error structs, number text) is stored in `TokenStream`
    ## side tables; tokens hold u32 indices.
    span*: Span                ## 8 bytes
    precededByWs*: bool        ## 1 byte — true if any whitespace, comment,
                               ## newline, semicolon, or line-continuation
                               ## preceded this token (or it's the first).
                               ## Used at entry-position sites to enforce
                               ## v2 token-adjacency rules.
    case kind*: TokenKind      ## 1 byte discriminator
    of tkIdent:     ident*: InternedStr        ## 4 bytes (handle)
    of tkString:    strIdx*: uint32            ## 4 bytes index into stringPayloads
    of tkRawString: rawIdx*: uint32            ## 4 bytes index into rawStringPayloads
    of tkNumber:    numIdx*: uint32            ## 4 bytes index into numberPayloads
    of tkKeyword:   keyword*: KeywordKind      ## 1 byte
    of tkError:     errIdx*: uint32            ## 4 bytes index into errorPayloads
    else:           discard

  TokenStream* = object
    ## The lexer's output: a compact token sequence plus the side
    ## tables holding any heavy payload. Each tkString/tkRawString/
    ## tkNumber/tkError token carries a u32 index into the matching
    ## seq below.
    ##
    ## The split exists so the token sequence stays cache-friendly
    ## (24-byte tokens, ~2.5 per cache line); the parser streams tokens
    ## linearly and only chases an indirection when a heavy payload is
    ## actually needed.
    tokens*: seq[Token]
    stringPayloads*: seq[string]
    rawStringPayloads*: seq[string]
    numberPayloads*: seq[NumberPayload]
    errorPayloads*: seq[ParseError]
    source*: string
      ## Original source text — needed by visitors that read bareword
      ## (tkIdent) bytes directly (interner is disabled in visitor mode).
      ## Stored as a string ref; no extra allocation beyond the bind.

  Lexer = object
    ## Lexer state during a `lex(source, interner)` call. The interner
    ## is NOT a field — it's threaded as a `var Interner` parameter.
    source: string
    pos: Position
    stream: TokenStream      ## accumulating tokens + side tables
    wsPending: bool

# Compile-time contract: lexer.KeywordKind and spec_literals.KdlKeyword
# enumerate the same set in the same order. Indexing
# `KdlKeywordLiterals[<KeywordKind value>]` cast through this assert is
# safe; without the assert a silent reordering could send `kwTrue` to
# `klFalse`'s string. Build breaks the instant parity drifts.
static:
  doAssert int(kwTrue)   == int(klTrue)
  doAssert int(kwFalse)  == int(klFalse)
  doAssert int(kwNull)   == int(klNull)
  doAssert int(kwInf)    == int(klInf)
  doAssert int(kwNegInf) == int(klNegInf)
  doAssert int(kwNan)    == int(klNan)
  doAssert int(high(KeywordKind)) == int(high(KdlKeyword)),
    "KeywordKind and KdlKeyword must enumerate the same set"

# ---------------------------------------------------------------------------
# Char classifiers
# ---------------------------------------------------------------------------

func isIdentStart(ch: char): bool {.inline.} =
  ## ASCII identifier-start predicate. KDL v2 defines bare idents by a
  ## denylist; this proc covers the ASCII subset. Bytes >= 0x80 are
  ## handled via `decodeUtf8At` + `isIdentCodepoint` at the call site so
  ## multi-byte Unicode codepoints participate correctly.
  case ch
  of '\0' .. ' ', '\x7f': false
  of '{', '}', '(', ')', '[', ']', '/', '\\', '"', '#', '=', ';': false
  of '0' .. '9': false  # would look like the start of a number
  else: true

func isIdentCont(ch: char): bool {.inline.} =
  case ch
  of '\0' .. ' ', '\x7f': false
  of '{', '}', '(', ')', '[', ']', '/', '\\', '"', '#', '=', ';': false
  else: true

## SWAR (SIMD Within A Register) bulk scanner for ASCII ident-cont
## bytes. Branch-free, processes 8 bytes per memory load. Falls back
## to the byte-by-byte path on any non-ASCII byte (>=0x80) or
## terminator byte found in the chunk. Caller resumes byte-loop from
## the precise stop position.
##
## Forbidden ident-cont bytes (terminators):
##   0x00..0x20  (control + space)         — range check
##   0x22 "  0x23 #  0x28 (  0x29 )        — broadcast equals
##   0x2F /  0x3B ;  0x3D =
##   0x5B [  0x5C \\  0x5D ]
##   0x7B {  0x7D }  0x7F DEL
##
## Strategy: for each forbidden byte b, compute hasByteEqual(word, b)
## using the standard XOR + hasZeroByte trick. OR all the results and
## the range-check for 0..0x20. The position of the first set high-bit
## tells us where to stop. countTrailingZeros / 8 gives the byte index.

const SwarLo = 0x0101010101010101'u64
const SwarHi = 0x8080808080808080'u64

func hasZeroByte(v: uint64): uint64 {.inline.} =
  ((v - SwarLo) and (not v) and SwarHi)

func hasByteEqual(w: uint64, b: uint8): uint64 {.inline.} =
  hasZeroByte(w xor (uint64(b) * SwarLo))

func anyByteLE(w: uint64, b: uint8): uint64 {.inline.} =
  ## Returns nonzero high-bits in positions where byte <= b.
  ## Trick: (w +~ 0x7F...) - subtract-with-bias. Standard SWAR pattern.
  let bb = uint64(b) * SwarLo
  hasZeroByte(w xor bb) or
    (((w xor SwarHi) - (bb xor SwarHi)) and not (w xor bb) and SwarHi)

func loadU64LE(s: string, offset: int): uint64 {.inline.} =
  ## Little-endian load of 8 bytes. Caller must ensure offset+8 <= s.len.
  cast[ptr uint64](unsafeAddr s[offset])[]

func firstTerminatorBit(mask: uint64): int {.inline.} =
  ## Given a mask where each "stop" byte position has the 0x80 bit set,
  ## return the byte index of the first stop (0..7). Caller has already
  ## verified mask != 0.
  countTrailingZeroBits(mask) shr 3

proc swarScanIdentCont*(source: string, start: int): int =
  ## Bulk-scan ASCII ident-cont bytes from `start`. Returns the first
  ## index where scanning stops — either a terminator byte or any
  ## non-ASCII byte (>=0x80) requiring unicode validation by caller.
  var i = start
  # 8-byte SWAR loop
  while i + 8 <= source.len:
    let w = loadU64LE(source, i)
    # any byte >= 0x80? (unicode start — caller handles)
    let highBitSet = w and SwarHi
    # any byte <= 0x20 (control + space)?
    let leSpace = anyByteLE(w, 0x20)
    # any of the 12 forbidden punctuation bytes?
    let m = hasByteEqual(w, 0x22'u8) or hasByteEqual(w, 0x23'u8) or
            hasByteEqual(w, 0x28'u8) or hasByteEqual(w, 0x29'u8) or
            hasByteEqual(w, 0x2F'u8) or hasByteEqual(w, 0x3B'u8) or
            hasByteEqual(w, 0x3D'u8) or hasByteEqual(w, 0x5B'u8) or
            hasByteEqual(w, 0x5C'u8) or hasByteEqual(w, 0x5D'u8) or
            hasByteEqual(w, 0x7B'u8) or hasByteEqual(w, 0x7D'u8) or
            hasByteEqual(w, 0x7F'u8)
    let stop = highBitSet or leSpace or m
    if stop != 0:
      return i + firstTerminatorBit(stop)
    i += 8
  # Byte-loop tail for the remainder (<8 bytes)
  while i < source.len:
    let b = uint8(source[i])
    if b >= 0x80'u8: break
    if not isIdentCont(source[i]): break
    inc i
  i

func decodeUtf8At*(s: string, pos: int): tuple[cp: int, width: int] =
  ## Decode one UTF-8 codepoint at `s[pos]`. Returns (-1, 0) on EOF or
  ## malformed input. Surrogate halves (U+D800-DFFF) and codepoints >
  ## U+10FFFF report as malformed; over-long encodings too.
  if pos >= s.len: return (-1, 0)
  let b0 = uint8(s[pos])
  if b0 < 0x80'u8: return (int(b0), 1)
  var width: int
  var cp: int
  if (b0 and 0xE0'u8) == 0xC0'u8:
    width = 2; cp = int(b0 and 0x1F'u8)
    if b0 < 0xC2'u8: return (-1, 0)
  elif (b0 and 0xF0'u8) == 0xE0'u8:
    width = 3; cp = int(b0 and 0x0F'u8)
  elif (b0 and 0xF8'u8) == 0xF0'u8:
    width = 4; cp = int(b0 and 0x07'u8)
    if b0 > 0xF4'u8: return (-1, 0)
  else:
    return (-1, 0)
  if pos + width > s.len: return (-1, 0)
  for j in 1 ..< width:
    let bj = uint8(s[pos + j])
    if (bj and 0xC0'u8) != 0x80'u8: return (-1, 0)
    cp = (cp shl 6) or int(bj and 0x3F'u8)
  case width
  of 2:
    if cp < 0x80: return (-1, 0)
  of 3:
    if cp < 0x800 or (cp >= 0xD800 and cp <= 0xDFFF): return (-1, 0)
  of 4:
    if cp < 0x10000 or cp > 0x10FFFF: return (-1, 0)
  else: discard
  (cp, width)

func isUnicodeWhitespace*(cp: int): bool =
  ## KDL v2 Whitespace table.
  case cp
  of 0x0009, 0x0020, 0x00A0, 0x1680, 0x202F, 0x205F, 0x3000: true
  of 0x2000..0x200A: true
  else: false

func isUnicodeNewline*(cp: int): bool =
  ## KDL v2 Newline table. Includes VT (0x0B) and FF (0x0C) — both
  ## terminate a node like LF, not just whitespace.
  case cp
  of 0x000A, 0x000B, 0x000C, 0x000D, 0x0085, 0x2028, 0x2029: true
  else: false

func isIdentCodepoint*(cp: int): bool =
  ## True iff `cp` may appear inside a bare identifier. Whitespace,
  ## newline, the 12-char structural set, disallowed-literal-codepoints,
  ## bidi controls, and BOM are all rejected; everything else is fine.
  if cp < 0: return false
  if cp < 0x80:
    let ch = char(cp)
    return isIdentCont(ch)
  if isUnicodeWhitespace(cp): return false
  if isUnicodeNewline(cp): return false
  if (cp >= 0x200E and cp <= 0x200F) or
     (cp >= 0x202A and cp <= 0x202E) or
     (cp >= 0x2066 and cp <= 0x2069): return false
  if cp == 0xFEFF: return false
  if cp >= 0xD800 and cp <= 0xDFFF: return false
  true

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

func containsBidiControl*(s: openArray[char]): bool =
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

func isBareword*(s: openArray[char]): bool =
  ## True iff `s` is a valid KDL v2 bare identifier — emittable
  ## verbatim in a node-name / prop-key / type-tag position without
  ## quoting. Composes the same per-codepoint predicates the lexer
  ## uses to *recognize* barewords. Single source of truth: when the
  ## spec evolves, both lexer (consume) and emitter (produce) see the
  ## change through this predicate.
  ##
  ## Returns false for:
  ##   - empty string (must be `""`)
  ##   - reserved keyword (`true` / `false` / `null` / `inf` / `-inf` / `nan`)
  ##   - leading digit (would tokenize as number)
  ##   - leading `+`/`-` followed by digit (would tokenize as signed number)
  ##   - any character that doesn't satisfy `isIdentCont` (ASCII path)
  ##     or `isIdentCodepoint` (any codepoint path)
  ##   - bidi control codepoints (per `containsBidiControl`)
  if s.len == 0: return false
  if isReservedBareword(s): return false
  if (s[0] == '-' or s[0] == '+') and s.len >= 2 and s[1] in '0'..'9':
    return false
  # Fast path: pure ASCII bytes.
  var asciiOnly = true
  for i in 0 ..< s.len:
    if s[i].uint8 >= 0x80'u8:
      asciiOnly = false
      break
  if asciiOnly:
    if not isIdentStart(s[0]): return false
    for i in 1 ..< s.len:
      if not isIdentCont(s[i]): return false
    return true
  # Slow path: copy to string for decodeUtf8At; bareword inputs are
  # short so the alloc is bounded.
  let asStr = $(@s)
  let (firstCp, firstW) = decodeUtf8At(asStr, 0)
  if firstW == 0: return false
  if not isIdentCodepoint(firstCp): return false
  if firstCp < 0x80 and not isIdentStart(char(firstCp)): return false
  var i = firstW
  while i < asStr.len:
    let (cp, w) = decodeUtf8At(asStr, i)
    if w == 0: return false
    if not isIdentCodepoint(cp): return false
    i += w
  if containsBidiControl(s): return false
  true

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

proc multilineNewlineWidth(lx: Lexer): int =
  ## Width (in bytes) of a Unicode newline at the current cursor, or 0
  ## if not at a newline. Single-byte ASCII newlines (LF, CR, VT, FF)
  ## return 1; CRLF returns 2; the multi-byte NEL/LS/PS return 2 or 3.
  if lx.atEof: return 0
  let b0 = uint8(lx.peek)
  if b0 < 0x80'u8:
    case lx.peek
    of '\r':
      return (if lx.peek(1) == '\n': 2 else: 1)
    of '\n', '\v', '\f':
      return 1
    else:
      return 0
  let (cp, w) = decodeUtf8At(lx.source, lx.pos.offset)
  if cp < 0: return 0
  if isUnicodeNewline(cp): w else: 0

proc advanceNewline(lx: var Lexer) =
  ## Consume one logical newline. CRLF is treated as a single newline
  ## (one position bump, not two) so line numbers are stable across
  ## Windows-style files. Also handles VT, FF, NEL, LS, PS.
  let w = lx.multilineNewlineWidth
  if w == 0: return
  lx.pos = Position(offset: lx.pos.offset + w)

func isNewline(ch: char): bool {.inline.} =
  ## ASCII-only newline predicate (for hot byte-level paths). Multi-byte
  ## newlines and the broader Unicode set are checked via
  ## `multilineNewlineWidth` / `isUnicodeNewline` at call sites that
  ## must respect the full v2 Newline table.
  ch == '\n' or ch == '\r' or ch == '\v' or ch == '\f'

# ---------------------------------------------------------------------------
# Token emission
# ---------------------------------------------------------------------------

func isLineAllUnicodeWhitespace(line: string): bool =
  ## True iff every codepoint in `line` is a Unicode whitespace char.
  ## Used by the multi-line dedent pass: per spec, intermediate lines
  ## that are entirely whitespace are exempt from the prefix-match
  ## requirement and contribute the empty string.
  var i = 0
  while i < line.len:
    let b = uint8(line[i])
    if b < 0x80'u8:
      if line[i] != ' ' and line[i] != '\t': return false
      inc i
    else:
      let (cp, w) = decodeUtf8At(line, i)
      if cp < 0 or not isUnicodeWhitespace(cp): return false
      inc i, w
  true

func isMultilineWsEscapeStart(ch: char): bool {.inline.} =
  ## In a multi-line string, `\` followed by any of these bytes triggers
  ## the whitespace-escape rule: the `\` and the entire whitespace run
  ## (including newlines) are deleted in phase 1.
  ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r'

proc emit(lx: var Lexer, tok: sink Token) =
  var t = tok
  t.precededByWs = lx.wsPending
  lx.stream.tokens.add(t)
  # Structural tokens that semantically end a "phrase" implicitly grant
  # the next token wsPending. tkNewline, tkSemicolon, and tkSlashDash all
  # act like whitespace as far as entry-adjacency is concerned.
  case t.kind
  of tkNewline, tkSemicolon, tkSlashDash:
    lx.wsPending = true
  else:
    lx.wsPending = false

# ---------------------------------------------------------------------------
# Side-table emitters — produce a compact Token holding a u32 index into
# the matching payload seq, after appending the heavy payload to the seq.
# ---------------------------------------------------------------------------

proc emitString(lx: var Lexer, value: sink string, span: Span) =
  let idx = uint32(lx.stream.stringPayloads.len)
  lx.stream.stringPayloads.add(value)
  lx.emit(Token(kind: tkString, strIdx: idx, span: span))

proc emitRawString(lx: var Lexer, value: sink string, span: Span) =
  let idx = uint32(lx.stream.rawStringPayloads.len)
  lx.stream.rawStringPayloads.add(value)
  lx.emit(Token(kind: tkRawString, rawIdx: idx, span: span))

proc emitNumber(lx: var Lexer, text: sink string, base: NumberBase,
                negative: bool, span: Span) =
  let idx = uint32(lx.stream.numberPayloads.len)
  lx.stream.numberPayloads.add(NumberPayload(
    text: text, base: base, negative: negative))
  lx.emit(Token(kind: tkNumber, numIdx: idx, span: span))

proc emitError(lx: var Lexer, code: ParseErrorCode, span: Span, hint = "") =
  let idx = uint32(lx.stream.errorPayloads.len)
  lx.stream.errorPayloads.add(initError(code, span, hint))
  lx.emit(Token(kind: tkError, errIdx: idx, span: span))

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
    Position(offset: start.offset - 2),
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
    let b = uint8(ch)
    if b < 0x80'u8:
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
    else:
      let (cp, w) = decodeUtf8At(lx.source, lx.pos.offset)
      if cp >= 0 and isUnicodeWhitespace(cp):
        for _ in 0 ..< w: lx.advanceOne()
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
      let escSpan = initSpan(escStart, Position(offset: lx.pos.offset + 1))
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
    # Per KDL v2 spec (Multi-Line String), processing is three phases:
    #   1. Resolve whitespace escapes (`\<ws+>` is deleted entirely).
    #   2. Dedent: the bytes between the last '\n' and the closing `"""`
    #      are the closing-prefix (must be whitespace-only); strip that
    #      exact byte sequence from every intermediate line.
    #   3. Resolve other backslash escapes (\n, \t, \", \u{…}, etc.).
    # The previous implementation interleaved all three and got the
    # closing-line whitespace-escape interactions wrong.
    var rawBuf = ""
    while not lx.atEof:
      if lx.peek == '"' and lx.peek(1) == '"' and lx.peek(2) == '"':
        lx.advanceOne(); lx.advanceOne(); lx.advanceOne()
        # Split rawBuf on '\n'. The slice after the final '\n' is the
        # closing-prefix; everything before it is the content section.
        var lines: seq[string] = @[]
        var line = ""
        for ch in rawBuf:
          if ch == '\n':
            lines.add(line); line = ""
          else:
            line.add(ch)
        lines.add(line)
        if lines.len < 1:
          lx.emitError(peLexUnterminatedString, initSpan(start, lx.pos),
                       "malformed multi-line string")
          return
        let closingPrefix = lines[^1]
        # Closing-prefix bytes must form a sequence of whitespace
        # codepoints per the spec Whitespace table — ASCII subset is
        # tab/space; non-ASCII handled via decodeUtf8At + Unicode WS
        # classifier so fixtures like multiline_string_whitespace_only
        # (U+2001 etc.) validate correctly.
        var ci = 0
        var prefixOk = true
        while ci < closingPrefix.len:
          let b = uint8(closingPrefix[ci])
          if b < 0x80'u8:
            if closingPrefix[ci] != ' ' and closingPrefix[ci] != '\t':
              prefixOk = false; break
            inc ci
          else:
            let (cp, w) = decodeUtf8At(closingPrefix, ci)
            if cp < 0 or not isUnicodeWhitespace(cp):
              prefixOk = false; break
            inc ci, w
        if not prefixOk:
          lx.emitError(peLexUnterminatedString, initSpan(start, lx.pos),
                       "closing \"\"\" must be on its own line " &
                       "(non-whitespace before closing delimiter)")
          return
        var dedented = newStringOfCap(rawBuf.len)
        # Intermediate content = lines[0 .. ^2]; lines[^1] is the closing
        # prefix consumed above. Per spec: a line that contains ONLY
        # whitespace is exempt from the prefix-match requirement; it
        # contributes whatever bytes remain after stripping the longest
        # common prefix shared with `closingPrefix`. A non-whitespace
        # intermediate line MUST start with the full closing prefix.
        for i in 0 ..< lines.len - 1:
          if i > 0: dedented.add('\n')
          let lineStr = lines[i]
          if lineStr.len == 0:
            discard
          elif isLineAllUnicodeWhitespace(lineStr):
            # Spec: whitespace-only intermediate lines contribute empty,
            # regardless of how their bytes compare with the closing
            # prefix.
            discard
          elif lineStr.startsWith(closingPrefix):
            dedented.add(lineStr[closingPrefix.len .. ^1])
          else:
            lx.emitError(peLexUnterminatedString, initSpan(start, lx.pos),
                         "line content does not start with the closing " &
                         "indentation prefix")
            return
        # Phase 3: resolve other backslash escapes on the dedented buffer.
        var decoded = ""
        var j = 0
        while j < dedented.len:
          let ch = dedented[j]
          if ch == '\\' and j + 1 < dedented.len:
            inc j
            let esc = dedented[j]
            case esc
            of 'n':  decoded.add('\n'); inc j
            of 't':  decoded.add('\t'); inc j
            of 'r':  decoded.add('\r'); inc j
            of '"':  decoded.add('"');  inc j
            of '\\': decoded.add('\\'); inc j
            of 'b':  decoded.add('\b'); inc j
            of 'f':  decoded.add('\f'); inc j
            of 's':  decoded.add(' ');  inc j
            of 'u':
              # Minimal `\u{XXXX}` decoder for the dedented buffer — the
              # opening `\u` is at position j; advance past it and the
              # caller dispatchEscape can't easily be reused here because
              # we're operating on a string, not the lexer cursor. Re-
              # implement just the `\u{HEX}` shape inline.
              inc j  # past 'u'
              if j >= dedented.len or dedented[j] != '{':
                lx.emitError(peLexInvalidEscape, initSpan(start, lx.pos),
                             "\\u must be followed by '{'")
                return
              inc j  # past '{'
              var cp: int = 0
              var hexCount = 0
              while j < dedented.len and dedented[j] != '}':
                let c = dedented[j]
                let v =
                  case c
                  of '0'..'9': int(ord(c) - ord('0'))
                  of 'a'..'f': int(ord(c) - ord('a') + 10)
                  of 'A'..'F': int(ord(c) - ord('A') + 10)
                  else: -1
                if v < 0:
                  lx.emitError(peLexInvalidEscape, initSpan(start, lx.pos),
                               "bad hex digit in \\u{…}")
                  return
                cp = (cp shl 4) or v
                inc hexCount
                inc j
              if hexCount == 0 or hexCount > 6 or
                 (cp >= 0xD800 and cp <= 0xDFFF) or cp > 0x10FFFF:
                lx.emitError(peLexInvalidEscape, initSpan(start, lx.pos),
                             "invalid codepoint in \\u{…}")
                return
              if j >= dedented.len or dedented[j] != '}':
                lx.emitError(peLexInvalidEscape, initSpan(start, lx.pos),
                             "unterminated \\u{…}")
                return
              inc j  # past '}'
              # UTF-8 encode the codepoint.
              if cp < 0x80:
                decoded.add(char(cp))
              elif cp < 0x800:
                decoded.add(char(0xC0 or (cp shr 6)))
                decoded.add(char(0x80 or (cp and 0x3F)))
              elif cp < 0x10000:
                decoded.add(char(0xE0 or (cp shr 12)))
                decoded.add(char(0x80 or ((cp shr 6) and 0x3F)))
                decoded.add(char(0x80 or (cp and 0x3F)))
              else:
                decoded.add(char(0xF0 or (cp shr 18)))
                decoded.add(char(0x80 or ((cp shr 12) and 0x3F)))
                decoded.add(char(0x80 or ((cp shr 6) and 0x3F)))
                decoded.add(char(0x80 or (cp and 0x3F)))
            else:
              lx.emitError(peLexInvalidEscape, initSpan(start, lx.pos),
                           "unknown escape \\" & esc)
              return
          else:
            decoded.add(ch); inc j
        lx.emitString(decoded, initSpan(start, lx.pos))
        return
      # Phase 1: copy bytes into rawBuf, with whitespace-escapes deleted.
      if lx.peek == '\\':
        # Look ahead: if followed by 1+ whitespace (incl. newline), it's
        # a whitespace-escape — drop the `\` and all consecutive ws.
        let savePos = lx.pos
        lx.advanceOne()
        if not lx.atEof and isMultilineWsEscapeStart(lx.peek):
          while not lx.atEof and isMultilineWsEscapeStart(lx.peek):
            if isNewline(lx.peek): lx.advanceNewline() else: lx.advanceOne()
          continue
        # Not a ws-escape — keep the `\` and the next byte verbatim for
        # phase 3 to interpret.
        lx.pos = savePos
        rawBuf.add(lx.peek)
        lx.advanceOne()
        if not lx.atEof:
          rawBuf.add(lx.peek)
          lx.advanceOne()
        continue
      if isNewline(lx.peek):
        rawBuf.add('\n')
        lx.advanceNewline()
        continue
      if isDisallowedControl(lx.peek):
        let sPos = lx.pos
        lx.advanceOne()
        lx.emitError(peLexUnexpectedChar, initSpan(sPos, lx.pos),
                     "disallowed literal control codepoint in string body")
        return
      rawBuf.add(lx.peek)
      lx.advanceOne()
    # EOF before close
    let span = initSpan(start, lx.pos)
    lx.emitError(peLexUnterminatedString, span,
                 "unterminated multi-line string")
    return

  # Regular single-line string
  let openSpan = initSpan(start, Position(offset: start.offset + 1))
  lx.advanceOne()  # consume opening "
  let decoded = lx.decodeRegularString(openSpan, '"')
  lx.emitString(decoded, initSpan(start, lx.pos))

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
          # Same Unicode-whitespace + whitespace-only-line rules as the
          # regular `"""…"""` path; see lexRegularOrMultiline.
          var ci = 0
          var prefixOk = true
          while ci < closingPrefix.len:
            let b = uint8(closingPrefix[ci])
            if b < 0x80'u8:
              if closingPrefix[ci] != ' ' and closingPrefix[ci] != '\t':
                prefixOk = false; break
              inc ci
            else:
              let (cp, w) = decodeUtf8At(closingPrefix, ci)
              if cp < 0 or not isUnicodeWhitespace(cp):
                prefixOk = false; break
              inc ci, w
          if not prefixOk:
            let span = initSpan(start, lx.pos)
            lx.emitError(peLexUnterminatedString, span,
                         "closing #\"\"\"… must be on its own line")
            return
          var decoded = ""
          for j in 0 ..< rawLines.len - 1:
            let line = rawLines[j]
            if j > 0: decoded.add('\n')
            if line.len == 0:
              discard
            elif isLineAllUnicodeWhitespace(line):
              discard  # whitespace-only contributes empty
            elif line.startsWith(closingPrefix):
              decoded.add(line[closingPrefix.len .. ^1])
            else:
              let span = initSpan(start, lx.pos)
              lx.emitError(peLexUnterminatedString, span,
                           "line content has less indent than closing #\"\"\"…")
              return
          lx.emitRawString(decoded, initSpan(start, lx.pos))
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
        lx.emitRawString(body, initSpan(start, lx.pos))
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
    lx.emitNumber(lx.source[start.offset ..< lx.pos.offset], base, negative, span)
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
  lx.emitNumber(lx.source[start.offset ..< lx.pos.offset], base, negative, span)

# ---------------------------------------------------------------------------
# Identifiers + keywords
# ---------------------------------------------------------------------------

proc lexBareIdent(lx: var Lexer, interner: var Interner) =
  let start = lx.pos
  while not lx.atEof:
    let b = uint8(lx.peek)
    if b < 0x80'u8:
      let newOffset = swarScanIdentCont(lx.source, lx.pos.offset)
      if newOffset == lx.pos.offset: break
      lx.pos = lx.pos.advance(newOffset - lx.pos.offset)
    else:
      let (cp, w) = decodeUtf8At(lx.source, lx.pos.offset)
      if cp < 0 or not isIdentCodepoint(cp): break
      for _ in 0 ..< w: lx.advanceOne()
  let textLast = lx.pos.offset - 1
  let span = initSpan(start, lx.pos)
  # Use an openArray slice into source — avoids allocating a string
  # just to validate + intern. intern() also takes openArray; only
  # the SBO path (≤22 bytes) is fully zero-alloc, the heap path
  # still allocates once for the Entry payload.
  if containsBidiControl(lx.source.toOpenArray(start.offset, textLast)):
    lx.emitError(peLexInvalidIdentifier, span,
                 "bidirectional control codepoint in identifier")
    return
  # Legacy KDL v1 raw-string syntax: `r"..."` / `r#"..."#`. v2 requires
  # raw strings to start with `#"`. Single-char r/R check is a direct
  # byte read — no need to materialize the string for ==.
  if (textLast == start.offset and
      (lx.source[start.offset] == 'r' or lx.source[start.offset] == 'R')) and
     not lx.atEof and (lx.peek == '"' or lx.peek == '#'):
    lx.emitError(peLexInvalidIdentifier, span,
                 "KDL v1 raw-string syntax `r\"...\"` is not valid in v2; " &
                 "use `#\"...\"#` instead")
    return
  # Reserved-bareword rejection at lex time. KDL v2 forbids bare
  # `true`/`false`/`null`/`inf`/`-inf`/`nan` as identifiers in any
  # position (node name, property key, arg value). The lexer is the
  # only place that touches every bareword byte, so doing this check
  # here removes the per-call cost on the parser hot path.
  if isReservedBareword(lx.source.toOpenArray(start.offset, textLast)):
    lx.emitError(peLexReservedKeyword, span,
      "reserved keyword '" &
      lx.source[start.offset .. textLast] &
      "' must be quoted or `#`-prefixed; bare use is forbidden in KDL v2")
    return
  let handle = interner.intern(lx.source.toOpenArray(start.offset, textLast))
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
  # Byte-level dispatch against the six v2 keywords. Avoids allocating a
  # slice + case-on-string on the hot path (fixtures with many #true/#false
  # values hit this per token). Length-prefilter then per-byte compare —
  # all six keywords have distinct (length, first-byte) shapes.
  let span = initSpan(start, lx.pos)
  let s = textStart.offset
  let n = lx.pos.offset - s
  template byteAt(i: int): char = lx.source[s + i]
  var kw: KeywordKind
  var matched = false
  case n
  of 3:                           # inf | nan
    if byteAt(0) == 'i' and byteAt(1) == 'n' and byteAt(2) == 'f':
      kw = kwInf; matched = true
    elif byteAt(0) == 'n' and byteAt(1) == 'a' and byteAt(2) == 'n':
      kw = kwNan; matched = true
  of 4:                           # true | null | -inf
    if byteAt(0) == 't' and byteAt(1) == 'r' and byteAt(2) == 'u' and byteAt(3) == 'e':
      kw = kwTrue; matched = true
    elif byteAt(0) == 'n' and byteAt(1) == 'u' and byteAt(2) == 'l' and byteAt(3) == 'l':
      kw = kwNull; matched = true
    elif byteAt(0) == '-' and byteAt(1) == 'i' and byteAt(2) == 'n' and byteAt(3) == 'f':
      kw = kwNegInf; matched = true
  of 5:                           # false
    if byteAt(0) == 'f' and byteAt(1) == 'a' and byteAt(2) == 'l' and
       byteAt(3) == 's' and byteAt(4) == 'e':
      kw = kwFalse; matched = true
  else: discard
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
  of '\n', '\r', '\v', '\f':
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
    # Multi-byte newlines (NEL, LS, PS) — bytes >= 0x80 fall here.
    let b = uint8(ch)
    if b >= 0x80'u8:
      let (cp, _) = decodeUtf8At(lx.source, lx.pos.offset)
      if cp >= 0 and isUnicodeNewline(cp):
        let s = lx.pos
        lx.advanceNewline()
        lx.emit(Token(kind: tkNewline, span: initSpan(s, lx.pos)))
        return
      if cp >= 0 and isIdentCodepoint(cp):
        lx.lexBareIdent(interner)
        return
    elif isIdentStart(ch):
      lx.lexBareIdent(interner)
      return
    let s = lx.pos; lx.advanceOne()
    lx.emitError(peLexUnexpectedChar, initSpan(s, lx.pos),
                 "unexpected character '" & $ch & "'")

func estimateTokenCount*(sourceLen: int): int {.inline.} =
  ## Heuristic for pre-allocating the lexer's `seq[Token]` capacity.
  ##
  ## Empirically, KDL configs produce ~1 token per 6-8 source bytes
  ## (mix of single-byte punctuation, 1-byte newlines, and 5-15-byte
  ## identifiers/numbers/strings). Dividing by 6 slightly over-
  ## estimates the typical case so the seq doesn't need to re-grow
  ## during the lex pass for any realistic input.
  ##
  ## Returns at least 16 — for tiny inputs the lex overhead is
  ## dominated by setup costs, not a few extra preallocated slots.
  max(16, sourceLen div 6)


func sourceSizeOk*(len: int): Result[void, ParseError] =
  ## The compact `Span` representation stores byte offsets as `uint32`,
  ## capping source size at 4 GiB. Past that boundary, offsets would
  ## silently truncate and produce corrupted spans — better to refuse
  ## up front with a clear error.
  if len > int(uint32.high):
    err[void, ParseError](initError(peOther, pointSpan(StartPosition),
      "source too large: " & $len & " bytes exceeds the " &
      $int(uint32.high) & "-byte limit"))
  else:
    ok(void, ParseError)


proc lex*(source: string, interner: var Interner): TokenStream
    {.noSideEffect.} =
  ## Tokenize `source`. Returns a `TokenStream` (compact tokens + side
  ## tables for heavy payloads); the token sequence is always terminated
  ## by `tkEof`. Errors surface as `tkError` tokens with a u32 index into
  ## `errorPayloads`; the parser handles re-sync.
  # Pre-allocate seqs at estimated final size — eliminates O(log N)
  # reallocations during the lex pass for typical inputs.
  let tokCap = estimateTokenCount(source.len)
  let stringCap = max(4, source.len div 64)
  let numberCap = max(4, source.len div 128)
  var lx = Lexer(source: source, pos: StartPosition,
                 stream: TokenStream(
                   tokens: newSeqOfCap[Token](tokCap),
                   stringPayloads: newSeqOfCap[string](stringCap),
                   numberPayloads: newSeqOfCap[NumberPayload](numberCap),
                 ),
                 wsPending: true)
  let szCheck = sourceSizeOk(source.len)
  if szCheck.isErr:
    lx.stream.errorPayloads.add(szCheck.getErr)
    lx.stream.tokens.add(Token(kind: tkError, errIdx: 0,
                               span: pointSpan(StartPosition)))
    lx.stream.tokens.add(Token(kind: tkEof, span: pointSpan(StartPosition)))
    return lx.stream
  if not isWellFormedUtf8(source):
    lx.emitError(peLexUnexpectedChar, pointSpan(StartPosition),
                 "input is not well-formed UTF-8")
    lx.emit(Token(kind: tkEof, span: pointSpan(StartPosition)))
    return lx.stream
  if lx.source.len >= 3 and
     lx.source[0] == '\xEF' and lx.source[1] == '\xBB' and
     lx.source[2] == '\xBF':
    lx.pos = Position(offset: 3)
  while not lx.atEof:
    lx.skipWhitespaceAndComments()
    if lx.atEof: break
    lx.lexOne(interner)
  if lx.stream.tokens.len == 0 or lx.stream.tokens[^1].kind != tkEof:
    lx.emit(Token(kind: tkEof, span: pointSpan(lx.pos)))
  lx.stream.source = source
  result = lx.stream
