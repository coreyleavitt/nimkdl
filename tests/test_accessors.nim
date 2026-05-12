## Tests for string-keyed convenience accessors on KdlDoc / KdlNode.
##
## These layer on top of the existing InternedStr-keyed primitives in
## codegen.nim (findProp / findChild / etc.) so consumers don't have
## to thread the interner by hand for ad-hoc inspection.

import std/unittest

import ../src/ast
import ../src/intern
import ../src/parser
import ../src/spans

template parseOk(src: string, body: untyped) =
  let res = parse(src)
  check res.isOk
  if res.isOk:
    let doc {.inject.} = res.get
    body

suite "string-keyed accessors":
  test "doc.node(name) returns first top-level by name string":
    parseOk("a x=1\nb y=2\na z=3"):
      let n = doc.findNode("a")
      check n.name != InvalidInterned
      check doc.resolveName(n) == "a"

  test "doc.node(name) returns sentinel when missing":
    parseOk("a x=1"):
      let n = doc.findNode("missing")
      check n.name == InvalidInterned

  test "doc.findNodes(name) returns all top-level matches in source order":
    parseOk("rule \"first\"\nother\nrule \"second\""):
      let rules = doc.findNodes("rule")
      check rules.len == 2

  test "node.prop(doc, name) returns the property value":
    parseOk("n enabled=#true count=42"):
      let n = doc.nodes[0]
      check n.prop(doc, "enabled").kind == kvBool
      check n.prop(doc, "enabled").boolVal == true
      check n.prop(doc, "count").intVal == 42

  test "node.prop(doc, missing) returns kvNull sentinel":
    parseOk("n enabled=#true"):
      let n = doc.nodes[0]
      let v = n.prop(doc, "absent")
      check v.kind == kvNull

  test "node.hasProp(doc, name) reports presence":
    parseOk("n a=1"):
      let n = doc.nodes[0]
      check n.hasProp(doc, "a")
      check not n.hasProp(doc, "b")

  test "node.child(doc, name) returns first child by name":
    parseOk("parent { a \"first\"; b; a \"second\" }"):
      let p = doc.nodes[0]
      let a = p.child(doc, "a")
      check a.name != InvalidInterned
      check doc.resolveName(a) == "a"

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
