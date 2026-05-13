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
  test "doc.findNode(name) returns Some(first top-level) by name":
    parseOk("a x=1\nb y=2\na z=3"):
      let n = doc.findNode("a")
      check n.isSome
      check doc.resolveName(n.get) == "a"

  test "doc.findNode(name) returns None when missing":
    parseOk("a x=1"):
      check doc.findNode("missing").isNone

  test "doc.findNodes(name) returns all top-level matches in source order":
    parseOk("rule \"first\"\nother\nrule \"second\""):
      let rules = doc.findNodes("rule")
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
  test "node.arg(idx) returns the idx-th positional value":
    parseOk("n \"first\" 2 \"third\""):
      let n = doc.nodes[0]
      check n.arg(0).kind == kvString
      check n.arg(0).strVal == "first"
      check n.arg(1).kind == kvInt
      check n.arg(1).intVal == 2
      check n.arg(2).kind == kvString
      check n.arg(2).strVal == "third"

  test "node.arg(idx) returns kvNull for out-of-range":
    parseOk("n \"only\""):
      let n = doc.nodes[0]
      check n.arg(99).kind == kvNull

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
      check n.arg(2).strVal == "third"
      check not n.hasArg(3)
