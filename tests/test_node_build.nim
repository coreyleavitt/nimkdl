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

import std/[unittest, options, monotimes, times]
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

suite "node_build — F2: property dedup is O(n), and last-wins keeps the LAST occurrence's position":
  ## Regression: `buildNodeDoc`'s `ceProp` handler used to rescan the ENTIRE
  ## current node's `entries` on every single property token to delete an
  ## earlier same-key entry — O(N) work per prop, O(N^2) total for a node
  ## with N (not necessarily even duplicate) props. A crafted node with tens
  ## of thousands of props parses in low-single-digit milliseconds under the
  ## O(n) fix; the old O(n^2) code took multiple seconds to tens of seconds
  ## at this N (empirically: 2k props=0.10s, 32k=17.8s, quadrupling per
  ## doubling).

  test "duplicate key interleaved with another prop: last occurrence's VALUE and POSITION survive":
    # `a=1 x=5 a=2`: the old incremental delete-then-append put the surviving
    # `a` entry at the END (where the second occurrence was appended), not
    # where the first `a=1` originally sat. The O(n) post-pass dedup must
    # reproduce the identical order, not just the identical value.
    let n = doc("n a=1 x=5 a=2\n").node("n")
    check n.props.len == 2
    check n.props[0].key == "x"
    check n.props[0].value == newKdlInt(5)
    check n.props[1].key == "a"
    check n.props[1].value == newKdlInt(2)

  test "three occurrences of the same key: only the last survives, value and position":
    let n = doc("n k=1 k=2 k=3\n").node("n")
    check n.props.len == 1
    check n.props[0].value == newKdlInt(3)

  proc manyPropsSrc(n: int): string =
    result = "n "
    for i in 0 ..< n:
      result.add "k" & $i & "=1 "

  test "20000 distinct props on one node parses in well under a second (not O(n^2))":
    let src = manyPropsSrc(20_000)
    let t0 = getMonoTime()
    let r = parseNodes(src)
    let t1 = getMonoTime()
    check r.isOk
    check r.get.node("n").props.len == 20_000
    let elapsedMs = (t1 - t0).inMilliseconds
    checkpoint("20000-prop parse took " & $elapsedMs & " ms")
    # O(n^2) would take single-to-tens-of-seconds at this N (see suite doc);
    # O(n)/O(n log n) is low-single-digit milliseconds. 1000ms is a bound
    # that's comfortably on the linear side without being flake-prone.
    check elapsedMs < 1000

  test "scaling from 4000 to 16000 props (4x N) is far from the 16x a quadratic algorithm would cost":
    proc elapsedMs(n: int): float =
      let src = manyPropsSrc(n)
      let t0 = getMonoTime()
      let r = parseNodes(src)
      let t1 = getMonoTime()
      check r.isOk
      (t1 - t0).inNanoseconds.float / 1_000_000.0
    let small = elapsedMs(4_000)
    let big = elapsedMs(16_000)
    checkpoint("4000 props: " & $small & " ms; 16000 props: " & $big & " ms")
    # Linear predicts ~4x; a lingering O(n^2) predicts ~16x. Give generous
    # headroom above linear (and a small additive floor to absorb noise on an
    # already-tiny `small`) while still rejecting quadratic growth outright.
    check big < small * 8.0 + 10.0
