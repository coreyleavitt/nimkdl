## test_node_api.nim — Cat-3 DOM convenience + mutation API (rfc §9.1, §9.2).
##
## Typed read conveniences (propInt/argStr/…) extract a scalar when the value's
## kind matches, else none. The mutation API builds/edits trees doc-free; every
## mutator sets `dirty`. setProp is an upsert (KDL last-wins); addProp is
## deliberately absent (the parser collapses dup keys, so it would only
## manufacture a footgun — rfc §9.2).

import std/[unittest, options]
import ../src/node

suite "node — typed read conveniences":
  test "propInt/propStr/propBool/propFloat":
    var n = newNode("n")
    n.entries.add newProperty("i", newKdlInt(7))
    n.entries.add newProperty("s", newKdlString("hi"))
    n.entries.add newProperty("b", newKdlBool(true))
    n.entries.add newProperty("f", newKdlFloat(2.5))
    check n.propInt("i") == some(7'i64)
    check n.propStr("s") == some("hi")
    check n.propBool("b") == some(true)
    check n.propFloat("f") == some(2.5)
    check n.propInt("s").isNone        # wrong kind → none
    check n.propInt("absent").isNone

  test "argInt/argStr/argBool/argFloat":
    var n = newNode("n")
    n.entries.add newArgument(newKdlInt(1))
    n.entries.add newArgument(newKdlString("x"))
    check n.argInt(0) == some(1'i64)
    check n.argStr(1) == some("x")
    check n.argInt(1).isNone           # wrong kind
    check n.argStr(9).isNone           # out of range

suite "node — mutation API (doc-free, sets dirty)":
  test "addArg / setName / setTypeAnnotation":
    var n = newNode("n")
    check not n.dirty
    n.addArg(newKdlInt(5))
    check n.dirty
    check n.arg(0) == some(newKdlInt(5))
    n.setName("renamed")
    check n.name == "renamed"
    n.setTypeAnnotation(some("ty"))
    check n.typeAnnotation == some("ty")

  test "setArg replaces by positional index (skips props), false out of range":
    var n = newNode("n")
    n.addArg(newKdlInt(1))
    n.setProp("k", newKdlBool(true))   # interleaved prop — skipped by index
    n.addArg(newKdlInt(2))
    check n.setArg(1, newKdlString("x"))
    check n.arg(0) == some(newKdlInt(1))
    check n.arg(1) == some(newKdlString("x"))
    check not n.setArg(5, newKdlNull())   # out of range → no-op

  test "setProp upserts (last-wins), removeProp":
    var n = newNode("n")
    n.setProp("k", newKdlInt(1))
    n.setProp("k", newKdlInt(2))       # upsert — replaces, doesn't duplicate
    check n.props.len == 1
    check n.prop("k") == some(newKdlInt(2))
    check n.removeProp("k")
    check n.prop("k").isNone
    check not n.removeProp("k")        # already gone

  test "typed prop setters":
    var n = newNode("n")
    n.setPropInt("i", 9)
    n.setPropStr("s", "v")
    n.setPropBool("b", false)
    n.setPropFloat("f", 1.25)
    check n.propInt("i") == some(9'i64)
    check n.propStr("s") == some("v")
    check n.propBool("b") == some(false)
    check n.propFloat("f") == some(1.25)

  test "addChild / removeChild / doc.add":
    var parent = newNode("parent")
    parent.addChild(newNode("a"))
    parent.addChild(newNode("a"))
    parent.addChild(newNode("b"))
    check parent.children.len == 3
    check parent.removeChild("a") == 2   # count removed
    check parent.children.len == 1
    let d = newDoc()
    d.add(newNode("root1"))
    d.add(newNode("root2"))
    check d.nodes.len == 2
