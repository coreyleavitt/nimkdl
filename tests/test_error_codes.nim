## test_error_codes.nim — pin the ParseErrorCode wire/conformance contract.
##
## The integer values of ParseErrorCode are a STABLE cross-impl contract
## (rfc-core-rebuild §10): new codes append with the next free value; existing
## codes never renumber. This test fails loudly if anyone reorders or inserts a
## code mid-list — which is exactly when the contract would silently break.

import std/unittest
import ../src/spans

suite "ParseErrorCode — stable integer contract (rfc §10)":
  test "each code maps to its pinned value":
    check ord(peLexUnexpectedChar)     == 0
    check ord(peLexUnterminatedString) == 1
    check ord(peLexInvalidEscape)      == 2
    check ord(peLexInvalidNumber)      == 3
    check ord(peLexInvalidIdentifier)  == 4
    check ord(peLexReservedKeyword)    == 5
    check ord(peReservedTypeInvalid)   == 6
    check ord(peTypeReservedMismatch)  == 7
    check ord(peParseUnexpected)       == 8
    check ord(peParseExpected)         == 9
    check ord(peParseDepthExceeded)    == 10
    check ord(peTypeUnknownField)      == 11
    check ord(peTypeMismatch)          == 12
    check ord(peTypeMissingRequired)   == 13
    check ord(peTypeEnumInvalid)       == 14
    check ord(peTypeDiscriminatorBad)  == 15
    check ord(peEncodeUnsupported)     == 16
    check ord(peOther)                 == 17
    check ord(peTypeNoVariantMatch)    == 18
    check ord(peIOError)               == 19
    check ord(peTypeIntegerOverflow)   == 20

  test "contract bounds (append-only: new codes start at 21)":
    check ParseErrorCode.low.ord == 0
    check ParseErrorCode.high.ord == 20

  test "every code renders a non-empty message":
    for c in ParseErrorCode:
      check codeMessage(c).len > 0
