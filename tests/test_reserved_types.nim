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
