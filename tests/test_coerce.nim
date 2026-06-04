## Tests for `coerce[T](val: KdlValue)` — the value leg of the typed bridge
## (rfc-consumer-api §4.6, slice V1). source→T (`decode`), node→T (`decodeNode`),
## value→T (`coerce`). Named `coerce` (not a third `decode` overload) and guarded
## to SCALAR targets only: aggregates (object/tuple/seq/array WITHOUT a
## `kdlDecodeValue` hook) are a hard compile error directing the caller to
## `decodeNode`/`decode`.

import std/[options, unittest]

import ../src/api
import ../src/value
import ../src/spans

suite "coerce — built-in scalars":

  test "coerce[int] of an int value":
    let r = coerce[int](newKdlInt(42))
    check r.isOk
    check r.get == 42

  test "coerce[int64] of an int value":
    let r = coerce[int64](newKdlInt(-9))
    check r.isOk
    check r.get == -9'i64

  test "coerce[string] of a string value":
    let r = coerce[string](newKdlString("hello"))
    check r.isOk
    check r.get == "hello"

  test "coerce[bool] of a bool value":
    let r = coerce[bool](newKdlBool(true))
    check r.isOk
    check r.get == true

  test "coerce[float] of a float value":
    let r = coerce[float](newKdlFloat(2.5))
    check r.isOk
    check r.get == 2.5

  test "coerce[float] of an int value (int→float widening)":
    let r = coerce[float](newKdlInt(7))
    check r.isOk
    check r.get == 7.0

  test "coerce[uint8] of a non-negative int value":
    let r = coerce[uint8](newKdlInt(200))
    check r.isOk
    check r.get == 200'u8

suite "coerce — kvBigInt (review #5)":

  # A magnitude exceeding int64 — built via the real `newKdlBigInt` constructor
  # (the same shape the parser emits when a literal overflows int64). Value here
  # is 2^64 + 5 = 18446744073709551621 (bigHi=1, bigLo=5, positive).
  let hugePos = newKdlBigInt(bigHi = 1'u64, bigLo = 5'u64, bigNegative = false)
  # 2^64 (bigHi=1, bigLo=0) — fits in u128 reasoning but not any int64 target.
  let twoPow64 = newKdlBigInt(bigHi = 1'u64, bigLo = 0'u64, bigNegative = false)

  test "coerce[float] of a bigint widens (lossy but numeric)":
    let r = coerce[float](twoPow64)
    check r.isOk
    check r.get == 18446744073709551616.0  # 2^64

  test "coerce[float] of a negative bigint widens with sign":
    let r = coerce[float](newKdlBigInt(1'u64, 0'u64, true))
    check r.isOk
    check r.get == -18446744073709551616.0

  test "coerce[int64] of an out-of-int64 bigint → overflow (not kind mismatch)":
    let r = coerce[int64](hugePos)
    check r.isErr
    check r.getErr.code == peTypeIntegerOverflow

  test "coerce[int8] of a huge bigint → overflow (not kind mismatch)":
    let r = coerce[int8](hugePos)
    check r.isErr
    check r.getErr.code == peTypeIntegerOverflow

  test "coerce[uint64] of a bigint > uint64.max → overflow":
    # bigHi != 0 ⇒ magnitude >= 2^64 > uint64.high
    let r = coerce[uint64](hugePos)
    check r.isErr
    check r.getErr.code == peTypeIntegerOverflow

  test "coerce[uint64] of a negative bigint → kind/sign mismatch (not overflow)":
    let r = coerce[uint64](newKdlBigInt(0'u64, 1'u64, true))
    check r.isErr
    check r.getErr.code == peTypeMismatch

  test "coerce[int8] of an in-range int → succeeds":
    let r = coerce[int8](newKdlInt(100))
    check r.isOk
    check r.get == 100'i8

  test "coerce[int8] of an out-of-range int → overflow (no RangeDefect)":
    let r = coerce[int8](newKdlInt(200))
    check r.isErr
    check r.getErr.code == peTypeIntegerOverflow

  test "coerce[uint8] of an out-of-range int → overflow":
    let r = coerce[uint8](newKdlInt(300))
    check r.isErr
    check r.getErr.code == peTypeIntegerOverflow

suite "coerce — enum scalar (allowed, not blocked by the guard)":

  type Mode = enum
    mRead = "read"
    mWrite = "write"

  test "coerce[Mode] of the matching string value":
    let r = coerce[Mode](newKdlString("write"))
    check r.isOk
    check r.get == mWrite

  test "coerce[Mode] of an unknown string → enum-invalid error":
    let r = coerce[Mode](newKdlString("delete"))
    check r.isErr
    check r.getErr.code == peTypeEnumInvalid

# A custom scalar type + its `kdlDecodeValue` hook live at MODULE level — the
# documented placement ("in scope before the type's `kdl:` block"). `coerce`'s
# generic `mixin`/`compiles` resolution binds module-level hooks; a hook nested
# inside a `suite`/`block` is NOT reliably visible to a pre-defined generic.
type Color = object
  r, g, b: uint8

proc kdlDecodeValue(val: KdlValue, T: typedesc[Color]): Result[Color, string] =
  if val.kind != kvString or val.strVal.len != 7 or val.strVal[0] != '#':
    return err[Color, string]("expected #rrggbb string")
  proc hx(s: string): uint8 =
    for c in s:
      result = result shl 4
      case c
      of '0'..'9': result = result or uint8(ord(c) - ord('0'))
      of 'a'..'f': result = result or uint8(ord(c) - ord('a') + 10)
      of 'A'..'F': result = result or uint8(ord(c) - ord('A') + 10)
      else: discard
  ok[Color, string](Color(r: hx(val.strVal[1..2]),
                          g: hx(val.strVal[3..4]),
                          b: hx(val.strVal[5..6])))

suite "coerce — custom kdlScalar type (allowed via hook, not blocked)":

  test "coerce[Color] routes through the kdlDecodeValue hook":
    let r = coerce[Color](newKdlString("#ff8000"))
    check r.isOk
    check r.get == Color(r: 255, g: 128, b: 0)

  test "hook error string surfaces as a typed ParseError":
    let r = coerce[Color](newKdlString("nope"))
    check r.isErr
    check r.getErr.code == peTypeMismatch

suite "coerce — kind mismatch is a clear typed error":

  test "coerce[int] of a string value → peTypeMismatch":
    let r = coerce[int](newKdlString("123"))
    check r.isErr
    check r.getErr.code == peTypeMismatch

  test "coerce[string] of an int value → peTypeMismatch":
    let r = coerce[string](newKdlInt(5))
    check r.isErr
    check r.getErr.code == peTypeMismatch

  test "coerce[bool] of a null value → peTypeMismatch":
    let r = coerce[bool](newKdlNull())
    check r.isErr
    check r.getErr.code == peTypeMismatch
