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

import std/[formatfloat, strutils]   # addFloatRoundtrip — stdlib, NOT nkdl's formatter
import proptest
import ../src/ast

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
                     value: newIntValue(value))))

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
        ValueSurface(text: t, value: newFloatValue(f)))

# ---------------------------------------------------------------------------
# Slice 5 — keyword values
# ---------------------------------------------------------------------------

proc keywordSurfaces*(): Strategy[ValueSurface] =
  ## The six `#`-keyword values.
  sampledFrom(@[
    ("#true",  newBoolValue(true)),
    ("#false", newBoolValue(false)),
    ("#null",  newNullValue()),
    ("#inf",   newFloatValue(Inf)),
    ("#-inf",  newFloatValue(NegInf)),
    ("#nan",   newFloatValue(NaN)),
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
      ValueSurface(text: "\"" & s & "\"", value: newStringValue(s)))

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
      ValueSurface(text: "\"" & escapeRegular(s) & "\"", value: newStringValue(s)))
