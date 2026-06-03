## test_node_build.nim — the self-contained node-producing builder (rfc §SB).
##
## `parseNodes` drives lex → cursor → buildNodeDoc, folding cursor events into a
## *self-contained* node.KdlDoc (owned strings, no interner). Verified through the
## doc-free Cat-3 accessors. This is the strangler replacement for the interned
## `doc_build.buildDoc`; once `parse()` swaps onto it the old core retires.
##
## Scope of this slice: structural core — nodes, args, props (last-wins),
## children, node + value type annotations, slashdash. Preserve-mode sidecar and
## reserved-tag validation rejoin in later slices.

import std/[unittest, options]
import ../src/node_build   # re-exports node + value

proc doc(src: string): KdlDoc =
  let r = parseNodes(src)
  check r.isOk
  r.get

suite "node_build — structural parse into self-contained nodes":
  test "a bare node":
    let d = doc("foo\n")
    check d.nodes.len == 1
    let n = d.node("foo")
    check not n.isNil
    check n.args.len == 0
    check n.props.len == 0
    check n.children.len == 0

  test "positional arguments, typed":
    let n = doc("n 1 \"two\" #true #null\n").node("n")
    check n.arg(0) == some(newKdlInt(1))
    check n.arg(1) == some(newKdlString("two"))
    check n.arg(2) == some(newKdlBool(true))
    check n.arg(3) == some(newKdlNull())

  test "properties":
    let n = doc("n a=1 b=\"x\"\n").node("n")
    check n.prop("a") == some(newKdlInt(1))
    check n.prop("b") == some(newKdlString("x"))

  test "repeated prop keys are last-wins":
    let n = doc("n k=1 k=2\n").node("n")
    check n.prop("k") == some(newKdlInt(2))

  test "children nest, doc-free":
    let parent = doc("parent {\n  child 7\n}\n").node("parent")
    check not parent.isNil
    let child = parent.child("child")
    check not child.isNil
    check child.arg(0) == some(newKdlInt(7))

  test "node type annotation is owned (no interner)":
    let n = doc("(author)person name=\"ada\"\n").node("person")
    check not n.isNil
    check n.typeAnnotation == some("author")

  test "value type annotation":
    let n = doc("n (u8)255\n").node("n")
    check n.arg(0).get.typeAnnotation == some("u8")

  test "slashdash discards a node":
    let d = doc("/-gone\nalive\n")
    check d.nodes.len == 1
    check not d.node("alive").isNil
    check d.node("gone").isNil

  test "multiple top-level nodes in source order":
    let d = doc("a\nb\nc\n")
    check d.nodes.len == 3
    check d.nodes[0].name == "a"
    check d.nodes[2].name == "c"

  test "self-containedness: parsed node survives with no doc reference":
    let n = doc("server port=8080\n").node("server")
    # `d` is gone; `n` is a ref into a tree that owns all its own bytes.
    check n.name == "server"
    check n.prop("port") == some(newKdlInt(8080))
