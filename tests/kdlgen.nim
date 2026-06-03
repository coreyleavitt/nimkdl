## kdlgen — paired KDL surface generators for spec-coverage testing.
##
## Each generator yields a `ValueSurface` = (text, value): a syntactically
## valid KDL surface form paired with the `KdlValue` it MUST denote. The
## property suite (`test_spec_coverage`) asserts that `parse("node " & text)`
## yields exactly one node with one argument whose value equals `value`.
##
## ## Why a generator is the oracle
##
## No KDL parser fully conforms to the spec (the kdl-org reference misses
## corpus cases too), so a differential against any *parser* can't be ground
## truth. The spec grammar is the only authority. We encode it here in the
## **generation** direction, which is structurally simpler than parsing — no
## ambiguity, no lookahead, no error recovery — so each branch is correct by
## audit against one grammar production. See
## `docs/rfc-spec-coverage-testing.md`.
##
## ## The one non-negotiable
##
## The renderer must NOT call nkdl's encoder/formatter (`emitter`, `numlit`,
## `doc_emit`). It hand-writes its own surface forms so a shared bug cannot
## hide from itself. The float slice is the one sanctioned exception (it leans
## on stdlib `addFloatRoundtrip`, which is not nkdl and tests a different
## algorithm than any encoder).

import std/[formatfloat, strutils, unicode]   # addFloatRoundtrip — stdlib, NOT nkdl's formatter
import proptest
import ../src/value

type
  ValueSurface* = object
    ## A valid KDL surface form of one value, paired with the value it denotes.
    text*:  string
    value*: KdlValue

func valueEq*(a, b: KdlValue): bool =
  ## Kind + payload equality, ignoring `span` and the (absent for these
  ## generators) `typeAnnotation`. NaN is treated as equal to NaN (the
  ## generator and parser must agree on `#nan`, which `==` would reject).
  if a.kind != b.kind: return false
  case a.kind
  of kvInt:    a.intVal == b.intVal
  of kvString: a.strVal == b.strVal
  of kvBool:   a.boolVal == b.boolVal
  of kvNull:   true
  of kvFloat:
    (a.floatVal != a.floatVal and b.floatVal != b.floatVal) or  # both NaN
    a.floatVal == b.floatVal
  of kvBigInt:
    a.bigHi == b.bigHi and a.bigLo == b.bigLo and
    a.bigNegative == b.bigNegative

# ---------------------------------------------------------------------------
# Slices 1-3 (unified) — integers, full grammar coverage
#
#   number  := hex | octal | binary | decimal
#   decimal := sign? integer ('.' integer)? exponent?
#   integer := digit (digit | '_')*
#   hex     := sign? '0x' hex-digit (hex-digit | '_')*     (octal/binary analog)
#   sign    := '+' | '-'
#
# So every integer covers: base ∈ {10,16,8,2}, hex digit case, sign ∈
# {none, '+', '-'}, and `_` runs after ANY body digit — consecutive and
# trailing allowed, never leading (the first char after sign/prefix is a
# digit). value derives from sign × magnitude. Independent of numlit.
# ---------------------------------------------------------------------------

const RadixBound = 1_099_511_627_776  # 2^40 — multi-digit, well inside int64

type IntStyle = object
  base: int
  upperHex: bool

const intStyles = @[
  IntStyle(base: 10, upperHex: false),
  IntStyle(base: 16, upperHex: false),
  IntStyle(base: 16, upperHex: true),
  IntStyle(base: 8,  upperHex: false),
  IntStyle(base: 2,  upperHex: false),
]

func magnitudeDigits(mag: uint64, base: int, upperHex: bool): string =
  ## The bare digits of `mag` in `base` (no prefix/sign/underscores).
  let ds = if upperHex: "0123456789ABCDEF" else: "0123456789abcdef"
  if mag == 0'u64: return "0"
  var m = mag
  while m > 0'u64:
    result = ds[int(m mod uint64(base))] & result
    m = m div uint64(base)

func basePrefix(base: int): string =
  (case base
   of 16: "0x"
   of 8:  "0o"
   of 2:  "0b"
   else:  "")

proc integerSurfaces*(): Strategy[ValueSurface] =
  ## Every integer surface form. Draws magnitude × style × sign-mode, then a
  ## per-digit underscore-run count (0..2 after each digit, trailing allowed).
  map(integers(0, RadixBound), sampledFrom(intStyles), integers(0, 2))
    .flatMap(proc(t: (int, IntStyle, int)): Strategy[ValueSurface] =
      let (magI, style, signMode) = t
      let digits = magnitudeDigits(uint64(magI), style.base, style.upperHex)
      let signTxt = ["", "+", "-"][signMode]
      let value = (if signMode == 2: -magI.int64 else: magI.int64)
      lists(integers(0, 2), digits.len, digits.len).map(proc(us: seq[int]): ValueSurface =
        var body = ""
        for i in 0 ..< digits.len:
          body.add digits[i]
          for _ in 0 ..< us[i]: body.add '_'   # run after digit i (i=last ⇒ trailing)
        ValueSurface(text: signTxt & basePrefix(style.base) & body,
                     value: newKdlInt(value))))

# ---------------------------------------------------------------------------
# Slice 4 — decimal floats
# ---------------------------------------------------------------------------

proc renderFloat(f: float): string =
  ## Shortest round-tripping decimal via stdlib Schubfach (NOT nkdl's
  ## formatter — a sanctioned independent oracle; we test nkdl's float
  ## *decoder*). Ensure a `.`/exponent so it lexes as a float, not an int.
  result = ""
  result.addFloatRoundtrip(f)
  if '.' notin result and 'e' notin result and 'E' notin result:
    result.add ".0"

proc finiteFloatSurfaces*(): Strategy[ValueSurface] =
  ## Finite, non-keyword floats (inf/nan are the keyword slice). A `+` sign is
  ## added to a random subset of positives (grammar `sign := '+' | '-'`).
  map(floats(-1e12, 1e12, allowNan = false), booleans(),
      proc(f: float, plus: bool): ValueSurface =
        var t = renderFloat(f)
        if plus and t.len > 0 and t[0] notin {'-', '+'}: t = "+" & t
        ValueSurface(text: t, value: newKdlFloat(f)))

# ---------------------------------------------------------------------------
# Slice 5 — keyword values
# ---------------------------------------------------------------------------

proc keywordSurfaces*(): Strategy[ValueSurface] =
  ## The six `#`-keyword values.
  sampledFrom(@[
    ("#true",  newKdlBool(true)),
    ("#false", newKdlBool(false)),
    ("#null",  newKdlNull()),
    ("#inf",   newKdlFloat(Inf)),
    ("#-inf",  newKdlFloat(NegInf)),
    ("#nan",   newKdlFloat(NaN)),
  ]).map(proc(p: (string, KdlValue)): ValueSurface =
    ValueSurface(text: p[0], value: p[1]))

# ---------------------------------------------------------------------------
# Slice 6 — plain (regular) strings, no escapes
# ---------------------------------------------------------------------------

proc plainStringSurfaces*(): Strategy[ValueSurface] =
  ## `"…"` whose body is printable ASCII minus `"` (0x22) and `\` (0x5C),
  ## so it needs no escaping. value = the verbatim bytes.
  strings(intervals([(0x20'i32, 0x21'i32),
                     (0x23'i32, 0x5B'i32),
                     (0x5D'i32, 0x7E'i32)]), 0, 32)
    .map(proc(s: string): ValueSurface =
      ValueSurface(text: "\"" & s & "\"", value: newKdlString(s)))

# ---------------------------------------------------------------------------
# Slice 7 — escaped regular strings
# ---------------------------------------------------------------------------

func escapeRegular(s: string): string =
  ## Independent escaper: short forms for the named escapes, `\u{HH}` for the
  ## remaining control codes, verbatim for the rest. Shares no code with
  ## nkdl's emitter. Input is ASCII (one byte = one codepoint).
  for ch in s:
    case ch
    of '"':  result.add "\\\""
    of '\\': result.add "\\\\"
    of '\n': result.add "\\n"
    of '\t': result.add "\\t"
    of '\r': result.add "\\r"
    of '\b': result.add "\\b"
    of '\x0C': result.add "\\f"
    else:
      # Disallowed-literal codepoints (C0 controls AND DEL 0x7F) must be
      # escaped; verbatim DEL is invalid KDL, which nkdl correctly rejects.
      if ord(ch) < 0x20 or ord(ch) == 0x7F:
        result.add "\\u{" & toLowerAscii(toHex(ord(ch), 2)) & "}"
      else:
        result.add ch

proc escapedStringSurfaces*(): Strategy[ValueSurface] =
  ## Arbitrary ASCII strings (incl. `"`, `\`, controls) rendered with escapes;
  ## value is the decoded original. Exercises escape DECODING.
  strings(intervals([(0x00'i32, 0x7F'i32)]), 0, 24)
    .map(proc(s: string): ValueSurface =
      ValueSurface(text: "\"" & escapeRegular(s) & "\"", value: newKdlString(s)))

# ---------------------------------------------------------------------------
# Slice 8 — \u{} escapes (ordinary scalar values)
#
#   string-character := '\\' (... | 'u{' hex-unicode '}') | ...
#   hex-unicode      := hex-digit{1, 6} - surrogate - above-max-scalar
# Tests the \u{} mechanics — 1..6 digits, case, leading zeros, multi-byte
# UTF-8 — on ordinary codepoints. Disallowed-literal codepoints (controls,
# DEL, bidi, BOM), which the spec permits *only* via escape, are a separate
# deliberate slice. value = the codepoint's UTF-8.
# ---------------------------------------------------------------------------

func renderUnicodeEscape(cp: int, pad: int, upper: bool): string =
  ## `\u{...}` for `cp`, with `pad` extra leading zeros (total digits capped
  ## at 6) and chosen hex case. Hand-written; shares nothing with the lexer.
  var nat = toHex(cp, 6)                       # 6 uppercase hex digits
  while nat.len > 1 and nat[0] == '0': nat = nat[1 .. ^1]
  let total = min(6, nat.len + pad)
  var digits = repeat('0', total - nat.len) & nat
  if not upper: digits = toLowerAscii(digits)
  "\\u{" & digits & "}"

proc unicodeEscapeSurfaces*(): Strategy[ValueSurface] =
  ## A single `\u{}`-escaped ordinary scalar value inside a `"…"`. Codepoints
  ## are drawn from gap-free interval ranges (so no rejection): they avoid
  ## surrogates (D800-DFFF), bidi (200E-200F, 202A-202E, 2066-2069), BOM
  ## (FEFF), DEL (7F), and the C0/C1 control blocks — all of which are the
  ## escaped-disallowed-literal slice's job. One codepoint = the value's UTF-8.
  map(strings(intervals([
        (0x20'i32,    0x7E'i32),       # printable ASCII (no DEL)
        (0x00A0'i32,  0x024F'i32),     # Latin-1 supplement + extended
        (0x0370'i32,  0x1FFF'i32),     # Greek … (before the 0x200x bidi)
        (0x2030'i32,  0x205F'i32),     # after the 0x202x bidi
        (0x3000'i32,  0xD7FF'i32),     # CJK … up to the surrogate block
        (0xE000'i32,  0xFDFF'i32),     # private use … before BOM
        (0x10000'i32, 0x10FFFF'i32),   # astral planes
      ]), 1, 1), integers(0, 5), booleans(),
      proc(s: string, pad: int, upper: bool): ValueSurface =
        let cp = int(s.runeAt(0))
        ValueSurface(text: "\"" & renderUnicodeEscape(cp, pad, upper) & "\"",
                     value: newKdlString(s)))

# ---------------------------------------------------------------------------
# Slice 9 — ws-escape (line continuation) in strings
#
#   ws-escape := '\\' (unicode-space | newline)+
# A `\` followed by a run of whitespace/newlines (ASCII OR Unicode) elides
# entirely. Injecting ws-escapes into a string must NOT change its value —
# the generative form of the review-#8 fix. value = the base bytes.
# ---------------------------------------------------------------------------

const wsEscapeForms = [
  "\\ ", "\\\t", "\\\n", "\\\r", "\\ \t",        # ASCII single + run
  "\\\n  ",                                       # `\` + newline + indent
  "\\\xC2\xA0",                                   # `\` + U+00A0 NBSP
  "\\\xE2\x80\xA8",                               # `\` + U+2028 LINE SEPARATOR
  "\\\xE2\x80\x89",                               # `\` + U+2009 THIN SPACE
  "\\ \xC2\xA0\t",                                # `\` + mixed ASCII/Unicode run
]

proc wsEscapeStringSurfaces*(): Strategy[ValueSurface] =
  ## Base string (a–z) with `\<ws+>` line-continuations injected at a random
  ## subset of slots; every injection elides, so value = the base bytes.
  strings(intervals([(0x61'i32, 0x7A'i32)]), 0, 8).flatMap(proc(base: string): Strategy[ValueSurface] =
    lists(integers(0, wsEscapeForms.len), base.len + 1, base.len + 1).map(
      proc(picks: seq[int]): ValueSurface =
        var t = "\""
        for i in 0 .. base.len:
          if picks[i] > 0: t.add wsEscapeForms[picks[i] - 1]   # inject ws-escape
          if i < base.len: t.add base[i]
        t.add "\""
        ValueSurface(text: t, value: newKdlString(base))))

# ---------------------------------------------------------------------------
# Slice 10 — raw strings
#
#   raw-string := '#' raw-string-quotes '#' | '#' raw-string '#'
#   single-line-raw-string-char := unicode - newline - disallowed-literal
# No escapes — the body is verbatim. We use a body with no '#', so the close
# `"#…#` only matches at the wrapper regardless of hash count; '"' and '\'
# appear literally. value = the body bytes.
# ---------------------------------------------------------------------------

proc rawStringSurfaces*(): Strategy[ValueSurface] =
  ## `#…#"body"#…#` with 1–5 hashes. Per single-line-raw-string-body, a body
  ## may NOT be a lone `"` nor start with `""` (that forms the `"""` marker),
  ## so we draw one of its three valid shapes: empty, non-quote-first, or
  ## one-quote-then-non-quote. `"` (mid/end) and `\` appear verbatim; no `#`
  ## in the body so any hash count closes only at the wrapper. value = body.
  # single-line-raw-string-body := '' | (char-'"') char*? | '"' (char-'"') char*?
  let nonQuote = strings(intervals([(0x20'i32, 0x21'i32), (0x24'i32, 0x7E'i32)]), 1, 1)
  let full     = strings(intervals([(0x20'i32, 0x22'i32), (0x24'i32, 0x7E'i32)]), 0, 14)
  let bodyGen = frequency([
    (1, just("")),                                                 # ''
    (8, map(nonQuote, full, proc(a, b: string): string = a & b)),  # (char-'"') char*?
    (3, map(nonQuote, full, proc(a, b: string): string = "\"" & a & b)),  # '"' (char-'"') char*?
  ])
  map(integers(1, 5), bodyGen, proc(n: int, body: string): ValueSurface =
    let hashes = repeat('#', n)
    ValueSurface(text: hashes & "\"" & body & "\"" & hashes,
                 value: newKdlString(body)))

# ---------------------------------------------------------------------------
# Slice 11 — multi-line strings + dedent
#
# Per the spec (Multi-line String): open `"""` + immediate newline; the final
# line is whitespace-only before the closing `"""`, and THAT whitespace is the
# prefix stripped from every line; the value omits the first+last newline, the
# final line's whitespace, and the matching prefix on each line; whitespace-
# only lines become empty lines. We render LITERAL content (escapes are shared
# with the single-line slices) so value = the lines joined by '\n'.
# Line alphabet excludes space (so a non-empty line is never whitespace-only),
# '"' (avoid forming '"""'), and '\' (no accidental escapes).
# ---------------------------------------------------------------------------

proc multilineStringSurfaces*(): Strategy[ValueSurface] =
  ## `"""<nl> (prefix line <nl>)* prefix"""` with a shared whitespace prefix.
  let prefixGen = strings(intervals([(0x20'i32, 0x20'i32), (0x09'i32, 0x09'i32)]), 0, 4)
  let lineGen = frequency([
    (2, just("")),                                                    # whitespace-only ⇒ empty value line
    (8, strings(intervals([(0x21'i32, 0x21'i32),                      # non-space, non-'"', non-'\'
                           (0x23'i32, 0x5B'i32),
                           (0x5D'i32, 0x7E'i32)]), 1, 8)),
  ])
  map(prefixGen, lists(lineGen, 0, 4),
      proc(p: string, lines: seq[string]): ValueSurface =
        var t = "\"\"\"\n"
        for ln in lines: t.add p & ln & "\n"
        t.add p & "\"\"\""
        ValueSurface(text: t, value: newKdlString(lines.join("\n"))))

# ---------------------------------------------------------------------------
# Slice 12 — node-space trivia (whitespace, block comments, esclines)
#
#   node-space := ws* escline ws* | ws+
#   ws         := unicode-space | multi-line-comment      (NOT single-line!)
#   escline    := '\\' ws* (single-line-comment | newline | eof)
#   multi-line-comment := '/*' commented-block            (nestable)
# Block comments are node-space; line comments are only reachable via an
# escline. None of it changes the decoded value. Targets skipBlockComment /
# skipLineComment / skipLineContinuation.
# ---------------------------------------------------------------------------

proc nodeSpaceTrivia(): Strategy[string] =
  ## A sequence of valid node-space pieces, space-joined (the join space is
  ## itself node-space, and guarantees no adjacency ambiguity between pieces).
  let piece = frequency([
    (5, strings(intervals([(0x20'i32, 0x20'i32), (0x09'i32, 0x09'i32)]), 1, 3)),  # ws run
    (2, just("/* comment */")),                       # block comment
    (2, just("/* a /* nested */ b */")),              # nested block comment
    (2, just("\\\n")),                                # escline: '\' newline
    (2, just("\\ \t\n")),                             # escline: '\' ws* newline
    (2, just("\\ // trailing\n")),                    # escline: '\' ws* single-line-comment
  ])
  lists(piece, 0, 4).map(proc(ps: seq[string]): string = ps.join(" "))

proc triviaSurfaces*(): Strategy[ValueSurface] =
  ## An integer value preceded by arbitrary valid node-space trivia and
  ## optionally followed by a node-terminator line comment (`// …` runs to
  ## newline/eof). The value is unchanged regardless. The trailing comment
  ## covers the line-comment-as-terminator path (skipLineComment).
  map(nodeSpaceTrivia(), integers(-9999, 9999), booleans(),
      proc(triv: string, n: int, trailComment: bool): ValueSurface =
        let tail = if trailComment: " // trailing comment" else: ""
        ValueSurface(text: triv & " " & $n & tail, value: newKdlInt(n.int64)))

# ---------------------------------------------------------------------------
# Slice 13 — bareword identifiers (node names)
#
#   identifier-string := (unambiguous-ident | ...) - disallowed-keyword-identifiers
#   unambiguous-ident := (identifier-char - digit - sign - '.') identifier-char*
#   identifier-char   := unicode - unicode-space - newline
#                        - [\\/(){};\[\]"#=] - disallowed-literal-code-points
# Barewords are node NAMES (not arg values), so this has its own property.
# We cover unambiguous-ident over ASCII + Unicode identifier-chars (exercises
# isIdentCodepoint), excluding the reserved keyword barewords.
# ---------------------------------------------------------------------------

proc identifierNames*(): Strategy[string] =
  ## A first char that is an identifier-char but not digit/sign/'.', then any
  ## identifier-chars. Excludes true/false/null/inf/-inf/nan (reserved).
  let startCh = strings(intervals([
    (0x41'i32, 0x5A'i32), (0x61'i32, 0x7A'i32), (0x5F'i32, 0x5F'i32),  # A-Z a-z _
    (0x00C0'i32, 0x024F'i32), (0x0370'i32, 0x03FF'i32)]), 1, 1)        # Latin/Greek letters
  let restCh = strings(intervals([
    (0x41'i32, 0x5A'i32), (0x61'i32, 0x7A'i32), (0x30'i32, 0x39'i32),  # alnum
    (0x5F'i32, 0x5F'i32), (0x2D'i32, 0x2E'i32), (0x24'i32, 0x24'i32),  # _ - . $
    (0x00C0'i32, 0x024F'i32), (0x0370'i32, 0x03FF'i32)]), 0, 10)
  map(startCh, restCh, proc(a, b: string): string = a & b)
    .filter(proc(s: string): bool =
      s notin ["true", "false", "null", "inf", "-inf", "nan"])
