## Tests for the KdlEmitter primitive — symmetric OUT-side inverse of
## KdlCursor. Built in cycles A1-A11; this file grows one assertion at
## a time as the substrate fills in.

import std/unittest

import ../src/emitter

suite "emitter — A1: tracer":

  test "newBufferEmitter then finish returns empty string for no events":
    var e = newBufferEmitter()
    check e.finish() == ""

suite "emitter — A2: bare node":

  test "pushNodeBegin foo + pushNodeEnd yields foo\\n":
    var e = newBufferEmitter()
    e.pushNodeBegin("foo")
    e.pushNodeEnd()
    check e.finish() == "foo\n"

suite "emitter — A3: typed-value pushArg":

  test "pushArgInt 42 emits foo 42\\n":
    var e = newBufferEmitter()
    e.pushNodeBegin("foo")
    e.pushArgInt(42)
    e.pushNodeEnd()
    check e.finish() == "foo 42\n"

  test "pushArgInt -7 emits the negative sign":
    var e = newBufferEmitter()
    e.pushNodeBegin("n")
    e.pushArgInt(-7)
    e.pushNodeEnd()
    check e.finish() == "n -7\n"

  test "multiple pushArgInt emit space-separated":
    var e = newBufferEmitter()
    e.pushNodeBegin("seq")
    e.pushArgInt(1)
    e.pushArgInt(2)
    e.pushArgInt(3)
    e.pushNodeEnd()
    check e.finish() == "seq 1 2 3\n"

suite "emitter — A4: pushProp":

  test "pushPropInt emits foo x=1\\n":
    var e = newBufferEmitter()
    e.pushNodeBegin("foo")
    e.pushPropInt("x", 1)
    e.pushNodeEnd()
    check e.finish() == "foo x=1\n"

  test "pushArg before pushProp orders entries":
    var e = newBufferEmitter()
    e.pushNodeBegin("foo")
    e.pushArgInt(42)
    e.pushPropInt("count", 3)
    e.pushNodeEnd()
    check e.finish() == "foo 42 count=3\n"

suite "emitter — A5: children block + indent":

  test "single nested child indents 4 spaces":
    var e = newBufferEmitter()
    e.pushNodeBegin("parent")
    e.pushChildrenBegin()
    e.pushNodeBegin("child")
    e.pushNodeEnd()
    e.pushChildrenEnd()
    e.pushNodeEnd()
    check e.finish() == "parent {\n    child\n}\n"

  test "depth-2 nesting indents 8 spaces at depth 2":
    var e = newBufferEmitter()
    e.pushNodeBegin("a")
    e.pushChildrenBegin()
    e.pushNodeBegin("b")
    e.pushChildrenBegin()
    e.pushNodeBegin("c")
    e.pushNodeEnd()
    e.pushChildrenEnd()
    e.pushNodeEnd()
    e.pushChildrenEnd()
    e.pushNodeEnd()
    check e.finish() == "a {\n    b {\n        c\n    }\n}\n"

  test "children with entries on parent":
    var e = newBufferEmitter()
    e.pushNodeBegin("svc")
    e.pushArgInt(42)
    e.pushChildrenBegin()
    e.pushNodeBegin("port")
    e.pushArgInt(80)
    e.pushNodeEnd()
    e.pushChildrenEnd()
    e.pushNodeEnd()
    check e.finish() == "svc 42 {\n    port 80\n}\n"

suite "emitter — A6: annotations":

  test "node annotation emits (tag) prefix":
    var e = newBufferEmitter()
    e.pushNodeBegin("addr", anno = "ipv4")
    e.pushNodeEnd()
    check e.finish() == "(ipv4)addr\n"

  test "arg annotation emits (tag) before value":
    var e = newBufferEmitter()
    e.pushNodeBegin("n")
    e.pushArgInt(42, anno = "u8")
    e.pushNodeEnd()
    check e.finish() == "n (u8)42\n"

  test "prop annotation emits (tag) before value":
    var e = newBufferEmitter()
    e.pushNodeBegin("p")
    e.pushPropInt("count", 3, anno = "u32")
    e.pushNodeEnd()
    check e.finish() == "p count=(u32)3\n"

  test "node + arg + prop annotations combine":
    var e = newBufferEmitter()
    e.pushNodeBegin("host", anno = "server")
    e.pushArgInt(42, anno = "u8")
    e.pushPropInt("port", 80, anno = "u16")
    e.pushNodeEnd()
    check e.finish() == "(server)host (u8)42 port=(u16)80\n"

suite "emitter — A7: slashdash brackets":

  test "slashdashed top-level node prefixes /-":
    var e = newBufferEmitter()
    e.pushSlashdashBegin()
    e.pushNodeBegin("dead")
    e.pushSlashdashEnd()
    e.pushNodeEnd()
    check e.finish() == "/-dead\n"

  test "slashdashed entry prefixes /- mid-node":
    var e = newBufferEmitter()
    e.pushNodeBegin("foo")
    e.pushSlashdashBegin()
    e.pushArgInt(42)
    e.pushSlashdashEnd()
    e.pushArgInt(99)
    e.pushNodeEnd()
    check e.finish() == "foo /-42 99\n"

  test "slashdashed prop prefixes /- before key":
    var e = newBufferEmitter()
    e.pushNodeBegin("foo")
    e.pushSlashdashBegin()
    e.pushPropInt("x", 1)
    e.pushSlashdashEnd()
    e.pushNodeEnd()
    check e.finish() == "foo /-x=1\n"

  test "slashdashed children block prefixes /- before brace":
    var e = newBufferEmitter()
    e.pushNodeBegin("foo")
    e.pushSlashdashBegin()
    e.pushChildrenBegin()
    e.pushNodeBegin("inner")
    e.pushNodeEnd()
    e.pushChildrenEnd()
    e.pushSlashdashEnd()
    e.pushNodeEnd()
    check e.finish() == "foo /-{\n    inner\n}\n"

  test "slashdashed nested child node":
    var e = newBufferEmitter()
    e.pushNodeBegin("p")
    e.pushChildrenBegin()
    e.pushSlashdashBegin()
    e.pushNodeBegin("c")
    e.pushSlashdashEnd()
    e.pushNodeEnd()
    e.pushChildrenEnd()
    e.pushNodeEnd()
    check e.finish() == "p {\n    /-c\n}\n"

suite "emitter — A8: typed value primitives (string/float/bool/null)":

  test "pushArgString emits quoted value":
    var e = newBufferEmitter()
    e.pushNodeBegin("greeting")
    e.pushArgString("hello")
    e.pushNodeEnd()
    check e.finish() == "greeting \"hello\"\n"

  test "pushArgString escapes backslash and double-quote":
    var e = newBufferEmitter()
    e.pushNodeBegin("msg")
    e.pushArgString("she said \"hi\\bye\"")
    e.pushNodeEnd()
    check e.finish() == "msg \"she said \\\"hi\\\\bye\\\"\"\n"

  test "pushArgString escapes newline and tab":
    var e = newBufferEmitter()
    e.pushNodeBegin("m")
    e.pushArgString("a\nb\tc")
    e.pushNodeEnd()
    check e.finish() == "m \"a\\nb\\tc\"\n"

  test "pushArgFloat emits decimal form for finite values":
    var e = newBufferEmitter()
    e.pushNodeBegin("ratio")
    e.pushArgFloat(1.5)
    e.pushNodeEnd()
    check e.finish() == "ratio 1.5\n"

  test "pushArgFloat emits #inf for positive infinity":
    var e = newBufferEmitter()
    e.pushNodeBegin("limit")
    e.pushArgFloat(Inf)
    e.pushNodeEnd()
    check e.finish() == "limit #inf\n"

  test "pushArgFloat emits #-inf for negative infinity":
    var e = newBufferEmitter()
    e.pushNodeBegin("limit")
    e.pushArgFloat(NegInf)
    e.pushNodeEnd()
    check e.finish() == "limit #-inf\n"

  test "pushArgFloat emits #nan for NaN":
    var e = newBufferEmitter()
    e.pushNodeBegin("bad")
    e.pushArgFloat(NaN)
    e.pushNodeEnd()
    check e.finish() == "bad #nan\n"

  test "pushArgBool emits #true / #false":
    var e = newBufferEmitter()
    e.pushNodeBegin("flags")
    e.pushArgBool(true)
    e.pushArgBool(false)
    e.pushNodeEnd()
    check e.finish() == "flags #true #false\n"

  test "pushArgNull emits #null":
    var e = newBufferEmitter()
    e.pushNodeBegin("absent")
    e.pushArgNull()
    e.pushNodeEnd()
    check e.finish() == "absent #null\n"

  test "props with typed primitives":
    var e = newBufferEmitter()
    e.pushNodeBegin("cfg")
    e.pushPropString("name", "alpha")
    e.pushPropBool("enabled", true)
    e.pushPropFloat("scale", 2.5)
    e.pushPropNull("fallback")
    e.pushNodeEnd()
    check e.finish() == "cfg name=\"alpha\" enabled=#true scale=2.5 fallback=#null\n"
