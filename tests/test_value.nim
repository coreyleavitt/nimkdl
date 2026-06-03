## test_value.nim — the self-contained value leaf (rfc-core-rebuild §5.2 / §6).
##
## KdlValue/KdlEntry own all their bytes (strVal, propKey, typeAnnotation).
## No interner, no doc, no back-reference. The headline property tested here is
## self-containedness: two values built independently — with no shared interner
## and no document — compare structurally equal. This is the behavior that is
## *impossible* under the interned-handle model (handles are interner-relative).

import std/[unittest, options]
import ../src/value

suite "value leaf — self-contained KdlValue":
  test "newKdlString owns its bytes with no doc":
    let v = newKdlString("hello")
    check v.kind == kvString
    check v.strVal == "hello"
    check v.typeAnnotation.isNone

  test "type annotation is none by default, some when set":
    var v = newKdlInt(42)
    check v.typeAnnotation.isNone
    v.typeAnnotation = some("u8")
    check v.typeAnnotation == some("u8")
    # empty-string annotation is distinct from absent (KDL `(\"\")value`)
    v.typeAnnotation = some("")
    check v.typeAnnotation.isSome
    check v.typeAnnotation.get == ""

  test "structural == across independently-built values (self-containedness)":
    # No shared interner, no doc — equality is pure byte structure.
    check newKdlString("x") == newKdlString("x")
    check newKdlInt(7) == newKdlInt(7)
    check newKdlBool(true) == newKdlBool(true)
    check newKdlNull() == newKdlNull()

  test "different kind or content compares unequal":
    check newKdlString("x") != newKdlString("y")
    check newKdlInt(1) != newKdlInt(2)
    check newKdlString("1") != newKdlInt(1)
    check newKdlBool(true) != newKdlBool(false)

  test "type annotation participates in equality":
    var a = newKdlString("x")
    var b = newKdlString("x")
    check a == b
    a.typeAnnotation = some("date")
    check a != b
    b.typeAnnotation = some("date")
    check a == b

  test "bigint carries 128-bit magnitude + sign":
    let v = newKdlBigInt(bigHi = 1'u64, bigLo = 0'u64, bigNegative = true)
    check v.kind == kvBigInt
    check v.bigHi == 1'u64
    check v.bigLo == 0'u64
    check v.bigNegative

  test "float and null":
    check newKdlFloat(1.5).floatVal == 1.5
    check newKdlNull().kind == kvNull

  test "== is reflexive for NaN (data-model identity, not IEEE)":
    let nan = newKdlFloat(NaN)
    check nan == nan
    check newKdlFloat(NaN) == newKdlFloat(NaN)
    check newKdlFloat(Inf) == newKdlFloat(Inf)
    check newKdlFloat(NaN) != newKdlFloat(1.0)

suite "value leaf — self-contained KdlEntry":
  test "argument entry wraps a value":
    let e = newArgument(newKdlString("id"))
    check e.kind == keArgument
    check e.argValue == newKdlString("id")

  test "property entry owns its key as a plain string":
    let e = newProperty("enabled", newKdlBool(true))
    check e.kind == keProperty
    check e.propKey == "enabled"
    check e.propValue == newKdlBool(true)

  test "entries compare structurally with no doc":
    check newArgument(newKdlInt(1)) == newArgument(newKdlInt(1))
    check newProperty("k", newKdlInt(1)) == newProperty("k", newKdlInt(1))
    check newProperty("k", newKdlInt(1)) != newProperty("j", newKdlInt(1))
    check newArgument(newKdlInt(1)) != newProperty("k", newKdlInt(1))
