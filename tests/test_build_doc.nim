## Unit tests for buildDoc — the Cat 3 (AST/DOM) consumer of the
## cursor. Folds CursorEvents into a KdlDoc using an explicit
## node-construction stack. Replaces the visitor-protocol DocBuilder
## from src/doc_builder.nim.
##
## These tests cover the fold itself; the validation gate that proves
## the rewrite is sound is the existing test suite (668 unit + 18
## property + 338 conformance) after parse() switches to buildDoc.

import std/unittest

import ../src/ast
import ../src/cursor
import ../src/doc_build
import ../src/intern
import ../src/lexer
import ../src/spans

proc buildFrom(src: string): KdlDoc =
  var interner = initInterner()
  var stream = new(TokenStream)
  stream[] = lex(src, interner)
  var c = initStringCursor(addr stream[], src)
  let r = buildDoc(c, sourcePath = "<test>")
  check r.isOk
  r.get

suite "buildDoc — single node":
  test "lone bareword produces a KdlDoc with one top-level node":
    let doc = buildFrom("foo")
    check doc.nodes.len == 1
    check doc.interner.lookup(doc.nodes[0].name) == "foo"

suite "buildDoc — entries":
  test "numeric arg becomes a KdlEntry(argument)":
    let doc = buildFrom("foo 42")
    check doc.nodes[0].entries.len == 1
    let e = doc.nodes[0].entries[0]
    check e.kind == keArgument
    check e.argValue.kind == kvInt
    check e.argValue.intVal == 42

  test "property becomes a KdlEntry(property) with key":
    let doc = buildFrom("foo x=1")
    check doc.nodes[0].entries.len == 1
    let e = doc.nodes[0].entries[0]
    check e.kind == keProperty
    check doc.interner.lookup(e.propName) == "x"

  test "later prop wins (KDL v2 dedup)":
    let doc = buildFrom("foo x=1 x=2")
    check doc.nodes[0].entries.len == 1
    check doc.nodes[0].entries[0].propValue.intVal == 2

suite "buildDoc — children":
  test "node with single child":
    let doc = buildFrom("foo { bar }")
    check doc.nodes.len == 1
    check doc.nodes[0].children.len == 1
    check doc.interner.lookup(doc.nodes[0].children[0].name) == "bar"

  test "depth-3 nesting (the #11-fix payoff)":
    let doc = buildFrom("l1 { l2 { l3 } }")
    check doc.nodes.len == 1
    check doc.nodes[0].children.len == 1
    check doc.nodes[0].children[0].children.len == 1
    check doc.interner.lookup(
      doc.nodes[0].children[0].children[0].name) == "l3"

suite "buildDoc — multiple top-level nodes":
  test "semi-separated":
    let doc = buildFrom("foo;bar")
    check doc.nodes.len == 2
    check doc.interner.lookup(doc.nodes[0].name) == "foo"
    check doc.interner.lookup(doc.nodes[1].name) == "bar"

suite "buildDoc — type annotations":
  test "node type annotation populates KdlNode.typeAnnotation":
    let doc = buildFrom("(u8)foo")
    check doc.interner.lookup(doc.nodes[0].typeAnnotation) == "u8"

  test "arg type annotation populates KdlValue.typeAnnotation":
    let doc = buildFrom("foo (i32)42")
    let val = doc.nodes[0].entries[0].argValue
    check doc.interner.lookup(val.typeAnnotation) == "i32"

suite "buildDoc — slashdash":
  test "slashdashed entry is omitted from the AST":
    let doc = buildFrom("foo /-42 13")
    check doc.nodes[0].entries.len == 1
    check doc.nodes[0].entries[0].argValue.intVal == 13

  test "slashdashed top-level node is omitted":
    let doc = buildFrom("/- foo\nbar")
    check doc.nodes.len == 1
    check doc.interner.lookup(doc.nodes[0].name) == "bar"

  test "slashdashed children block is omitted":
    let doc = buildFrom("foo /-{ skip_me }")
    check doc.nodes.len == 1
    check doc.nodes[0].children.len == 0
