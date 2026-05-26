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
    let r = parse(src, preserveHashes = true)
    check r.isOk
    if r.isOk:
      check r.get.sourceText == src

  test "newDoc has empty sourceText":
    let doc = newDoc()
    check doc.sourceText == ""

suite "trivia preservation — phase B (emPreserve encoder)":
  test "parsed doc encodes byte-for-byte in emPreserve":
    let src = "rule \"compaction\" {\n    enabled #true\n}\n"
    let r = parse(src, preserveHashes = true)
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
    let r = parse(src, preserveHashes = true)
    check r.isOk
    if r.isOk:
      check encode(r.get, emPreserve) == src

  test "preserves original number bases":
    let src = "n 0xff 0b1010 0o777"
    let r = parse(src, preserveHashes = true)
    check r.isOk
    if r.isOk:
      check encode(r.get, emPreserve) == src

  test "preserves string escape forms":
    let src = "n \"foo\\u{0a}bar\""
    let r = parse(src, preserveHashes = true)
    check r.isOk
    if r.isOk:
      check encode(r.get, emPreserve) == src

  test "preserves raw string `#` count":
    let src = "n ##\"hello \"#\"##"
    let r = parse(src, preserveHashes = true)
    check r.isOk
    if r.isOk:
      check encode(r.get, emPreserve) == src

suite "trivia preservation — phase B (mutation falls back to canonical)":
  test "mutated parsed doc emits canonical, not original":
    let src = "n a=1 b=2"
    let r = parse(src, preserveHashes = true)
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
    let r = parse(src, preserveHashes = true)
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
    let r = parse(src, preserveHashes = true)
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
    let r = parse(src, preserveHashes = true)
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
    let r = parse(src, preserveHashes = true)
    check r.isOk
    if r.isOk:
      var doc = r.get
      # Edit a's child b.
      doc.nodes[0].children[0].setProp(doc, "x", newIntValue(99))
      let text = encode(doc, emPreserve)
      # 'a' subtree re-emitted (canonical); 'c' subtree preserved.
      check "x=99" in text
      check "c { d 2 }" in text

suite "trivia preservation — surgical splice (B1: in-place entry edit)":
  test "in-place entry edit preserves all sibling entries' source bytes":
    # Parse a node with several entries spanning unusual whitespace.
    # Edit just one entry; the rest must survive byte-for-byte
    # including any non-canonical spacing.
    let src = "n  a=1   b=2     c=3\n"
    let r = parse(src, preserveHashes = true)
    check r.isOk
    if r.isOk:
      var doc = r.get
      doc.nodes[0].setProp(doc, "b", newIntValue(99))
      let text = encode(doc, emPreserve)
      # `a=1` and `c=3` preserved with their exact original spacing
      # (3+ spaces between b and c, etc.)
      check "  a=1   " in text      # original 2 + 3 spaces around a=1
      check "     c=3" in text      # original 5 spaces before c=3
      check "b=99" in text          # only this changed

  test "in-place edit preserves trailing comment on the same line":
    # Trailing comments after the last entry live in the node's
    # source bytes (between the last entry's end and the node
    # terminator). Surgical splice must not touch them.
    let src = "n a=1 b=2 // important context here\nother"
    let r = parse(src, preserveHashes = true)
    check r.isOk
    if r.isOk:
      var doc = r.get
      doc.nodes[0].setProp(doc, "a", newIntValue(99))
      let text = encode(doc, emPreserve)
      check "a=99" in text
      check "// important context here" in text

  test "deep edit preserves outer-level formatting and comments":
    # Parse a doc with comments at outer level + custom indentation
    # in a children block. Edit one deep entry. Outer-level comments
    # and the rule's source-bytes around the edited entry must
    # survive verbatim.
    let src = "// top-level header\nrule \"compaction\" {\n  // inner note\n  enabled #true\n  threshold 0.7\n}\n"
    let r = parse(src, preserveHashes = true)
    check r.isOk
    if r.isOk:
      var doc = r.get
      doc.nodes[0].children[0].setProp(doc, "threshold",
                                       newFloatValue(0.8))
      let text = encode(doc, emPreserve)
      check "// top-level header" in text
      check "// inner note" in text
      check "threshold=0.8" in text     # edited
      check "enabled #true" in text     # sibling entry preserved

suite "trivia preservation — surgical splice (B2: shape-change fallback)":
  test "adding a new entry falls back to canonical for that node only":
    # New entry → shape change → that node goes canonical. Siblings
    # of THAT NODE (other top-level nodes) preserve verbatim.
    let src = "// header\nrule \"a\" enabled=#true\nrule \"b\" enabled=#false\n"
    let r = parse(src, preserveHashes = true)
    check r.isOk
    if r.isOk:
      var doc = r.get
      doc.nodes[0].setProp(doc, "newkey", newIntValue(42))
      let text = encode(doc, emPreserve)
      # Sibling rule "b" still verbatim, including its exact source bytes.
      check "rule \"b\" enabled=#false" in text
      check "// header" in text
      # rule "a" canonical, contains the new key.
      check "newkey=42" in text

  test "removing an entry falls back to canonical for that node only":
    let src = "// keep this comment\nrule a=1 b=2 c=3\nother thing\n"
    let r = parse(src, preserveHashes = true)
    check r.isOk
    if r.isOk:
      var doc = r.get
      check doc.nodes[0].removeProp(doc, "b")
      let text = encode(doc, emPreserve)
      check "// keep this comment" in text
      check "other thing" in text       # sibling preserved

when defined(kdlHashStats):
  suite "trivia preservation — encoder hashes each node at most once":
    # Quadratic-hashing regression guard. The natural recursive
    # implementation calls hashNodeContent(n) at every level — which
    # itself recurses through the subtree — so an N-deep tree gets
    # hashed O(N²) bytes per encode. Threading the hash through the
    # recursion makes it O(N).
    test "hash-call count is bounded by node count":
      let src = """
        rule "a" {
          action "x" enabled=#true
          action "y" {
            nested "z" k=1
          }
        }
        rule "b" key="v"
        rule "c"
      """
      let r = parse(src, preserveHashes = true)
      check r.isOk
      var doc = r.get
      # Force a mutation so the encoder takes the per-node freshness
      # path (the no-mutation path is a fast-return of doc.sourceText
      # with zero hash calls and isn't what we're measuring).
      doc.nodes[0].setProp(doc, "touched", newBoolValue(true))
      # Count nodes — including all descendants. We expect at most
      # one hash computation per node.
      proc countNodes(ns: seq[KdlNode]): int =
        for n in ns:
          result.inc
          result.inc countNodes(n.children)
      let nodeCount = countNodes(doc.nodes)
      kdlHashCallCount = 0
      discard encode(doc, emPreserve)
      check kdlHashCallCount <= nodeCount

when not defined(release):
  # Raw-field mutation should be caught with a useful diagnostic
  # rather than silently producing stale source bytes.
  suite "trivia preservation — raw-field-mutation detection (debug)":
    test "raw mutation that doesn't call markMutated panics in debug":
      let r = parse("rule \"original\"", preserveHashes = true)
      check r.isOk
      var doc = r.get
      # Bypass the builder API: mutate a value field directly.
      # `doc.mutated` stays false, but the content no longer matches
      # `parseHash`. The fast-path return of doc.sourceText would
      # silently produce stale bytes; we want to panic instead.
      doc.nodes[0].entries[0].argValue.strVal = "tampered"
      expect AssertionDefect:
        discard encode(doc, emPreserve)

    test "clean parsed doc still fast-paths without panic":
      let r = parse("rule \"a\"\nrule \"b\"", preserveHashes = true)
      check r.isOk
      let text = encode(r.get, emPreserve)
      check text.contains("rule")
      check text.contains("\"a\"")
      check text.contains("\"b\"")

    test "explicit markMutated after raw mutation skips the assertion":
      # Strings that look like bare idents canonical-emit unquoted, so
      # we use one that requires quoting to keep the round-trip visible.
      let r = parse("rule \"x with space\"", preserveHashes = true)
      check r.isOk
      var doc = r.get
      doc.nodes[0].entries[0].argValue.strVal = "y with space"
      doc.markMutated()  # caller acknowledges; encode takes slow path
      let text = encode(doc, emPreserve)
      check "\"y with space\"" in text
