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
