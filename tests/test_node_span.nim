## test_node_span.nim — per-node source span recording (rfc-consumer-api S1).
##
## Every parsed `KdlNode` records `span = [offset, length)` into the owning
## doc's `sourceText`, so `sourceText[span.offset ..< span.offset+span.length]`
## is the exact source text of that node. Hand-built nodes have `length == 0`.
##
## End-boundary semantics (verified against the real cursor, not the RFC's
## illustrative code): `ceNodeEnd` emits a ZERO-LENGTH point span at the
## position just BEFORE the node terminator (newline/semicolon/`}`/EOF), so
## the exclusive end offset is `ev.span.offset` itself. The span therefore
## covers the node head + entries + its children `{...}` block, but EXCLUDES
## the trailing terminator.

import std/[unittest, options]
import ../src/node_build   # re-exports node + value + spans

proc doc(src: string): KdlDoc =
  let r = parseNodes(src)
  check r.isOk
  r.get

proc spanText(d: KdlDoc, n: KdlNode): string =
  d.sourceText[n.span.offset ..< n.span.offset + n.span.length]

suite "node span — exact source byte range per node":
  test "a plain node's span is its exact source text":
    let d = doc("foo 1 2\n")
    let n = d.node("foo")
    check n.span.offset == 0
    check n.span.length == len("foo 1 2")
    check spanText(d, n) == "foo 1 2"

  test "span starts at the node's first byte even with leading whitespace":
    let src = "\n  foo 1\nbar 2\n"
    let d = doc(src)
    let foo = d.node("foo")
    check spanText(d, foo) == "foo 1"
    let bar = d.node("bar")
    check spanText(d, bar) == "bar 2"

  test "span re-parses to a structurally-equal node":
    let d = doc("alpha a=1 b=\"x\" 7\nbeta\n")
    let n = d.node("alpha")
    let slice = spanText(d, n)
    let reparsed = parseNodes(slice)
    check reparsed.isOk
    check reparsed.get.nodes.len == 1
    check reparsed.get.nodes[0] == n

  test "span covers the whole node including its children block":
    let src = "parent x=1 {\n  child 7\n  other\n}\n"
    let d = doc(src)
    let p = d.node("parent")
    let txt = spanText(d, p)
    # full node text from 'parent' through the closing brace, terminator excluded
    check txt == "parent x=1 {\n  child 7\n  other\n}"
    # and it re-parses equal
    let re = parseNodes(txt)
    check re.isOk
    check re.get.nodes.len == 1
    check re.get.nodes[0] == p

  test "child node span is exact within the parent's source":
    let src = "parent {\n  child 7\n}\n"
    let d = doc(src)
    let child = d.node("parent").child("child")
    check spanText(d, child) == "child 7"

  test "annotated node span.offset points at the '(' paren, not the tag":
    let src = "(author)person name=\"ada\"\n"
    let d = doc(src)
    let n = d.node("person")
    check src[n.span.offset] == '('
    check n.span.offset == 0
    check spanText(d, n) == "(author)person name=\"ada\""
    let re = parseNodes(spanText(d, n))
    check re.isOk
    check re.get.nodes[0] == n

  test "annotated node with leading whitespace still starts at '('":
    let src = "  (t)node 1\n"
    let d = doc(src)
    let n = d.node("node")
    check src[n.span.offset] == '('
    check spanText(d, n) == "(t)node 1"

  test "semicolon-terminated node excludes the semicolon":
    let d = doc("foo 1; bar 2\n")
    check spanText(d, d.node("foo")) == "foo 1"
    check spanText(d, d.node("bar")) == "bar 2"

  test "last node at EOF with no trailing newline":
    let d = doc("foo 1 2 3")
    check spanText(d, d.node("foo")) == "foo 1 2 3"

  test "hand-built node has span.length == 0 (the no-source sentinel)":
    let n = newNode("hand")
    check n.span.length == 0
    n.addArg(newKdlInt(5))
    check n.span.length == 0    # mutation does not fabricate a span
