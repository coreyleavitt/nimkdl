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

suite "trivia preservation — per-node freshness (FNV-1a 128)":
  test "editing one top-level node preserves the others byte-for-byte":
    let src = "// header comment\nrule \"compaction\" enabled=#true\nrule \"permission-deny\" default=\"ask\"\n"
    let r = parse(src)
    check r.isOk
    if r.isOk:
      var doc = r.get
      # Edit the FIRST rule's enabled property.
      doc.nodes[0].setProp(doc, "enabled", newBoolValue(false))
      let text = encode(doc, emPreserve)
      # First rule re-emitted canonical (enabled=#false now).
      check "enabled=#false" in text
      # Second rule's source bytes preserved verbatim — no canonicalization.
      check "rule \"permission-deny\" default=\"ask\"" in text

  test "editing deep child preserves sibling subtree":
    let src = "outer {\n    rule \"a\" {\n        threshold 0.7\n        enabled #true\n    }\n    other-rule {\n        keep-me #true\n    }\n}\n"
    let r = parse(src)
    check r.isOk
    if r.isOk:
      var doc = r.get
      # Mutate deep: doc.nodes[0].children[0].entries[0] (threshold).
      doc.nodes[0].children[0].setProp(doc, "threshold", newFloatValue(0.8))
      let text = encode(doc, emPreserve)
      # Mutated entry shows the new value.
      check "threshold=0.8" in text
      # Sibling subtree (`other-rule`) preserves its inner content
      # verbatim — span starts at the node name, so leading indent
      # of the surrounding parent isn't part of the span. The
      # internal 8-space indent and `keep-me #true` are intact.
      check "other-rule {\n        keep-me #true\n    }" in text

  test "adding a new top-level node leaves existing nodes verbatim":
    let src = "rule \"a\" enabled=#true\nrule \"b\" enabled=#false\n"
    let r = parse(src)
    check r.isOk
    if r.isOk:
      var doc = r.get
      var newer = newNode(doc, "rule")
      newer.addArg(doc, newStringValue("c"))
      doc.add(newer)
      let text = encode(doc, emPreserve)
      # Existing nodes preserved with their original quoting.
      check "rule \"a\" enabled=#true" in text
      check "rule \"b\" enabled=#false" in text
      # New node emitted canonical (bare-string form for "c" since it's
      # a valid bare ident).
      check "rule c" in text

  test "hash mismatch correctly identifies edited subtree":
    let src = "a { b 1 }\nc { d 2 }"
    let r = parse(src)
    check r.isOk
    if r.isOk:
      var doc = r.get
      # Edit a's child b.
      doc.nodes[0].children[0].setProp(doc, "x", newIntValue(99))
      let text = encode(doc, emPreserve)
      # 'a' subtree re-emitted (canonical); 'c' subtree preserved.
      check "x=99" in text
      check "c { d 2 }" in text
