## Tests for byte-lossless round-trip via the source-string-plus-spans
## scheme. `KdlDoc.sourceText` carries the original input; `emPreserve`
## mode in the encoder emits it verbatim for unmodified docs.
##
## Beats kdl-rs's per-node-trivia approach by being zero-copy: one
## string for the whole document plus existing Span pointers, vs
## kdl-rs's allocate-trivia-strings-per-AST-node.

import std/[strutils, unittest]

import ../src/ast
import ../src/encode
import ../src/parser
import ../src/spans

suite "trivia preservation — phase A (sourceText capture)":
  test "parse populates doc.sourceText with the original bytes":
    let src = "a 1\nb \"hello\"\n"
    let r = parse(src)
    check r.isOk
    if r.isOk:
      check r.get.sourceText == src

  test "newDoc has empty sourceText":
    let doc = newDoc()
    check doc.sourceText == ""

suite "trivia preservation — phase B (emPreserve encoder)":
  test "parsed doc encodes byte-for-byte in emPreserve":
    let src = "rule \"compaction\" {\n    enabled #true\n}\n"
    let r = parse(src)
    check r.isOk
    if r.isOk:
      check encode(r.get, emPreserve) == src

  test "built-from-scratch doc falls back to canonical":
    var doc = newDoc()
    var n = newNode(doc, "rule")
    n.addArg(doc, newStringValue("foo"))
    doc.add(n)
    let preserved = encode(doc, emPreserve)
    let canonical = encode(doc, emPretty)
    check preserved == canonical

  test "preserves comments and exact whitespace":
    let src = "// leading comment\na 1   2  // trailing\n/* block */\nb"
    let r = parse(src)
    check r.isOk
    if r.isOk:
      check encode(r.get, emPreserve) == src

  test "preserves original number bases":
    let src = "n 0xff 0b1010 0o777"
    let r = parse(src)
    check r.isOk
    if r.isOk:
      check encode(r.get, emPreserve) == src

  test "preserves string escape forms":
    let src = "n \"foo\\u{0a}bar\""
    let r = parse(src)
    check r.isOk
    if r.isOk:
      check encode(r.get, emPreserve) == src

  test "preserves raw string `#` count":
    let src = "n ##\"hello \"#\"##"
    let r = parse(src)
    check r.isOk
    if r.isOk:
      check encode(r.get, emPreserve) == src

suite "trivia preservation — phase B (mutation falls back to canonical)":
  test "mutated parsed doc emits canonical, not original":
    let src = "n a=1 b=2"
    let r = parse(src)
    check r.isOk
    if r.isOk:
      var doc = r.get
      doc.nodes[0].setProp(doc, "a", newIntValue(99))
      let text = encode(doc, emPreserve)
      check "a=99" in text
      check text != src
