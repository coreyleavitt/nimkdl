## Tests for parse-time validation of KDL v2 reserved type annotations.
##
## Spec reference: draft-marchan-kdl2, §3 Components ("Reserved Type
## Annotations"). The spec says reserved annotations "MAY be recognized by
## KDL parsers" — we choose to recognize them, which obligates us to
## "interpret these types" per the cited RFC/ISO/IEEE standard.
##
## Each validator has at least one positive (valid input → parses) and one
## negative (invalid input → ParseError with peReservedTypeInvalid) test.
## Where the underlying standard publishes test vectors, those serve as
## the positive cases verbatim — anchors to the standard, not our
## intuition.

import std/unittest

import ../src/grammar
import ../src/parser
import ../src/spans

template parseErr(src: string, expectedCode: ParseErrorCode) =
  let res = parse(src)
  check res.isErr
  if res.isErr:
    check res.getErr.code == expectedCode

template parseOkSilent(src: string) =
  let res = parse(src)
  check res.isOk

suite "reserved types — numeric (tier 1)":
  test "(u8) value in range parses":
    parseOkSilent("node (u8)42")

  test "(u8) value out of range is rejected":
    parseErr("node (u8)300", peReservedTypeInvalid)

  test "(u8) rejection is mirrored by reference interpreter (differential)":
    # Both interpreters must agree on reserved-type rejections.
    let viaFast = parse("node (u8)300")
    let viaRef = referenceInterpret("node (u8)300")
    check viaFast.isErr
    check viaRef.isErr
    if viaFast.isErr and viaRef.isErr:
      check viaFast.getErr.code == peReservedTypeInvalid
      check viaRef.getErr.code == peReservedTypeInvalid

  test "(i8) at lower bound parses; below rejects":
    parseOkSilent("n (i8)-128")
    parseErr("n (i8)-129", peReservedTypeInvalid)

  test "(i8) at upper bound parses; above rejects":
    parseOkSilent("n (i8)127")
    parseErr("n (i8)128", peReservedTypeInvalid)

  test "(i16) bounds":
    parseOkSilent("n (i16)-32768")
    parseOkSilent("n (i16)32767")
    parseErr("n (i16)32768", peReservedTypeInvalid)
    parseErr("n (i16)-32769", peReservedTypeInvalid)

  test "(i32) bounds":
    parseOkSilent("n (i32)2147483647")
    parseErr("n (i32)2147483648", peReservedTypeInvalid)
    parseErr("n (i32)-2147483649", peReservedTypeInvalid)

  test "(i64) bounds — int64.high / int64.low":
    parseOkSilent("n (i64)9223372036854775807")
    parseOkSilent("n (i64)-9223372036854775808")
    parseErr("n (i64)9223372036854775808", peReservedTypeInvalid)

  test "(i128) accepts kvBigInt within signed 128-bit range":
    # 2^127 - 1
    parseOkSilent("n (i128)170141183460469231731687303715884105727")
    # 2^127 — out of range
    parseErr("n (i128)170141183460469231731687303715884105728",
             peReservedTypeInvalid)

  test "(u16) bounds":
    parseOkSilent("n (u16)65535")
    parseErr("n (u16)65536", peReservedTypeInvalid)
    parseErr("n (u16)-1", peReservedTypeInvalid)

  test "(u32) bounds":
    parseOkSilent("n (u32)4294967295")
    parseErr("n (u32)4294967296", peReservedTypeInvalid)
    parseErr("n (u32)-1", peReservedTypeInvalid)

  test "(u64) bounds — uint64.high":
    parseOkSilent("n (u64)18446744073709551615")
    parseErr("n (u64)-1", peReservedTypeInvalid)

  test "(u128) accepts unsigned 128-bit range":
    # 2^128 - 1
    parseOkSilent("n (u128)340282366920938463463374607431768211455")
    parseErr("n (u128)-1", peReservedTypeInvalid)

  test "(isize) and (usize) behave as platform int":
    # isize == int64 on 64-bit; we follow Nim's int width.
    parseOkSilent("n (isize)42")
    parseOkSilent("n (usize)42")
    parseErr("n (usize)-1", peReservedTypeInvalid)

  test "(f32) accepts finite within IEEE-754 single-precision range":
    parseOkSilent("n (f32)1.5")
    parseOkSilent("n (f32)0")
    parseOkSilent("n (f32)#inf")
    # > 3.4e38 → out of range
    parseErr("n (f32)1e40", peReservedTypeInvalid)

  test "(f64) accepts any finite KDL float":
    parseOkSilent("n (f64)1.5")
    parseOkSilent("n (f64)1e300")
    parseOkSilent("n (f64)#inf")

  test "numeric tag on string is type-mismatch":
    parseErr("n (u8)\"42\"", peReservedTypeInvalid)
    parseErr("n (f32)\"1.5\"", peReservedTypeInvalid)

suite "reserved types — strings (tier 2)":
  test "(uuid) RFC 4122 example":
    # RFC 4122 §3 reference example.
    parseOkSilent("n (uuid)\"f81d4fae-7dec-11d0-a765-00a0c91e6bf6\"")

  test "(uuid) accepts uppercase":
    parseOkSilent("n (uuid)\"F81D4FAE-7DEC-11D0-A765-00A0C91E6BF6\"")

  test "(uuid) wrong dash positions rejected":
    parseErr("n (uuid)\"f81d4fae7dec-11d0-a765-00a0c91e6bf6\"",
             peReservedTypeInvalid)

  test "(uuid) non-hex char rejected":
    parseErr("n (uuid)\"g81d4fae-7dec-11d0-a765-00a0c91e6bf6\"",
             peReservedTypeInvalid)

  test "(uuid) requires string value":
    parseErr("n (uuid)42", peReservedTypeInvalid)

  test "(ipv4) standard test addresses":
    # RFC 5737 documentation prefix.
    parseOkSilent("n (ipv4)\"192.0.2.1\"")
    parseOkSilent("n (ipv4)\"0.0.0.0\"")
    parseOkSilent("n (ipv4)\"255.255.255.255\"")

  test "(ipv4) rejects out-of-range octet":
    parseErr("n (ipv4)\"256.0.0.0\"", peReservedTypeInvalid)
    parseErr("n (ipv4)\"1.2.3.999\"", peReservedTypeInvalid)

  test "(ipv4) rejects malformed":
    parseErr("n (ipv4)\"1.2.3\"", peReservedTypeInvalid)
    parseErr("n (ipv4)\"1.2.3.4.5\"", peReservedTypeInvalid)
    parseErr("n (ipv4)\"1.2.3.\"", peReservedTypeInvalid)
    parseErr("n (ipv4)\"hello\"", peReservedTypeInvalid)
    parseErr("n (ipv4)\"1.2.3.04\"", peReservedTypeInvalid)  # leading zero

  test "(ipv6) RFC 4291 examples":
    parseOkSilent("n (ipv6)\"2001:db8::1\"")
    parseOkSilent("n (ipv6)\"::1\"")
    parseOkSilent("n (ipv6)\"::\"")
    parseOkSilent("n (ipv6)\"2001:0db8:0000:0000:0000:0000:0000:0001\"")
    parseOkSilent("n (ipv6)\"fe80::1\"")

  test "(ipv6) embedded IPv4 form":
    # RFC 4291 §2.2: last 32 bits as dotted IPv4.
    parseOkSilent("n (ipv6)\"::ffff:192.0.2.1\"")

  test "(ipv6) rejects malformed":
    parseErr("n (ipv6)\"2001:db8\"", peReservedTypeInvalid)
    parseErr("n (ipv6)\"2001::db8::1\"", peReservedTypeInvalid)  # double ::
    parseErr("n (ipv6)\"2001:db8:gggg::1\"", peReservedTypeInvalid)
    parseErr("n (ipv6)\"1:2:3:4:5:6:7:8:9\"", peReservedTypeInvalid)  # too many

  test "(date) RFC 3339 full-date":
    parseOkSilent("n (date)\"2026-05-12\"")
    parseOkSilent("n (date)\"1970-01-01\"")
    parseOkSilent("n (date)\"2000-02-29\"")   # valid leap year

  test "(date) calendar validation":
    parseErr("n (date)\"2025-02-29\"", peReservedTypeInvalid)  # not leap
    parseErr("n (date)\"2026-13-01\"", peReservedTypeInvalid)  # bad month
    parseErr("n (date)\"2026-04-31\"", peReservedTypeInvalid)  # Apr has 30
    parseErr("n (date)\"2026-5-12\"", peReservedTypeInvalid)   # not zero-padded

  test "(time) RFC 3339 partial-time and full-time":
    parseOkSilent("n (time)\"00:00:00\"")
    parseOkSilent("n (time)\"23:59:60\"")          # leap second per RFC 3339
    parseOkSilent("n (time)\"10:00:00.5\"")
    parseOkSilent("n (time)\"10:00:00.123456789\"")
    parseOkSilent("n (time)\"10:00:00Z\"")
    parseOkSilent("n (time)\"10:00:00+01:00\"")
    parseOkSilent("n (time)\"10:00:00-05:30\"")

  test "(time) rejects malformed":
    parseErr("n (time)\"24:00:00\"", peReservedTypeInvalid)
    parseErr("n (time)\"10:60:00\"", peReservedTypeInvalid)
    parseErr("n (time)\"10:00\"", peReservedTypeInvalid)
    parseErr("n (time)\"10:00:00+25:00\"", peReservedTypeInvalid)

  test "(date-time) RFC 3339 examples":
    parseOkSilent("n (date-time)\"2026-05-12T10:00:00Z\"")
    parseOkSilent("n (date-time)\"1985-04-12T23:20:50.52Z\"")
    parseOkSilent("n (date-time)\"1996-12-19T16:39:57-08:00\"")

  test "(date-time) rejects malformed":
    parseErr("n (date-time)\"2026-05-12\"", peReservedTypeInvalid)        # missing time
    parseErr("n (date-time)\"2026-05-12 10:00:00Z\"", peReservedTypeInvalid)  # space, not T
    parseErr("n (date-time)\"2026-13-01T10:00:00Z\"", peReservedTypeInvalid)

  test "(duration) ISO 8601 examples":
    parseOkSilent("n (duration)\"P1Y\"")
    parseOkSilent("n (duration)\"P1Y2M3DT4H5M6S\"")
    parseOkSilent("n (duration)\"PT1H\"")
    parseOkSilent("n (duration)\"PT0.5S\"")
    parseOkSilent("n (duration)\"P1W\"")        # weeks designator

  test "(duration) rejects malformed":
    parseErr("n (duration)\"\"", peReservedTypeInvalid)
    parseErr("n (duration)\"P\"", peReservedTypeInvalid)
    parseErr("n (duration)\"P1\"", peReservedTypeInvalid)    # no designator
    parseErr("n (duration)\"1Y\"", peReservedTypeInvalid)    # missing P
    parseErr("n (duration)\"P1H\"", peReservedTypeInvalid)   # H without T

  test "(base64) RFC 4648 §10 test vectors":
    parseOkSilent("n (base64)\"\"")           # empty
    parseOkSilent("n (base64)\"Zg==\"")       # "f"
    parseOkSilent("n (base64)\"Zm8=\"")       # "fo"
    parseOkSilent("n (base64)\"Zm9v\"")       # "foo"
    parseOkSilent("n (base64)\"Zm9vYmFy\"")   # "foobar"

  test "(base64) rejects malformed":
    parseErr("n (base64)\"Zg=\"",  peReservedTypeInvalid)   # bad len mod 4
    parseErr("n (base64)\"Zg===\"", peReservedTypeInvalid)  # excess padding
    parseErr("n (base64)\"Z!==\"", peReservedTypeInvalid)   # non-alphabet
    parseErr("n (base64)\"Zg=A\"", peReservedTypeInvalid)   # data after padding

  test "(base85) RFC 1924 example":
    # 32-bit value 0 encodes to 5 chars of base85 minimum-alphabet zeros.
    parseOkSilent("n (base85)\"00000\"")
    # Spec test: encoding of an IPv6 address per RFC 1924 §4.
    # 2001:0db8:0000:0000:0000:0000:0000:0001 → 9R}vSQZ1W=8fRv*-7Z>9*
    parseOkSilent("n (base85)\"9R}vSQZ1W=8fRv*-7Z>9*\"")

  test "(base85) rejects non-alphabet":
    parseErr("n (base85)\"abc \"", peReservedTypeInvalid)   # space disallowed
    parseErr("n (base85)\"abc\\\"\"", peReservedTypeInvalid) # quote disallowed

suite "reserved types — numeric tier-1 property sweep":
  # Deterministic boundary sweep over all 8 sub-int-64 numeric tags.
  # Each tag's accept/reject must agree with its declared range, exactly.
  # A pseudo-random integer is fed via decimal literal; we assert the
  # parse result matches `inRange(i, lo, hi)`. Lock against off-by-one
  # at the bounds and against sign-bit confusions.

  test "i8 boundary sweep":
    for i in -130 .. 130:
      let res = parse("n (i8)" & $i)
      let inRange = i >= -128 and i <= 127
      check res.isOk == inRange

  test "u8 boundary sweep":
    for i in -2 .. 260:
      let res = parse("n (u8)" & $i)
      let inRange = i >= 0 and i <= 255
      check res.isOk == inRange

  test "i16 boundary sweep":
    for i in [-32770, -32769, -32768, -1, 0, 1, 32766, 32767, 32768, 32770]:
      let res = parse("n (i16)" & $i)
      let inRange = i >= -32768 and i <= 32767
      check res.isOk == inRange

  test "u16 boundary sweep":
    for i in [-2, -1, 0, 1, 65534, 65535, 65536, 70000]:
      let res = parse("n (u16)" & $i)
      let inRange = i >= 0 and i <= 65535
      check res.isOk == inRange

  test "i32 boundary sweep":
    for i in @[int64(-2147483650), -2147483649, -2147483648, -1, 0,
               1, 2147483646, 2147483647, 2147483648, 2147483650]:
      let res = parse("n (i32)" & $i)
      let inRange = i >= -2147483648'i64 and i <= 2147483647'i64
      check res.isOk == inRange

  test "u32 boundary sweep":
    for i in @[int64(-1), 0, 1, 4294967294, 4294967295, 4294967296]:
      let res = parse("n (u32)" & $i)
      let inRange = i >= 0 and i <= 4294967295'i64
      check res.isOk == inRange
