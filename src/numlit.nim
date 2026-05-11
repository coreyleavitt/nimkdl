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

func decodeIntFromToken*(tok: Token): Result[int64, ParseError] =
  ## Decode a `tkNumber` token's raw integer text into `int64`, respecting
  ## sign and base. Handles `int64.low` correctly via uint64 accumulation
  ## (a value the naïve decode-magnitude-then-negate path can't represent).
  ##
  ## Returns `peLexInvalidNumber` on any digit-character mismatch or
  ## true overflow.
  assert tok.kind == tkNumber
  var s = tok.numText
  if s.len > 0 and (s[0] == '+' or s[0] == '-'):
    s = s[1 .. ^1]
  if tok.numBase != nbDecimal and s.len >= 2:
    s = s[2 .. ^1]
  let radix = radixOf(tok.numBase)
  let radixU = uint64(radix)
  let limit =
    if tok.numNegative: Int64LowMagU
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
        initError(peLexInvalidNumber, tok.span, "invalid digit for base"))
    # Pre-multiplication overflow check against the *signed* limit for
    # this token's sign. We need `acc * radix + d <= limit`.
    if acc > (limit - uint64(d)) div radixU:
      return err[int64, ParseError](
        initError(peLexInvalidNumber, tok.span,
                  "integer literal does not fit in int64"))
    acc = acc * radixU + uint64(d)
  if tok.numNegative:
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
# Float decode
# ---------------------------------------------------------------------------

func decodeFloatFromToken*(tok: Token): Result[float, ParseError] =
  ## Decode a `tkNumber` token's raw float text. Non-raising — uses
  ## `parseutils.parseFloat` which returns 0 on failure rather than
  ## raising `ValueError`. This is the property `parser.nim`'s
  ## `{.noSideEffect.}` contract needs.
  assert tok.kind == tkNumber
  # parseutils doesn't strip underscores; strip them first.
  var clean = newStringOfCap(tok.numText.len)
  for c in tok.numText:
    if c != '_': clean.add(c)
  var value: float
  let consumed = parseutils.parseFloat(clean, value)
  if consumed == 0 or consumed != clean.len:
    return err[float, ParseError](
      initError(peLexInvalidNumber, tok.span, "malformed float literal"))
  ok[float, ParseError](value)

# ---------------------------------------------------------------------------
# Float-vs-int classification
# ---------------------------------------------------------------------------

func looksLikeFloat*(tok: Token): bool {.inline.} =
  ## A decimal number is a float iff it carries a fractional part or
  ## an exponent. Hex/oct/bin literals are always integers.
  tok.numBase == nbDecimal and
    ('.' in tok.numText or 'e' in tok.numText or 'E' in tok.numText)
