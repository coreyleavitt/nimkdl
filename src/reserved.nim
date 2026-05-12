## reserved — parse-time interpretation of KDL v2 reserved type
## annotations.
##
## Spec reference: draft-marchan-kdl2 §3 Components, "Reserved Type
## Annotations". The spec lists ~30 reserved tag names (numeric like
## `(u8)`, temporal like `(date-time)`, network like `(ipv4)`, etc.)
## and says implementations MAY recognize them; if they do, they SHOULD
## interpret the value per the cited RFC/ISO/IEEE standard.
##
## We choose to recognize them, which obligates us to validate. This
## module is the single source of truth for that validation, dispatched
## from both the hand parser (`parser.nim parseValue`) and the reference
## interpreter (`grammar.nim buildValue`) so both interpreters agree on
## what a reserved-tag-annotated value means.
##
## ## Scope
##
## Tier 1 (numeric range): `i8 i16 i32 i64 i128 u8 u16 u32 u64 u128
##                          isize usize f32 f64`
## Tier 2 (string formats): `uuid ipv4 ipv6 date time date-time duration
##                           base64 base85`
## Tier 3 (RFC-shape):      `email idn-email hostname idn-hostname url
##                           url-reference irl irl-reference url-template
##                           regex`
## Tier 4 (static tables):  `country-2 country-3 country-subdivision
##                           currency decimal decimal64 decimal128`
##
## Each tier lands as its own slice. This file is the dispatcher; the
## validators are added incrementally.
##
## ## Contract
##
## `validateReserved(tag, value)` returns `ok(void, ParseError)` when:
##   - The tag is not in the reserved registry (open-world: user-defined
##     tags pass through opaquely per spec).
##   - The tag is in the registry and the value's content matches the
##     standard interpretation.
##
## Returns `Err(peReservedTypeInvalid, ...)` when the tag is in the
## registry but the content doesn't match. The hint always cites the
## tag name and the specific constraint violated.
##
## All procs are `{.noSideEffect.}` so the chain stays VM-callable for
## `embed[T]` compile-time decode.

import ./ast
import ./spans

func intMismatch(v: KdlValue, tag: string): ParseError {.inline.} =
  initError(peReservedTypeInvalid, v.span,
            "(" & tag & ") requires an integer value")

func intOutOfRange(v: KdlValue, tag, lo, hi: string): ParseError {.inline.} =
  let shown =
    case v.kind
    of kvInt: $v.intVal
    of kvBigInt: "<128-bit magnitude>"
    else: "<non-integer>"
  initError(peReservedTypeInvalid, v.span,
            "(" & tag & ") value " & shown & " is out of range [" & lo &
            ", " & hi & "]")

func validateSignedInt(v: KdlValue, tag: string, lo, hi: int64):
    Result[void, ParseError] =
  ## Range check a signed integer reserved type. Caller supplies range.
  case v.kind
  of kvInt:
    if v.intVal < lo or v.intVal > hi:
      return err[void, ParseError](intOutOfRange(v, tag, $lo, $hi))
    return ok(void, ParseError)
  of kvBigInt:
    # Magnitude exceeds int64.high by definition; cannot fit any tag
    # narrower than i128.
    err[void, ParseError](intOutOfRange(v, tag, $lo, $hi))
  else:
    err[void, ParseError](intMismatch(v, tag))

func validateUnsignedInt(v: KdlValue, tag: string, hi: uint64):
    Result[void, ParseError] =
  ## Range check an unsigned integer reserved type. Caller supplies the
  ## upper bound; lower bound is implicit 0.
  case v.kind
  of kvInt:
    if v.intVal < 0:
      return err[void, ParseError](intOutOfRange(v, tag, "0", $hi))
    if uint64(v.intVal) > hi:
      return err[void, ParseError](intOutOfRange(v, tag, "0", $hi))
    return ok(void, ParseError)
  of kvBigInt:
    # Already > int64.high; for u8..u32 always out of range; for u64
    # accepted iff hi==0 and not negative. Handled by caller via
    # validateU64Big / validateU128Big helpers.
    err[void, ParseError](intOutOfRange(v, tag, "0", $hi))
  else:
    err[void, ParseError](intMismatch(v, tag))

func validateU64(v: KdlValue): Result[void, ParseError] =
  ## `(u64)` — 0 .. 2^64-1. kvBigInt with hi==0 and not negative fits.
  case v.kind
  of kvInt:
    if v.intVal < 0:
      return err[void, ParseError](intOutOfRange(v, "u64", "0", "18446744073709551615"))
    return ok(void, ParseError)
  of kvBigInt:
    if v.bigNegative or v.bigHi != 0:
      return err[void, ParseError](intOutOfRange(v, "u64", "0", "18446744073709551615"))
    return ok(void, ParseError)  # bigLo fits since bigHi == 0
  else:
    err[void, ParseError](intMismatch(v, "u64"))

func validateI64(v: KdlValue): Result[void, ParseError] =
  ## `(i64)` — kvInt always fits (int64 range is the kvInt range); any
  ## kvBigInt magnitude exceeds it.
  case v.kind
  of kvInt: ok(void, ParseError)
  of kvBigInt:
    err[void, ParseError](intOutOfRange(v, "i64",
      "-9223372036854775808", "9223372036854775807"))
  else:
    err[void, ParseError](intMismatch(v, "i64"))

func validateI128(v: KdlValue): Result[void, ParseError] =
  ## `(i128)` — signed 128-bit range: −2^127 .. 2^127 − 1.
  ## Magnitude is (bigHi shl 64) or bigLo; we use a top-bit comparison.
  case v.kind
  of kvInt: ok(void, ParseError)  # int64 always fits i128
  of kvBigInt:
    # 2^127 = bigHi == 0x8000_0000_0000_0000, bigLo == 0.
    # Positive max: 2^127 - 1 → bigHi == 0x7FFF_FFFF_FFFF_FFFF, bigLo == max.
    # Negative min: 2^127 magnitude with sign bit. So magnitude must be
    # <= (1 shl 127) - 1 if positive, or <= (1 shl 127) if negative.
    if v.bigNegative:
      if v.bigHi > 0x8000_0000_0000_0000'u64 or
         (v.bigHi == 0x8000_0000_0000_0000'u64 and v.bigLo != 0):
        return err[void, ParseError](intOutOfRange(v, "i128",
          "-2^127", "2^127-1"))
    else:
      if v.bigHi >= 0x8000_0000_0000_0000'u64:
        return err[void, ParseError](intOutOfRange(v, "i128",
          "-2^127", "2^127-1"))
    return ok(void, ParseError)
  else:
    err[void, ParseError](intMismatch(v, "i128"))

func validateU128(v: KdlValue): Result[void, ParseError] =
  ## `(u128)` — 0 .. 2^128 − 1. Any non-negative magnitude fits since
  ## we cap parsing at 128 bits already.
  case v.kind
  of kvInt:
    if v.intVal < 0:
      return err[void, ParseError](intOutOfRange(v, "u128", "0", "2^128-1"))
    return ok(void, ParseError)
  of kvBigInt:
    if v.bigNegative:
      return err[void, ParseError](intOutOfRange(v, "u128", "0", "2^128-1"))
    return ok(void, ParseError)  # already capped at 128 bits at parse
  else:
    err[void, ParseError](intMismatch(v, "u128"))

func validateF32(v: KdlValue): Result[void, ParseError] =
  ## `(f32)` — IEEE-754 single precision. Finite values must fit
  ## ~|3.4028e38|; ±Inf and NaN pass.
  const f32Max = 3.4028234663852886e38
  case v.kind
  of kvFloat:
    let f = v.floatVal
    if f != f: return ok(void, ParseError)  # NaN
    if f == Inf or f == NegInf: return ok(void, ParseError)
    if f > f32Max or f < -f32Max:
      return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
        "(f32) value " & $f & " exceeds IEEE-754 single-precision range"))
    return ok(void, ParseError)
  of kvInt: ok(void, ParseError)
  of kvBigInt: ok(void, ParseError)
  else:
    err[void, ParseError](initError(peReservedTypeInvalid, v.span,
      "(f32) requires a numeric value"))

func validateF64(v: KdlValue): Result[void, ParseError] =
  ## `(f64)` — IEEE-754 double precision. Any KDL float / int fits by
  ## construction (KDL floats are parsed via Nim's parseFloat which is
  ## double-precision).
  case v.kind
  of kvFloat, kvInt, kvBigInt: ok(void, ParseError)
  else:
    err[void, ParseError](initError(peReservedTypeInvalid, v.span,
      "(f64) requires a numeric value"))

func validateReserved*(tag: string, v: KdlValue):
    Result[void, ParseError] {.noSideEffect.} =
  ## Dispatch a reserved tag to its validator. Returns ok for unknown
  ## tags (open-world per spec) and ok for known tags with valid content.
  case tag
  of "i8":    validateSignedInt(v, "i8",   -128'i64, 127'i64)
  of "i16":   validateSignedInt(v, "i16",  -32768'i64, 32767'i64)
  of "i32":   validateSignedInt(v, "i32",  -2147483648'i64, 2147483647'i64)
  of "i64":   validateI64(v)
  of "i128":  validateI128(v)
  of "u8":    validateUnsignedInt(v, "u8",  255'u64)
  of "u16":   validateUnsignedInt(v, "u16", 65535'u64)
  of "u32":   validateUnsignedInt(v, "u32", 4294967295'u64)
  of "u64":   validateU64(v)
  of "u128":  validateU128(v)
  of "isize": validateI64(v)  ## platform-dependent; we treat as int64
  of "usize": validateU64(v)  ## platform-dependent; we treat as uint64
  of "f32":   validateF32(v)
  of "f64":   validateF64(v)
  else:       return ok(void, ParseError)  # user-defined or not-yet-implemented
