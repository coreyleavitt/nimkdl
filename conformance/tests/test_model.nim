## conformance/tests/test_model.nim — clean-room model tests (no nkdl).
##
## M1: the number model is an EXACT decimal, not an int64/float pair. The spec
## (§Number) says KDL draws no logical int/float distinction and leaves
## representation to implementations — so a double-backed oracle is wrong, not
## merely biased: `1.23E+1000` is beyond IEEE-754 range and the kdl-org
## canonical corpus keeps it verbatim. These cases are transcribed directly
## from `tests/conformance/test_cases/expected_kdl/` (input => canonical).

import std/unittest
import ../model

suite "M1 — exact-decimal number model + canonical-KDL projection":

  test "integer canonicalizes to a bare decimal string":
    # arg_zero_type: 0 => 0 ; arg_hex_type: 0x10 => 16 (radix is a SURFACE
    # concern; the model holds decimal, so the model value for 0x10 is 16)
    check canonicalKdl(num(false, "16")) == "16"
    check canonicalKdl(num(false, "0")) == "0"
    check canonicalKdl(num(true, "10")) == "-10"

  test "real with fraction keeps the fraction verbatim (no trailing-zero strip)":
    # zero_float: 0.0 => 0.0 ; negative_float: -1.0 => -1.0 ; 2.5 => 2.5
    check canonicalKdl(num(false, "0", fracDigits = "0")) == "0.0"
    check canonicalKdl(num(true, "1", fracDigits = "0")) == "-1.0"
    check canonicalKdl(num(false, "2", fracDigits = "5")) == "2.5"

  test "exponent: e=>E and the exponent sign is always explicit":
    # no_decimal_exponent: 1e10 => 1E+10 (no dot when no fraction)
    check canonicalKdl(num(false, "1", hasExp = true, expDigits = "10")) == "1E+10"
    # positive_exponent: 1.0e+10 => 1.0E+10
    check canonicalKdl(num(false, "1", fracDigits = "0",
                           hasExp = true, expDigits = "10")) == "1.0E+10"
    # negative_exponent: 1.0e-10 => 1.0E-10
    check canonicalKdl(num(false, "1", fracDigits = "0",
                           hasExp = true, expNegative = true, expDigits = "10")) == "1.0E-10"
    # prop_float_type: 2.5E10 => 2.5E+10
    check canonicalKdl(num(false, "2", fracDigits = "5",
                           hasExp = true, expDigits = "10")) == "2.5E+10"

  test "magnitude beyond IEEE-754 double survives exactly (the float-as-double bug)":
    # sci_notation_large: 1.23E+1000 => 1.23E+1000  (a double would be +inf)
    check canonicalKdl(num(false, "1", fracDigits = "23",
                           hasExp = true, expDigits = "1000")) == "1.23E+1000"
    # sci_notation_small: 1.23E-1000 => 1.23E-1000
    check canonicalKdl(num(false, "1", fracDigits = "23",
                           hasExp = true, expNegative = true, expDigits = "1000")) == "1.23E-1000"

suite "M-value — representation-independent value equality (valueNormal)":

  test "equivalent real spellings collapse to one canonical value":
    # 1E+10 == 10000000000.0 ; 12E-56 == 1.2E-55 ; a double-based impl that
    # normalizes mantissa/exponent must still compare equal to our exact oracle.
    check num(false, "1", hasExp = true, expDigits = "10").num.valueNormal == "1E+10"
    check num(false, "10000000000", fracDigits = "0").num.valueNormal == "1E+10"
    check num(false, "12", hasExp = true, expNegative = true, expDigits = "56").num.valueNormal == "1.2E-55"
    check num(false, "1", fracDigits = "2",
              hasExp = true, expNegative = true, expDigits = "55").num.valueNormal == "1.2E-55"

  test "trailing zeros in the fraction are not significant to the value":
    check num(false, "1", fracDigits = "50").num.valueNormal == "1.5E+0"
    check num(false, "1", fracDigits = "5").num.valueNormal == "1.5E+0"

  test "exact zero, integers, and specials":
    check num(false, "0", fracDigits = "0").num.valueNormal == "0"
    check kInt(42).num.valueNormal == "42"          # integers stay plain decimal
    check kInt(-10).num.valueNormal == "-10"
    check kInf().num.valueNormal == "inf"
    check kNan().num.valueNormal == "nan"

  test "magnitude beyond IEEE-754 double still normalizes exactly":
    check num(false, "123", hasExp = true, expDigits = "998").num.valueNormal == "1.23E+1000"
