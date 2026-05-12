## Tests for the programmatic builder + mutation API on KdlDoc /
## KdlNode. Required for any consumer that wants to construct KDL
## programmatically or edit a parsed document and serialize it back
## out (config diff/merge, generators, REPL).

import std/[strutils, unittest]

import ../src/ast
import ../src/encode
import ../src/intern
import ../src/parser
import ../src/spans

template parseGet(src: string, doc: untyped, body: untyped) =
  let res = parse(src)
  check res.isOk
  if res.isOk:
    var doc {.inject.} = res.get
    body

suite "builder — programmatic construction":
  test "build a doc from scratch and encode round-trips":
    var doc = newDoc()
    var n = newNode(doc, "rule")
    n.addArg(newStringValue("compaction"))
    n.setProp(doc, "enabled", newBoolValue(true))
    n.setProp(doc, "max", newIntValue(42))
    doc.add(n)
    let text = encode(doc)
    let reparsed = parse(text)
    check reparsed.isOk
    if reparsed.isOk:
      check docEqual(doc, reparsed.get)

  test "addChild attaches a nested node":
    var doc = newDoc()
    var parent = newNode(doc, "outer")
    var child = newNode(doc, "inner")
    child.setProp(doc, "label", newStringValue("hi"))
    parent.addChild(child)
    doc.add(parent)
    let text = encode(doc)
    check "outer" in text
    check "inner" in text
    check "label=hi" in text

suite "builder — mutation on parsed docs":
  test "setProp replaces an existing property in source order":
    parseGet("n a=1 b=2 c=3", doc):
      doc.nodes[0].setProp(doc, "b", newIntValue(99))
      check doc.nodes[0].prop(doc, "b").intVal == 99
      # Source order preserved (b stays where it was; not bumped to end).
      var order: seq[string] = @[]
      for k, _ in doc.nodes[0].namedProperties(doc):
        order.add(k)
      check order == @["a", "b", "c"]

  test "setProp appends when the property is absent":
    parseGet("n a=1", doc):
      doc.nodes[0].setProp(doc, "b", newIntValue(2))
      check doc.nodes[0].hasProp(doc, "b")
      check doc.nodes[0].prop(doc, "b").intVal == 2

  test "removeProp deletes by name and returns true on hit":
    parseGet("n a=1 b=2", doc):
      check doc.nodes[0].removeProp(doc, "a")
      check not doc.nodes[0].hasProp(doc, "a")
      check doc.nodes[0].hasProp(doc, "b")

  test "removeProp returns false when name absent":
    parseGet("n a=1", doc):
      check not doc.nodes[0].removeProp(doc, "z")

  test "removeChild removes by name; returns count":
    parseGet("p { a 1; b; a 2; c }", doc):
      let removed = doc.nodes[0].removeChild(doc, "a")
      check removed == 2
      check doc.nodes[0].child(doc, "a").name == InvalidInterned
      check doc.nodes[0].child(doc, "b").name != InvalidInterned

  test "setTypeAnnotation tags a node":
    parseGet("n", doc):
      doc.nodes[0].setTypeAnnotation(doc, "version")
      check doc.resolveName(doc.nodes[0]) == "n"
      check doc.typeAnnotationOf(doc.nodes[0]) == "version"
      let text = encode(doc)
      check "(version)" in text

  test "doc.remove drops all top-level nodes by name":
    parseGet("a 1\nb\na 2\nc", doc):
      let removed = doc.remove("a")
      check removed == 2
      check doc.findNode("a").name == InvalidInterned

  test "doc.replace swaps the first matching top-level node":
    parseGet("a 1\nb\na 2", doc):
      var newer = newNode(doc, "a")
      newer.addArg(newStringValue("replaced"))
      check doc.replace("a", newer)
      # First `a` was replaced; second `a` still present.
      let matches = doc.findNodes("a")
      check matches.len == 2
      check matches[0].entries[0].argValue.strVal == "replaced"

suite "builder — round-trip after edits":
  test "edit a parsed doc and reparse yields the edited shape":
    parseGet("rule \"foo\"\nrule \"bar\"", doc):
      var n = newNode(doc, "rule")
      n.addArg(newStringValue("baz"))
      doc.add(n)
      let text = encode(doc)
      let reparsed = parse(text)
      check reparsed.isOk
      if reparsed.isOk:
        check reparsed.get.findNodes("rule").len == 3
