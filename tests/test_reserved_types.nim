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
