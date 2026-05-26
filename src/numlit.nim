## numlit — shared integer and float literal decoders.
##
## Both `parser.nim` and `grammar.nim` need to turn a `Token`'s raw
## number text into a typed value. Before this module they each had
## their own copy of the logic, which drifted into different
## behaviours on overflow (the parser correctly errored; the grammar's
## reference interpreter silently saturated). That divergence
## undermines the differential-oracle property the two parsers were
## paired up to provide. One source of truth here, both consume it.
##
## ## Why a separate file
##
## Lifting these helpers up to a module both parser and grammar can
## import avoids cyclic imports (parser doesn't depend on grammar;
## grammar can't depend on parser without a cycle) while keeping a
## single source of truth.
##
## ## Correctness notes
##
## - **int64.low** (`-9223372036854775808`). The magnitude `2^63` is
##   one more than `int64.high`. A naïve "decode magnitude as int64,
##   then negate" loses this value because the magnitude overflows
##   the signed range. We accumulate in `uint64` and only convert at
##   the end, bounds-checking against `uint64(int64.high) + 1` when
##   the literal is negative or `uint64(int64.high)` when positive.
## - **No exceptions across the parse boundary.** `parseFloat` from
##   `std/parseutils` (note: `parseutils.parseFloat`, not `strutils`)
##   returns the number of bytes consumed; zero means failure. No
##   `try`/`except` needed, so callers can stay `{.noSideEffect.}`.

import std/parseutils

import ./lexer
import ./spans

# ---------------------------------------------------------------------------
# Integer decode
# ---------------------------------------------------------------------------

const
  Int64HighU = uint64(int64.high)         ## 9_223_372_036_854_775_807
  Int64LowMagU = Int64HighU + 1'u64       ## 9_223_372_036_854_775_808

func radixOf*(base: NumberBase): int {.inline.} =
  case base
  of nbDecimal: 10
  of nbHex: 16
  of nbOctal: 8
  of nbBinary: 2

func decodeIntFromToken*(n: NumberPayload, span: Span): Result[int64, ParseError] =
  ## Decode a `tkNumber` token's raw integer text into `int64`, respecting
  ## sign and base. Handles `int64.low` correctly via uint64 accumulation
  ## (a value the naïve decode-magnitude-then-negate path can't represent).
  ##
  ## Returns `peLexInvalidNumber` on any digit-character mismatch or
  ## true overflow.
  var s = n.text
  if s.len > 0 and (s[0] == '+' or s[0] == '-'):
    s = s[1 .. ^1]
  if n.base != nbDecimal and s.len >= 2:
    s = s[2 .. ^1]
  let radix = radixOf(n.base)
  let radixU = uint64(radix)
  let limit =
    if n.negative: Int64LowMagU
    else: Int64HighU
  var acc: uint64 = 0
  for c in s:
    if c == '_': continue
    let d =
      case c
      of '0'..'9': int(ord(c) - ord('0'))
      of 'a'..'f': int(ord(c) - ord('a') + 10)
      of 'A'..'F': int(ord(c) - ord('A') + 10)
      else: -1
    if d < 0 or d >= radix:
      return err[int64, ParseError](
        initError(peLexInvalidNumber, span, "invalid digit for base"))
    # Pre-multiplication overflow check against the *signed* limit for
    # this token's sign. We need `acc * radix + d <= limit`.
    if acc > (limit - uint64(d)) div radixU:
      return err[int64, ParseError](
        initError(peLexInvalidNumber, span,
                  "integer literal does not fit in int64"))
    acc = acc * radixU + uint64(d)
  if n.negative:
    if acc == Int64LowMagU:
      # -2^63 — representable as int64 but not via simple negation
      # (the magnitude itself overflows the signed range). Cast through
      # int64 reinterpretation: int64.low has the same bit pattern as
      # uint64(-int64.low) = 2^63.
      return ok[int64, ParseError](low(int64))
    ok[int64, ParseError](-int64(acc))
  else:
    ok[int64, ParseError](int64(acc))

# ---------------------------------------------------------------------------
# 128-bit integer decode (kvBigInt promotion)
# ---------------------------------------------------------------------------

type
  IntDecode* = object
    ## Result of decoding a `tkNumber` integer when overflow past int64
    ## should produce a kvBigInt rather than an error. Callers inspect
    ## `fits64` to decide whether to emit kvInt or kvBigInt.
    fits64*: bool
    intVal*: int64    ## valid iff fits64
    bigHi*: uint64    ## valid iff not fits64
    bigLo*: uint64
    negative*: bool

func mulAdd128(hi, lo: var uint64, mul: uint64, add: uint64): bool =
  ## (hi:lo) := (hi:lo) * mul + add. Returns true on 128-bit overflow.
  ## Requires `mul < 2^32` and `add < 2^32` so intermediate products
  ## fit in uint64 — true for all radix ≤ 16 and digit ≤ 15.
  let l0 = lo and 0xFFFFFFFF'u64
  let l1 = lo shr 32
  let h0 = hi and 0xFFFFFFFF'u64
  let h1 = hi shr 32
  var c: uint64 = add
  let p0 = l0 * mul + c
  let r0 = p0 and 0xFFFFFFFF'u64
  c = p0 shr 32
  let p1 = l1 * mul + c
  let r1 = p1 and 0xFFFFFFFF'u64
  c = p1 shr 32
  let p2 = h0 * mul + c
  let r2 = p2 and 0xFFFFFFFF'u64
  c = p2 shr 32
  let p3 = h1 * mul + c
  let r3 = p3 and 0xFFFFFFFF'u64
  c = p3 shr 32
  if c != 0: return true
  lo = (r1 shl 32) or r0
  hi = (r3 shl 32) or r2
  false

func decodeIntPromoting*(n: NumberPayload, span: Span): Result[IntDecode, ParseError] =
  ## Decode an integer literal that may exceed int64.high. Produces
  ## `fits64 = true` when the value fits int64 (with int64.low special-
  ## cased like `decodeIntFromToken`); otherwise produces a 128-bit
  ## magnitude in (bigHi, bigLo) with sign in `negative`. 128-bit
  ## overflow still errors with `peLexInvalidNumber`.
  var s = n.text
  if s.len > 0 and (s[0] == '+' or s[0] == '-'):
    s = s[1 .. ^1]
  if n.base != nbDecimal and s.len >= 2:
    s = s[2 .. ^1]
  let radix = uint64(radixOf(n.base))
  var hi: uint64 = 0
  var lo: uint64 = 0
  for c in s:
    if c == '_': continue
    let d =
      case c
      of '0'..'9': uint64(ord(c) - ord('0'))
      of 'a'..'f': uint64(ord(c) - ord('a') + 10)
      of 'A'..'F': uint64(ord(c) - ord('A') + 10)
      else: high(uint64)
    if d >= radix:
      return err[IntDecode, ParseError](
        initError(peLexInvalidNumber, span, "invalid digit for base"))
    if mulAdd128(hi, lo, radix, d):
      return err[IntDecode, ParseError](
        initError(peLexInvalidNumber, span,
                  "integer literal exceeds 128 bits"))
  # Now (hi, lo) holds the unsigned magnitude.
  let neg = n.negative
  if hi == 0:
    if not neg:
      if lo <= Int64HighU:
        return ok[IntDecode, ParseError](IntDecode(
          fits64: true, intVal: int64(lo), negative: false))
    else:
      if lo <= Int64HighU:
        return ok[IntDecode, ParseError](IntDecode(
          fits64: true, intVal: -int64(lo), negative: true))
      if lo == Int64LowMagU:
        return ok[IntDecode, ParseError](IntDecode(
          fits64: true, intVal: low(int64), negative: true))
  # Doesn't fit int64 — emit as kvBigInt.
  ok[IntDecode, ParseError](IntDecode(
    fits64: false, bigHi: hi, bigLo: lo, negative: neg))

# ---------------------------------------------------------------------------
# Float decode
# ---------------------------------------------------------------------------

func decodeFloatFromToken*(n: NumberPayload, span: Span): Result[float, ParseError] =
  ## Decode a `tkNumber` token's raw float text. Non-raising — uses
  ## `parseutils.parseFloat` which returns 0 on failure rather than
  ## raising `ValueError`. This is the property `parser.nim`'s
  ## `{.noSideEffect.}` contract needs.
  # parseutils doesn't strip underscores. Most decimal float tokens
  # have none, so scan first and only allocate a stripped copy when
  # underscores are actually present — keeps the common case alloc-
  # free while still handling `1_000.5e1_2` correctly.
  var hasUnderscore = false
  for c in n.text:
    if c == '_': hasUnderscore = true; break
  let text =
    if hasUnderscore:
      var s = newStringOfCap(n.text.len)
      for c in n.text:
        if c != '_': s.add(c)
      s
    else:
      n.text
  var value: float
  let consumed = parseutils.parseFloat(text, value)
  if consumed == 0 or consumed != text.len:
    return err[float, ParseError](
      initError(peLexInvalidNumber, span, "malformed float literal"))
  ok[float, ParseError](value)

# ---------------------------------------------------------------------------
# Float-vs-int classification
# ---------------------------------------------------------------------------

func looksLikeFloat*(n: NumberPayload): bool {.inline.} =
  ## A decimal number is a float iff it carries a fractional part or
  ## an exponent. Hex/oct/bin literals are always integers.
  n.base == nbDecimal and
    ('.' in n.text or 'e' in n.text or 'E' in n.text)
