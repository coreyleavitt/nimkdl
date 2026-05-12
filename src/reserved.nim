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

func isHexDigit(c: char): bool {.inline.} =
  case c
  of '0'..'9', 'a'..'f', 'A'..'F': true
  else: false

func validateUuid(v: KdlValue): Result[void, ParseError] =
  ## `(uuid)` — RFC 4122 §3 UUID textual representation:
  ##   `XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX`
  ## where each X is a hex digit. We accept either case (RFC allows
  ## upper or lower) but require the exact 8-4-4-4-12 layout.
  if v.kind != kvString:
    return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
      "(uuid) requires a string value"))
  let s = v.strVal
  if s.len != 36:
    return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
      "(uuid) must be exactly 36 characters (got " & $s.len & ")"))
  const dashAt = [8, 13, 18, 23]
  for i, c in s:
    if i in dashAt:
      if c != '-':
        return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
          "(uuid) expected '-' at position " & $i))
    else:
      if not isHexDigit(c):
        return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
          "(uuid) non-hex digit at position " & $i))
  ok(void, ParseError)

func parseIpv4Bytes(s: string): bool =
  ## Parse `a.b.c.d` per RFC 791 strict form: exactly 4 dot-separated
  ## decimal octets, each in [0, 255], no leading zeros (per RFC 6943).
  var octets = 0
  var i = 0
  while i < s.len:
    var n = 0
    var digits = 0
    let octStart = i
    while i < s.len and s[i] >= '0' and s[i] <= '9':
      n = n * 10 + int(s[i]) - int('0')
      inc digits
      inc i
      if n > 255 or digits > 3: return false
    if digits == 0: return false
    # Leading zero rule: "07" / "001" / "00" all rejected (RFC 6943).
    if digits > 1 and s[octStart] == '0': return false
    inc octets
    if i < s.len:
      if s[i] != '.': return false
      inc i
      # Trailing dot or empty after dot is invalid.
      if i >= s.len: return false
  octets == 4

func validateIpv4(v: KdlValue): Result[void, ParseError] =
  ## `(ipv4)` — RFC 791 dotted-decimal four-octet address.
  if v.kind != kvString:
    return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
      "(ipv4) requires a string value"))
  if not parseIpv4Bytes(v.strVal):
    return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
      "(ipv4) malformed address: " & v.strVal))
  ok(void, ParseError)

func parseIpv6Bytes(s: string): bool =
  ## Parse `[hexgroup:]*[::[hexgroup:]*]?` per RFC 4291 §2.2.
  ## Allows the embedded IPv4 form in the final 32 bits.
  ## We count groups before and after `::` (if present) and verify
  ## total = 8, with embedded ipv4 counting as 2.
  if s.len == 0: return false
  var i = 0
  var beforeDouble = 0  # 16-bit hex groups before `::`
  var afterDouble = -1  # -1 means no `::` seen yet
  # Allow leading `::`
  if s.len >= 2 and s[0] == ':' and s[1] == ':':
    afterDouble = 0
    i = 2
  elif s.len >= 1 and s[0] == ':':
    return false  # single leading `:` invalid
  while i < s.len:
    # Parse a hex group (1-4 hex digits) OR detect embedded ipv4
    var hexStart = i
    var hexDigits = 0
    while i < s.len and isHexDigit(s[i]):
      inc hexDigits
      inc i
      if hexDigits > 4: return false
    if hexDigits == 0:
      # Either we just saw `::` or trailing colon; check.
      if i < s.len and s[i] == ':':
        # `::` here
        if i + 1 < s.len and s[i + 1] == ':':
          if afterDouble >= 0: return false  # second `::` invalid
          afterDouble = 0
          i += 2
          continue
        return false
      return false
    # If next char is '.', this is an embedded IPv4 in the final 32 bits.
    if i < s.len and s[i] == '.':
      let v4 = s[hexStart .. s.high]
      if not parseIpv4Bytes(v4): return false
      # Embedded IPv4 occupies 2 of the 8 groups (counts as final 32 bits)
      if afterDouble >= 0: afterDouble += 2
      else: beforeDouble += 2
      i = s.len
      break
    if afterDouble >= 0: inc afterDouble
    else: inc beforeDouble
    if i >= s.len: break
    if s[i] != ':': return false
    inc i
    # `::` after a hex group
    if i < s.len and s[i] == ':':
      if afterDouble >= 0: return false  # second `::` invalid
      afterDouble = 0
      inc i
      # Allow trailing `::` to terminate
      if i >= s.len: return true
  if afterDouble >= 0:
    # `::` compresses one-or-more zero groups; total before+after must
    # be < 8 (otherwise `::` is redundant — though RFC 5952 forbids
    # that, RFC 4291 allows it).
    return beforeDouble + afterDouble <= 8
  beforeDouble == 8

func validateIpv6(v: KdlValue): Result[void, ParseError] =
  ## `(ipv6)` — RFC 4291 §2.2 textual address. Accepts the canonical
  ## colon-separated 16-bit groups, `::` zero-run compression, and the
  ## embedded-IPv4 form for the final 32 bits.
  if v.kind != kvString:
    return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
      "(ipv6) requires a string value"))
  if not parseIpv6Bytes(v.strVal):
    return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
      "(ipv6) malformed address: " & v.strVal))
  ok(void, ParseError)

func isDigit(c: char): bool {.inline.} =
  c >= '0' and c <= '9'

func parseUInt(s: string, start, count: int, value: var int): bool =
  ## Parse exactly `count` decimal digits at `s[start..]` into `value`.
  if start + count > s.len: return false
  value = 0
  for i in 0 ..< count:
    let c = s[start + i]
    if not isDigit(c): return false
    value = value * 10 + int(c) - int('0')
  true

func isLeapYear(y: int): bool =
  (y mod 4 == 0 and y mod 100 != 0) or y mod 400 == 0

func daysInMonth(y, m: int): int =
  case m
  of 1, 3, 5, 7, 8, 10, 12: 31
  of 4, 6, 9, 11: 30
  of 2: (if isLeapYear(y): 29 else: 28)
  else: 0

func validateDateBody(s: string, start: int): bool =
  ## RFC 3339 full-date: `YYYY-MM-DD`. Returns true iff s[start..start+9]
  ## is a valid calendar date.
  if start + 10 > s.len: return false
  if s[start + 4] != '-' or s[start + 7] != '-': return false
  var year, month, day: int
  if not parseUInt(s, start, 4, year): return false
  if not parseUInt(s, start + 5, 2, month): return false
  if not parseUInt(s, start + 8, 2, day): return false
  if month < 1 or month > 12: return false
  let dim = daysInMonth(year, month)
  day >= 1 and day <= dim

func validateTimeBody(s: string, start: int): tuple[ok: bool, consumed: int] =
  ## RFC 3339 partial-time + optional time-offset. Returns the number of
  ## characters consumed. Format: `hh:mm:ss[.frac][Z|±hh:mm]`.
  if start + 8 > s.len: return (false, 0)
  if s[start + 2] != ':' or s[start + 5] != ':': return (false, 0)
  var hour, minute, second: int
  if not parseUInt(s, start, 2, hour): return (false, 0)
  if not parseUInt(s, start + 3, 2, minute): return (false, 0)
  if not parseUInt(s, start + 6, 2, second): return (false, 0)
  if hour > 23 or minute > 59 or second > 60: return (false, 0)
  # RFC 3339 allows second == 60 for leap seconds.
  var i = start + 8
  # Optional fractional seconds.
  if i < s.len and s[i] == '.':
    inc i
    let fracStart = i
    while i < s.len and isDigit(s[i]):
      inc i
    if i == fracStart: return (false, 0)
  # Optional time offset.
  if i >= s.len:
    return (true, i - start)
  if s[i] == 'Z' or s[i] == 'z':
    inc i
    return (true, i - start)
  if s[i] == '+' or s[i] == '-':
    inc i
    var offHour, offMin: int
    if not parseUInt(s, i, 2, offHour): return (false, 0)
    if i + 2 >= s.len or s[i + 2] != ':': return (false, 0)
    if not parseUInt(s, i + 3, 2, offMin): return (false, 0)
    if offHour > 23 or offMin > 59: return (false, 0)
    i += 5
    return (true, i - start)
  (false, 0)

func validateDate(v: KdlValue): Result[void, ParseError] =
  ## `(date)` — RFC 3339 §5.6 full-date.
  if v.kind != kvString:
    return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
      "(date) requires a string value"))
  let s = v.strVal
  if s.len != 10 or not validateDateBody(s, 0):
    return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
      "(date) not a valid RFC 3339 full-date: " & s))
  ok(void, ParseError)

func validateTime(v: KdlValue): Result[void, ParseError] =
  ## `(time)` — RFC 3339 §5.6 full-time (partial-time + offset).
  if v.kind != kvString:
    return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
      "(time) requires a string value"))
  let s = v.strVal
  let (okt, consumed) = validateTimeBody(s, 0)
  if not okt or consumed != s.len:
    return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
      "(time) not a valid RFC 3339 time: " & s))
  ok(void, ParseError)

func validateDateTime(v: KdlValue): Result[void, ParseError] =
  ## `(date-time)` — RFC 3339 §5.6 date-time: full-date `T` full-time.
  if v.kind != kvString:
    return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
      "(date-time) requires a string value"))
  let s = v.strVal
  if s.len < 11:
    return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
      "(date-time) too short"))
  if not validateDateBody(s, 0):
    return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
      "(date-time) invalid date portion: " & s))
  if s[10] != 'T' and s[10] != 't':
    return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
      "(date-time) requires 'T' separator between date and time"))
  let (okt, consumed) = validateTimeBody(s, 11)
  if not okt or consumed != s.len - 11:
    return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
      "(date-time) invalid time portion: " & s))
  ok(void, ParseError)

func validateDuration(v: KdlValue): Result[void, ParseError] =
  ## `(duration)` — ISO 8601 §3.4 duration. Form:
  ##   P[nY][nM][nW][nD][T[nH][nM][nS]]
  ## At least one designator must appear (so `P` alone is invalid, but
  ## `P1Y` or `PT1S` are fine). `W` cannot mix with other date designators
  ## per strict ISO 8601 but RFC 3339 (and most real-world parsers)
  ## accept `P1W` standalone; we accept that.
  if v.kind != kvString:
    return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
      "(duration) requires a string value"))
  let s = v.strVal
  if s.len < 2 or s[0] != 'P':
    return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
      "(duration) must start with 'P': " & s))
  var i = 1
  var inTime = false
  var anyDesignator = false
  while i < s.len:
    if s[i] == 'T':
      if inTime:
        return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
          "(duration) duplicate 'T' separator"))
      inTime = true
      inc i
      continue
    # Number: 1+ digits, optional `.` + 1+ digits.
    let numStart = i
    while i < s.len and isDigit(s[i]):
      inc i
    if i == numStart:
      return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
        "(duration) expected digits before designator at offset " & $i))
    if i < s.len and s[i] == '.':
      inc i
      let fracStart = i
      while i < s.len and isDigit(s[i]):
        inc i
      if i == fracStart:
        return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
          "(duration) decimal fraction missing digits"))
    if i >= s.len:
      return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
        "(duration) number without designator"))
    let designator = s[i]
    let validInDate = designator in {'Y', 'M', 'W', 'D'}
    let validInTime = designator in {'H', 'M', 'S'}
    if inTime:
      if not validInTime:
        return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
          "(duration) invalid designator '" & $designator &
          "' in time portion"))
    else:
      if not validInDate:
        return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
          "(duration) invalid designator '" & $designator &
          "' (use 'T' to introduce time portion)"))
    anyDesignator = true
    inc i
  if not anyDesignator:
    return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
      "(duration) 'P' must be followed by at least one designator"))
  ok(void, ParseError)

func isBase64Char(c: char): bool {.inline.} =
  case c
  of 'A'..'Z', 'a'..'z', '0'..'9', '+', '/': true
  else: false

func validateBase64(v: KdlValue): Result[void, ParseError] =
  ## `(base64)` — RFC 4648 §4 standard alphabet, with `=` padding to a
  ## length multiple of 4. We accept canonical form; URL-safe variant
  ## (RFC 4648 §5) would be a separate tag.
  if v.kind != kvString:
    return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
      "(base64) requires a string value"))
  let s = v.strVal
  if s.len mod 4 != 0:
    return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
      "(base64) length must be a multiple of 4"))
  # Count trailing `=` (0, 1, or 2 allowed); padding only at end.
  var padCount = 0
  var i = s.len
  while i > 0 and s[i - 1] == '=':
    inc padCount
    dec i
    if padCount > 2:
      return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
        "(base64) at most 2 padding chars allowed"))
  for j in 0 ..< i:
    if not isBase64Char(s[j]):
      return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
        "(base64) invalid character at position " & $j))
  ok(void, ParseError)

const Base85Alphabet =
  "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz" &
  "!#$%&()*+-;<=>?@^_`{|}~"

func isBase85Char(c: char): bool {.inline.} =
  # 85 chars per RFC 1924 §3. Hot loop, use a case.
  case c
  of '0'..'9', 'A'..'Z', 'a'..'z': true
  of '!', '#', '$', '%', '&', '(', ')', '*', '+', '-',
     ';', '<', '=', '>', '?', '@', '^', '_', '`',
     '{', '|', '}', '~': true
  else: false

func validateBase85(v: KdlValue): Result[void, ParseError] =
  ## `(base85)` — RFC 1924 §3 alphabet. Spec checks alphabet only;
  ## length isn't constrained to a multiple in RFC 1924 (it's intended
  ## for IPv6 specifically, which is exactly 20 chars, but a general
  ## base85 string can be any length).
  if v.kind != kvString:
    return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
      "(base85) requires a string value"))
  for i, c in v.strVal:
    if not isBase85Char(c):
      return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
        "(base85) invalid character at position " & $i))
  ok(void, ParseError)

func isAsciiAlpha(c: char): bool {.inline.} =
  case c
  of 'a'..'z', 'A'..'Z': true
  else: false

func isAsciiAlphaNum(c: char): bool {.inline.} =
  case c
  of 'a'..'z', 'A'..'Z', '0'..'9': true
  else: false

func validateHostnameLabel(label: string): bool =
  ## RFC 1035 §2.3.1 label: 1-63 letters/digits/hyphens, must start
  ## and end with alphanumeric.
  if label.len == 0 or label.len > 63: return false
  if not isAsciiAlphaNum(label[0]): return false
  if not isAsciiAlphaNum(label[^1]): return false
  for c in label:
    if not (isAsciiAlphaNum(c) or c == '-'): return false
  true

func validateHostname(v: KdlValue): Result[void, ParseError] =
  ## `(hostname)` — RFC 1035 §2.3.1 preferred-name form. Dot-separated
  ## labels, each 1-63 alphanumerics-plus-hyphens, no leading/trailing
  ## hyphen. Total <= 253 chars.
  if v.kind != kvString:
    return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
      "(hostname) requires a string value"))
  let s = v.strVal
  if s.len == 0 or s.len > 253:
    return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
      "(hostname) length must be 1..253"))
  var labelStart = 0
  for i, c in s:
    if c == '.':
      if not validateHostnameLabel(s[labelStart ..< i]):
        return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
          "(hostname) invalid label: '" & s[labelStart ..< i] & "'"))
      labelStart = i + 1
  if not validateHostnameLabel(s[labelStart .. ^1]):
    return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
      "(hostname) invalid final label"))
  ok(void, ParseError)

func validateIdnHostnameLabel(label: string): bool =
  ## RFC 5891 IDN label: ASCII labels follow LDH rules; Unicode labels
  ## are anything not containing forbidden chars. We accept ASCII-LDH
  ## or any non-ASCII-containing label of length 1..63 bytes.
  if label.len == 0 or label.len > 63: return false
  var anyHigh = false
  for c in label:
    let b = uint8(c)
    if b >= 0x80'u8:
      anyHigh = true
    elif not isAsciiAlphaNum(c) and c != '-':
      return false
  if not anyHigh:
    if not isAsciiAlphaNum(label[0]) or not isAsciiAlphaNum(label[^1]):
      return false
  true

func validateIdnHostname(v: KdlValue): Result[void, ParseError] =
  ## `(idn-hostname)` — RFC 5891. We accept either ASCII (LDH form,
  ## including `xn--` punycode labels) or Unicode labels. Full IDNA2008
  ## compliance (NFC normalization, BiDi rules) is deferred — this is a
  ## shape check.
  if v.kind != kvString:
    return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
      "(idn-hostname) requires a string value"))
  let s = v.strVal
  if s.len == 0:
    return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
      "(idn-hostname) empty"))
  var labelStart = 0
  for i, c in s:
    if c == '.':
      if not validateIdnHostnameLabel(s[labelStart ..< i]):
        return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
          "(idn-hostname) invalid label"))
      labelStart = i + 1
  if not validateIdnHostnameLabel(s[labelStart .. ^1]):
    return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
      "(idn-hostname) invalid final label"))
  ok(void, ParseError)

func isUrlScheme(s: string, last: var int): bool =
  ## RFC 3986 §3.1: scheme = ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )
  ## Sets `last` to the index of the `:` if found.
  if s.len == 0 or not isAsciiAlpha(s[0]): return false
  var i = 1
  while i < s.len:
    let c = s[i]
    if c == ':':
      last = i
      return i > 0
    if not (isAsciiAlphaNum(c) or c == '+' or c == '-' or c == '.'):
      return false
    inc i
  false

func validateUrl(v: KdlValue): Result[void, ParseError] =
  ## `(url)` — RFC 3986 absolute URI shape: scheme `:` hier-part
  ## [`?` query] [`#` fragment]. Validates scheme syntax and requires
  ## a non-empty body after the scheme.
  if v.kind != kvString:
    return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
      "(url) requires a string value"))
  let s = v.strVal
  if s.len == 0:
    return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
      "(url) empty"))
  var colonAt = -1
  if not isUrlScheme(s, colonAt):
    return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
      "(url) missing or invalid scheme"))
  if colonAt + 1 >= s.len:
    return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
      "(url) scheme without body"))
  ok(void, ParseError)

func validateUrlReference(v: KdlValue): Result[void, ParseError] =
  ## `(url-reference)` — RFC 3986 §4.1: either an absolute URI or a
  ## relative-ref. Effectively any non-control string is acceptable
  ## syntactically; the empty string is also a valid relative-ref.
  if v.kind != kvString:
    return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
      "(url-reference) requires a string value"))
  # Allow empty; otherwise just reject ASCII control chars in the
  # reference (matches the URI ABNF's exclusion of CTL).
  for i, c in v.strVal:
    if uint8(c) < 0x20'u8 or uint8(c) == 0x7F'u8:
      return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
        "(url-reference) contains control character at position " & $i))
  ok(void, ParseError)

func validateIrl(v: KdlValue): Result[void, ParseError] =
  ## `(irl)` — RFC 3987 IRI. Same as URL but the "iunreserved" set
  ## allows non-ASCII. We require a valid scheme like (url) but accept
  ## any Unicode codepoints (other than disallowed-literal-codepoints
  ## which are already rejected at lex time).
  if v.kind != kvString:
    return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
      "(irl) requires a string value"))
  let s = v.strVal
  var colonAt = -1
  if not isUrlScheme(s, colonAt):
    return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
      "(irl) missing or invalid scheme"))
  if colonAt + 1 >= s.len:
    return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
      "(irl) scheme without body"))
  ok(void, ParseError)

func validateIrlReference(v: KdlValue): Result[void, ParseError] =
  ## `(irl-reference)` — RFC 3987 relative-or-absolute IRI. Like
  ## url-reference but Unicode is allowed in the path/query/fragment.
  if v.kind != kvString:
    return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
      "(irl-reference) requires a string value"))
  # Same minimal check as url-reference; non-ASCII is permitted.
  for i, c in v.strVal:
    if uint8(c) < 0x20'u8 or uint8(c) == 0x7F'u8:
      return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
        "(irl-reference) contains control character at position " & $i))
  ok(void, ParseError)

func validateUrlTemplate(v: KdlValue): Result[void, ParseError] =
  ## `(url-template)` — RFC 6570 URI Template. The literal portions
  ## follow URI rules; the expression portions are `{...}`. We require
  ## balanced `{` `}` (no nesting, no unclosed expression).
  if v.kind != kvString:
    return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
      "(url-template) requires a string value"))
  var inExpr = false
  for i, c in v.strVal:
    if c == '{':
      if inExpr:
        return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
          "(url-template) nested '{' at position " & $i))
      inExpr = true
    elif c == '}':
      if not inExpr:
        return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
          "(url-template) unmatched '}' at position " & $i))
      inExpr = false
  if inExpr:
    return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
      "(url-template) unclosed expression"))
  ok(void, ParseError)

func validateEmail(v: KdlValue): Result[void, ParseError] =
  ## `(email)` — RFC 5322 simplified: exactly one `@` separating a
  ## non-empty local-part from a hostname-shaped domain. Full RFC 5322
  ## grammar (quoted local-parts, comments, etc.) is deferred — this
  ## is the 99% form.
  if v.kind != kvString:
    return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
      "(email) requires a string value"))
  let s = v.strVal
  if s.len == 0:
    return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
      "(email) empty"))
  var atAt = -1
  for i, c in s:
    if c == '@':
      if atAt >= 0:
        return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
          "(email) multiple '@' chars"))
      atAt = i
  if atAt < 0:
    return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
      "(email) missing '@'"))
  if atAt == 0:
    return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
      "(email) empty local-part"))
  if atAt == s.len - 1:
    return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
      "(email) empty domain"))
  # Validate local-part: 1-64 chars, atom-shape (no spaces, no control).
  let local = s[0 ..< atAt]
  if local.len > 64:
    return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
      "(email) local-part exceeds 64 chars"))
  for c in local:
    let b = uint8(c)
    if b < 0x21'u8 or b == 0x7F'u8 or c == '@' or c == ',' or c == '<' or
       c == '>' or c == '"' or c == '\\':
      return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
        "(email) invalid character in local-part"))
  # Validate domain via hostname rules.
  let domain = s[atAt + 1 .. ^1]
  let domainV = newStringValue(domain, v.span)
  let dr = validateHostname(domainV)
  if dr.isErr:
    return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
      "(email) invalid domain: " & domain))
  ok(void, ParseError)

func validateIdnEmail(v: KdlValue): Result[void, ParseError] =
  ## `(idn-email)` — RFC 6531. Local-part may include UTF-8; domain
  ## follows IDN hostname rules.
  if v.kind != kvString:
    return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
      "(idn-email) requires a string value"))
  let s = v.strVal
  if s.len == 0:
    return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
      "(idn-email) empty"))
  var atAt = -1
  for i, c in s:
    if c == '@':
      if atAt >= 0:
        return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
          "(idn-email) multiple '@'"))
      atAt = i
  if atAt <= 0 or atAt == s.len - 1:
    return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
      "(idn-email) malformed"))
  let domain = s[atAt + 1 .. ^1]
  let domainV = newStringValue(domain, v.span)
  let dr = validateIdnHostname(domainV)
  if dr.isErr:
    return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
      "(idn-email) invalid domain"))
  ok(void, ParseError)

func validateRegex(v: KdlValue): Result[void, ParseError] =
  ## `(regex)` — ECMA-262 RegExp grammar (per spec). We don't run the
  ## regex; we validate the source: balanced `(` `)` and `[` `]`, no
  ## dangling `\` escapes. Full ECMA-262 syntax (named groups,
  ## lookahead, etc.) is implicitly accepted because we don't reject
  ## anything that's syntactically structured.
  if v.kind != kvString:
    return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
      "(regex) requires a string value"))
  let s = v.strVal
  if s.len == 0:
    return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
      "(regex) empty pattern"))
  var i = 0
  var parenDepth = 0
  var inClass = false
  while i < s.len:
    let c = s[i]
    if c == '\\':
      if i + 1 >= s.len:
        return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
          "(regex) dangling backslash"))
      i += 2
      continue
    if inClass:
      if c == ']':
        inClass = false
      inc i
      continue
    case c
    of '[':
      inClass = true
    of '(':
      inc parenDepth
    of ')':
      if parenDepth == 0:
        return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
          "(regex) unmatched ')'"))
      dec parenDepth
    else:
      discard
    inc i
  if inClass:
    return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
      "(regex) unclosed character class '['"))
  if parenDepth != 0:
    return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
      "(regex) unclosed group '('"))
  ok(void, ParseError)

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
  of "uuid":  validateUuid(v)
  of "ipv4":  validateIpv4(v)
  of "ipv6":  validateIpv6(v)
  of "date":      validateDate(v)
  of "time":      validateTime(v)
  of "date-time": validateDateTime(v)
  of "duration":  validateDuration(v)
  of "base64":    validateBase64(v)
  of "base85":    validateBase85(v)
  of "hostname":      validateHostname(v)
  of "idn-hostname":  validateIdnHostname(v)
  of "url":           validateUrl(v)
  of "url-reference": validateUrlReference(v)
  of "irl":           validateIrl(v)
  of "irl-reference": validateIrlReference(v)
  of "url-template":  validateUrlTemplate(v)
  of "email":         validateEmail(v)
  of "idn-email":     validateIdnEmail(v)
  of "regex":         validateRegex(v)
  else:       return ok(void, ParseError)  # user-defined or not-yet-implemented
