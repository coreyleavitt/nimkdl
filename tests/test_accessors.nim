## Tests for string-keyed convenience accessors on KdlDoc / KdlNode.
##
## These layer on top of the existing InternedStr-keyed primitives in
## codegen.nim (findProp / findChild / etc.) so consumers don't have
## to thread the interner by hand for ad-hoc inspection.

import std/unittest

import ../src/ast
import ../src/parser
import ../src/spans

template parseOk(src: string, body: untyped) =
  let res = parse(src)
  check res.isOk
  if res.isOk:
    let doc {.inject.} = res.get
    body

suite "string-keyed accessors":
  test "doc.node(name) returns Some(first top-level) by name":
    parseOk("a x=1\nb y=2\na z=3"):
      let n = doc.node("a")
      check n.isSome
      check doc.resolveName(n.get) == "a"

  test "doc.node(name) returns None when missing":
    parseOk("a x=1"):
      check doc.node("missing").isNone

  test "doc.nodes(name) returns all top-level matches in source order":
    parseOk("rule \"first\"\nother\nrule \"second\""):
      let rules = doc.nodes("rule")
      check rules.len == 2

  test "node.prop(doc, name) returns Some(value) for present property":
    parseOk("n enabled=#true count=42"):
      let n = doc.nodes[0]
      check n.prop(doc, "enabled").get.kind == kvBool
      check n.prop(doc, "enabled").get.boolVal == true
      check n.prop(doc, "count").get.intVal == 42

  test "node.prop(doc, missing) returns None":
    parseOk("n enabled=#true"):
      let n = doc.nodes[0]
      check n.prop(doc, "absent").isNone

  test "node.prop distinguishes missing from present-and-null":
    # The whole point of Option over a kvNull sentinel: callers can
    # tell `key=#null` apart from "no key at all".
    parseOk("n explicit=#null"):
      let n = doc.nodes[0]
      check n.prop(doc, "explicit").isSome
      check n.prop(doc, "explicit").get.kind == kvNull
      check n.prop(doc, "missing").isNone

  test "node.hasProp(doc, name) reports presence":
    parseOk("n a=1"):
      let n = doc.nodes[0]
      check n.hasProp(doc, "a")
      check not n.hasProp(doc, "b")

  test "node.child(doc, name) returns Some(first child) by name":
    parseOk("parent { a \"first\"; b; a \"second\" }"):
      let p = doc.nodes[0]
      let a = p.child(doc, "a")
      check a.isSome
      check doc.resolveName(a.get) == "a"

  test "node.children(doc, name) returns all matching children":
    parseOk("parent { a 1; b; a 2; a 3 }"):
      let p = doc.nodes[0]
      let aChildren = p.children(doc, "a")
      check aChildren.len == 3

  test "named-properties iterator yields (string, KdlValue) pairs":
    parseOk("n enabled=#true count=42 name=\"foo\""):
      let n = doc.nodes[0]
      var keys: seq[string] = @[]
      for k, _ in n.namedProperties(doc):
        keys.add(k)
      check keys == @["enabled", "count", "name"]

suite "positional argument accessors (arg / hasArg)":
  test "node.arg distinguishes an explicit #null arg from a missing one":
    # The whole reason arg returns Option (not a kvNull sentinel): a present
    # `#null` positional and an absent positional are different facts, and a
    # sentinel conflates them.
    parseOk("n #null"):
      let n = doc.nodes[0]
      check n.arg(0).isSome              # present...
      check n.arg(0).get.kind == kvNull  # ...and its value is #null
      check n.arg(1).isNone              # genuinely absent

  test "node.arg(idx) returns some(idx-th positional value)":
    parseOk("n \"first\" 2 \"third\""):
      let n = doc.nodes[0]
      check n.arg(0).get.kind == kvString
      check n.arg(0).get.strVal == "first"
      check n.arg(1).get.kind == kvInt
      check n.arg(1).get.intVal == 2
      check n.arg(2).get.kind == kvString
      check n.arg(2).get.strVal == "third"

  test "node.arg(idx) returns none for out-of-range":
    parseOk("n \"only\""):
      let n = doc.nodes[0]
      check n.arg(1).isNone
      check n.arg(99).isNone

  test "node.args returns all positionals in order, skipping interleaved props":
    parseOk("n \"a\" k=1 \"b\" m=2 \"c\""):
      let a = doc.nodes[0].args
      check a.len == 3
      check a[0].strVal == "a"
      check a[1].strVal == "b"
      check a[2].strVal == "c"

  test "node.args is empty when the node has no positionals":
    parseOk("n k=1\nbare"):
      check doc.nodes[0].args.len == 0   # only a property
      check doc.nodes[1].args.len == 0   # bare node

  test "node.hasArg(idx) reports positional presence":
    parseOk("n \"x\" \"y\""):
      let n = doc.nodes[0]
      check n.hasArg(0)
      check n.hasArg(1)
      check not n.hasArg(2)

  test "arg / hasArg ignore interleaved properties (only count positionals)":
    parseOk("n \"first\" k=1 \"second\" m=2 \"third\""):
      let n = doc.nodes[0]
      check n.hasArg(2)
      check n.arg(2).get.strVal == "third"
      check not n.hasArg(3)

suite "doc-level node/nodes (M4 — bare-noun renames)":
  test "doc.node(name) finds first matching top-level node":
    parseOk("a 1\nb\na 2"):
      let n = doc.node("a")
      check n.isSome
      check doc.resolveName(n.get) == "a"

  test "doc.node(missing) returns None":
    parseOk("a"):
      check doc.node("missing").isNone

  test "doc.nodes(name) returns all matches in source order":
    parseOk("rule \"x\"\nother\nrule \"y\""):
      let rules = doc.nodes("rule")
      check rules.len == 2

  test "field doc.nodes and proc doc.nodes(name) coexist":
    parseOk("a 1\nb 2\na 3"):
      # `doc.nodes` (no args) is the field — every top-level node.
      check doc.nodes.len == 3
      # `doc.nodes(name)` is the filter proc — only matching ones.
      check doc.nodes("a").len == 2
      check doc.nodes("b").len == 1
      check doc.nodes("missing").len == 0
