## test_node.nim — self-contained KdlNode / KdlDoc (rfc-core-rebuild §5.2, §9).
##
## The node owns its `name`, prop keys, and type annotation as plain strings.
## `newNode` takes NO document — a detached node is fully usable (the headline
## mutation ergonomic). Accessors are doc-free. `prop` is LAST-wins per
## KDL 2.0 §Properties (rfc §9.3), not first-wins as the interned base did.

import std/[unittest, options]
import ../src/node   # re-exports value

suite "node leaf — self-contained KdlNode":
  test "newNode takes no doc and owns its name":
    let n = newNode("service")
    check n.name == "service"
    check n.typeAnnotation.isNone
    check n.entries.len == 0
    check n.childNodes.len == 0

  test "self-containedness: build a node, hold no doc, still read everything":
    var n = newNode("server")
    n.entries.add newProperty("port", newKdlInt(8080))
    n.entries.add newArgument(newKdlString("primary"))
    # No KdlDoc exists anywhere in this test. Reads need none.
    check n.name == "server"
    check n.prop("port") == some(newKdlInt(8080))
    check n.arg(0) == some(newKdlString("primary"))

  test "args / arguments skip interleaved properties":
    var n = newNode("n")
    n.entries.add newArgument(newKdlInt(1))
    n.entries.add newProperty("k", newKdlBool(true))
    n.entries.add newArgument(newKdlInt(2))
    check n.arg(0) == some(newKdlInt(1))
    check n.arg(1) == some(newKdlInt(2))
    check n.arg(2).isNone
    check n.args == @[newKdlInt(1), newKdlInt(2)]
    var collected: seq[KdlValue]
    for a in n.arguments: collected.add a
    check collected == @[newKdlInt(1), newKdlInt(2)]

  test "prop is LAST-wins (KDL 2.0 §Properties)":
    var n = newNode("n")
    n.entries.add newProperty("k", newKdlInt(1))
    n.entries.add newProperty("k", newKdlInt(2))   # rightmost wins
    check n.prop("k") == some(newKdlInt(2))
    check n.prop("absent").isNone

  test "props / properties enumerate key/value pairs":
    var n = newNode("n")
    n.entries.add newProperty("a", newKdlInt(1))
    n.entries.add newProperty("b", newKdlInt(2))
    check n.props == @[("a", newKdlInt(1)), ("b", newKdlInt(2))]

  test "child / children — nil for absent, by-value seq":
    var parent = newNode("parent")
    let c1 = newNode("leaf"); let c2 = newNode("leaf"); let c3 = newNode("other")
    parent.childNodes.add c1; parent.childNodes.add c2; parent.childNodes.add c3
    check parent.child("leaf") == c1            # first match (ref identity)
    check parent.child("missing").isNil
    check parent.children.len == 3
    check parent.children("leaf").len == 2

suite "node leaf — self-contained KdlDoc":
  test "newDoc + node / nodes accessors":
    let d = newDoc()
    let a = newNode("svc"); let b = newNode("svc"); let c = newNode("net")
    d.rootNodes.add a; d.rootNodes.add b; d.rootNodes.add c
    check d.node("svc") == a
    check d.node("nope").isNil
    check d.nodes.len == 3
    check d.nodes("svc").len == 2

suite "node leaf — structural equality (doc-free, recursive)":
  test "independently-built trees compare equal":
    proc tree(): KdlNode =
      result = newNode("root")
      result.entries.add newProperty("k", newKdlInt(1))
      let child = newNode("child")
      child.entries.add newArgument(newKdlString("x"))
      result.childNodes.add child
    check tree() == tree()

  test "difference in name / prop / child structure is detected":
    var a = newNode("a"); var b = newNode("b")
    check a != b
    b = newNode("a")
    check a == b
    a.entries.add newProperty("k", newKdlInt(1))
    check a != b
    b.entries.add newProperty("k", newKdlInt(1))
    check a == b
    a.childNodes.add newNode("c")
    check a != b
