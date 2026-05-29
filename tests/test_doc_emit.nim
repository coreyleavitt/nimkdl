## Tests for docEmit — Cat 3 OUT consumer that walks a KdlDoc and
## pushes events into a KdlEmitter. Cycles B1-B6 of the clean-core
## rebuild grow this surface one behavior at a time.

import std/unittest

import ../src/ast
import ../src/doc_emit
import ../src/emitter
import ../src/intern
import ../src/parser
import ../src/spans

suite "doc_emit — B1: tracer (bare top-level node)":

  test "single bare node emits foo\\n":
    var doc = newDoc()
    let n = doc.newNode("foo")
    doc.add(n)
    var e = newBufferEmitter()
    emitDoc(doc, e)
    check e.finish() == "foo\n"

  test "multiple top-level nodes emit in order":
    var doc = newDoc()
    var a = doc.newNode("a")
    var b = doc.newNode("b")
    doc.add(a)
    doc.add(b)
    var e = newBufferEmitter()
    emitDoc(doc, e)
    check e.finish() == "a\nb\n"

suite "doc_emit — B2: entries (args + props)":

  test "node with int argument":
    var doc = newDoc()
    var n = doc.newNode("count")
    n.entries.add(newArgument(newIntValue(42)))
    doc.add(n)
    var e = newBufferEmitter()
    emitDoc(doc, e)
    check e.finish() == "count 42\n"

  test "node with string argument":
    var doc = newDoc()
    var n = doc.newNode("greet")
    n.entries.add(newArgument(newStringValue("hi")))
    doc.add(n)
    var e = newBufferEmitter()
    emitDoc(doc, e)
    check e.finish() == "greet \"hi\"\n"

  test "node with bool + float + null arguments":
    var doc = newDoc()
    var n = doc.newNode("mix")
    n.entries.add(newArgument(newBoolValue(true)))
    n.entries.add(newArgument(newFloatValue(1.5)))
    n.entries.add(newArgument(newNullValue()))
    doc.add(n)
    var e = newBufferEmitter()
    emitDoc(doc, e)
    check e.finish() == "mix #true 1.5 #null\n"

  test "node with property":
    var doc = newDoc()
    var n = doc.newNode("svc")
    n.entries.add(newProperty(doc, "port", newIntValue(80)))
    doc.add(n)
    var e = newBufferEmitter()
    emitDoc(doc, e)
    check e.finish() == "svc port=80\n"

  test "node with arg then prop preserves source order":
    var doc = newDoc()
    var n = doc.newNode("svc")
    n.entries.add(newArgument(newStringValue("alpha")))
    n.entries.add(newProperty(doc, "count", newIntValue(3)))
    doc.add(n)
    var e = newBufferEmitter()
    emitDoc(doc, e)
    check e.finish() == "svc \"alpha\" count=3\n"

suite "doc_emit — B3: children":

  test "node with one child":
    var doc = newDoc()
    var parent = doc.newNode("parent")
    let child = doc.newNode("child")
    parent.children.add(child)
    doc.add(parent)
    var e = newBufferEmitter()
    emitDoc(doc, e)
    check e.finish() == "parent {\n    child\n}\n"

  test "depth-3 nesting":
    var doc = newDoc()
    var a = doc.newNode("a")
    var b = doc.newNode("b")
    var c = doc.newNode("c")
    let d = doc.newNode("d")
    c.children.add(d)
    b.children.add(c)
    a.children.add(b)
    doc.add(a)
    var e = newBufferEmitter()
    emitDoc(doc, e)
    check e.finish() == "a {\n    b {\n        c {\n            d\n        }\n    }\n}\n"

  test "parent with entries plus children":
    var doc = newDoc()
    var p = doc.newNode("svc")
    p.entries.add(newArgument(newIntValue(42)))
    let port = doc.newNode("port")
    var portN = port
    portN.entries.add(newArgument(newIntValue(80)))
    p.children.add(portN)
    doc.add(p)
    var e = newBufferEmitter()
    emitDoc(doc, e)
    check e.finish() == "svc 42 {\n    port 80\n}\n"

  test "siblings inside a children block":
    var doc = newDoc()
    var p = doc.newNode("p")
    p.children.add(doc.newNode("a"))
    p.children.add(doc.newNode("b"))
    doc.add(p)
    var e = newBufferEmitter()
    emitDoc(doc, e)
    check e.finish() == "p {\n    a\n    b\n}\n"

suite "doc_emit — B4: type annotations":

  test "node-level type annotation emits (tag)name":
    var doc = newDoc()
    var n = doc.newNode("host")
    n.typeAnnotation = doc.interner.intern("server")
    doc.add(n)
    var e = newBufferEmitter()
    emitDoc(doc, e)
    check e.finish() == "(server)host\n"

  test "arg-level type annotation propagates via dispatcher":
    var doc = newDoc()
    var n = doc.newNode("addr")
    var v = newStringValue("1.2.3.4")
    v.typeAnnotation = doc.interner.intern("ipv4")
    n.entries.add(newArgument(v))
    doc.add(n)
    var e = newBufferEmitter()
    emitDoc(doc, e)
    check e.finish() == "addr (ipv4)\"1.2.3.4\"\n"

  test "prop value type annotation":
    var doc = newDoc()
    var n = doc.newNode("c")
    var v = newIntValue(80)
    v.typeAnnotation = doc.interner.intern("u16")
    n.entries.add(newProperty(doc, "port", v))
    doc.add(n)
    var e = newBufferEmitter()
    emitDoc(doc, e)
    check e.finish() == "c port=(u16)80\n"

  test "node + arg + prop annotations all together":
    var doc = newDoc()
    var n = doc.newNode("svc")
    n.typeAnnotation = doc.interner.intern("server")
    var arg = newIntValue(42)
    arg.typeAnnotation = doc.interner.intern("u8")
    n.entries.add(newArgument(arg))
    var pv = newIntValue(80)
    pv.typeAnnotation = doc.interner.intern("u16")
    n.entries.add(newProperty(doc, "port", pv))
    doc.add(n)
    var e = newBufferEmitter()
    emitDoc(doc, e)
    check e.finish() == "(server)svc (u8)42 port=(u16)80\n"

suite "doc_emit — B5: preserve mode (clean subtree → source bytes)":

  test "unmutated parsed doc round-trips byte-exact for a bare node":
    let src = "foo\n"
    let r = parse(src, preserveFormat = true)
    check r.isOk
    var doc = r.get
    var e = newBufferEmitter()
    emitDocPreserve(doc, e)
    check e.finish() == src

  test "unmutated parsed doc preserves original number base":
    # The AST stores intVal=42 regardless of source; canonical mode
    # would re-emit "42", but preserve mode must keep "0x2a".
    let src = "n 0x2a\n"
    let r = parse(src, preserveFormat = true)
    check r.isOk
    var doc = r.get
    var e = newBufferEmitter()
    emitDocPreserve(doc, e)
    check e.finish() == src

  test "unmutated parsed doc preserves source whitespace":
    let src = "svc   port=80    enabled=#true\n"
    let r = parse(src, preserveFormat = true)
    check r.isOk
    var doc = r.get
    var e = newBufferEmitter()
    emitDocPreserve(doc, e)
    check e.finish() == src

  test "unmutated parsed doc preserves trailing comment":
    let src = "host \"hi\"  // greeting goes here\n"
    let r = parse(src, preserveFormat = true)
    check r.isOk
    var doc = r.get
    var e = newBufferEmitter()
    emitDocPreserve(doc, e)
    check e.finish() == src
