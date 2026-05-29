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
    let r = parse(src, preserveFormat = true)
    check r.isOk
    if r.isOk:
      check r.get.sourceText == src

  test "newDoc has empty sourceText":
    let doc = newDoc()
    check doc.sourceText == ""

suite "trivia preservation — phase B (emPreserve encoder)":
  test "parsed doc encodes byte-for-byte in emPreserve":
    let src = "rule \"compaction\" {\n    enabled #true\n}\n"
    let r = parse(src, preserveFormat = true)
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
    let r = parse(src, preserveFormat = true)
    check r.isOk
    if r.isOk:
      check encode(r.get, emPreserve) == src

  test "preserves original number bases":
    let src = "n 0xff 0b1010 0o777"
    let r = parse(src, preserveFormat = true)
    check r.isOk
    if r.isOk:
      check encode(r.get, emPreserve) == src

  test "preserves string escape forms":
    let src = "n \"foo\\u{0a}bar\""
    let r = parse(src, preserveFormat = true)
    check r.isOk
    if r.isOk:
      check encode(r.get, emPreserve) == src

  test "preserves raw string `#` count":
    let src = "n ##\"hello \"#\"##"
    let r = parse(src, preserveFormat = true)
    check r.isOk
    if r.isOk:
      check encode(r.get, emPreserve) == src

suite "trivia preservation — phase B (mutation falls back to canonical)":
  test "mutated parsed doc emits canonical, not original":
    let src = "n a=1 b=2"
    let r = parse(src, preserveFormat = true)
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
    let r = parse(src, preserveFormat = true)
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
    let r = parse(src, preserveFormat = true)
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
    let r = parse(src, preserveFormat = true)
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
    let r = parse(src, preserveFormat = true)
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
    let r = parse(src, preserveFormat = true)
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
    let r = parse(src, preserveFormat = true)
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
    let r = parse(src, preserveFormat = true)
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

suite "trivia preservation — shape-change (B2: tombstone-aware walk)":
  test "pure-add entry preserves sibling-entry source bytes + sibling top-level node":
    let src = "// header\nrule \"a\" enabled=#true\nrule \"b\" enabled=#false\n"
    let r = parse(src, preserveFormat = true)
    check r.isOk
    if r.isOk:
      var doc = r.get
      doc.nodes[0].setProp(doc, "newkey", newIntValue(42))
      let text = encode(doc, emPreserve)
      check "rule \"b\" enabled=#false" in text  # sibling node verbatim
      check "// header" in text
      check "newkey=42" in text                  # new entry appended
      check "enabled=#true" in text              # original sibling-entry preserved

  test "pure-remove entry preserves other entries' source bytes":
    let src = "// keep this comment\nrule a=1   b=2     c=3\nother thing\n"
    let r = parse(src, preserveFormat = true)
    check r.isOk
    if r.isOk:
      var doc = r.get
      check doc.nodes[0].removeProp(doc, "b")
      let text = encode(doc, emPreserve)
      check "// keep this comment" in text
      check "other thing" in text                # sibling top-level preserved
      check "a=1" in text                        # surviving entry preserved
      check "c=3" in text
      check "b=2" notin text                     # removed entry gone

  test "pure-remove entry preserves trailing comment on the same line":
    let src = "rule a=1 b=2 // trailing context\nother\n"
    let r = parse(src, preserveFormat = true)
    check r.isOk
    if r.isOk:
      var doc = r.get
      check doc.nodes[0].removeProp(doc, "b")
      let text = encode(doc, emPreserve)
      check "a=1" in text
      check "b=2" notin text
      check "// trailing context" in text        # trailing trivia preserved

  test "pure-remove child preserves sibling children + node framing":
    let src = "rule \"x\" {\n  // first note\n  enabled #true\n  // second note\n  threshold 0.7\n}\n"
    let r = parse(src, preserveFormat = true)
    check r.isOk
    if r.isOk:
      var doc = r.get
      check doc.nodes[0].removeChild(doc, "enabled") == 1
      let text = encode(doc, emPreserve)
      check "rule \"x\"" in text                 # framing preserved
      check "threshold 0.7" in text              # surviving child preserved
      check "// second note" in text             # trivia between gone-child and surviving
      check "enabled #true" notin text

  test "pure-add child to existing children block":
    let src = "rule {\n  // existing note\n  enabled #true\n}\n"
    let r = parse(src, preserveFormat = true)
    check r.isOk
    if r.isOk:
      var doc = r.get
      var newchild = newNode(doc, "threshold")
      newchild.addArg(doc, newFloatValue(0.8))
      doc.nodes[0].addChild(doc, newchild)
      let text = encode(doc, emPreserve)
      check "// existing note" in text           # original trivia preserved
      check "enabled #true" in text              # original child verbatim
      check "threshold" in text                  # appended
      check text.endsWith("}\n") or text.endsWith("}")

  test "mixed remove+add inside a single node":
    let src = "rule a=1 b=2 c=3\n"
    let r = parse(src, preserveFormat = true)
    check r.isOk
    if r.isOk:
      var doc = r.get
      check doc.nodes[0].removeProp(doc, "b")
      doc.nodes[0].setProp(doc, "d", newIntValue(4))
      let text = encode(doc, emPreserve)
      check "a=1" in text                        # surviving original
      check "c=3" in text                        # surviving original
      check "d=4" in text                        # appended
      check "b=2" notin text                     # removed

  test "doc-level remove preserves sibling nodes + inter-node trivia":
    let src = "// file header\nfirst a=1\n\n// section\nsecond b=2\nthird c=3\n"
    let r = parse(src, preserveFormat = true)
    check r.isOk
    if r.isOk:
      var doc = r.get
      check doc.removeNode("second") == 1
      let text = encode(doc, emPreserve)
      check "// file header" in text
      check "first a=1" in text                  # sibling preserved
      check "third c=3" in text                  # sibling preserved
      check "second" notin text                  # removed

  test "doc-level add appends new top-level node":
    let src = "first a=1\nsecond b=2\n"
    let r = parse(src, preserveFormat = true)
    check r.isOk
    if r.isOk:
      var doc = r.get
      var newnode = newNode(doc, "added")
      newnode.addArg(doc, newIntValue(99))
      doc.insert(doc.nodes.len, newnode)
      let text = encode(doc, emPreserve)
      check "first a=1" in text
      check "second b=2" in text
      check "added" in text
      check "99" in text

when defined(kdlHashStats):
  suite "trivia preservation — encoder skips per-node hashing":
    # Pre-gap-3 the encoder computed `hashNodeFromChildHashes` for
    # every node in the slow path — O(N) full-content hashes per
    # encode pass. The dirty-flag fix makes that work entirely
    # unnecessary: clean subtrees emit source bytes after an O(1)
    # `subtreeDirty` check; only dirty subtrees walk entries (and
    # only entries inside a dirty subtree get hashed). Edits that
    # touch one node in an otherwise-clean tree should cost ~0
    # `hashNodeFromChildHashes` calls. Per-entry `hashEntry` still
    # fires inside the dirty subtree's forward walk (cheap; catches
    # raw field mutation that bypassed the builder API).
    test "node-level hash work is zero across encode passes":
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
      let r = parse(src, preserveFormat = true)
      check r.isOk
      var doc = r.get
      # Edit one top-level node. Siblings + a's children remain clean.
      doc.nodes[0].setProp(doc, "touched", newBoolValue(true))
      kdlHashCallCount = 0
      discard encode(doc, emPreserve)
      # Zero node-level (`hashNodeFromChildHashes` / `hashNodeContent`)
      # work — the doc-level raw-mutation safety check is gated on
      # `doc.mutated == false`, which is false here (the setProp
      # flipped it), so even debug builds skip it.
      check kdlHashCallCount == 0

when not defined(release):
  # Raw-field mutation should be caught with a useful diagnostic
  # rather than silently producing stale source bytes.
  suite "trivia preservation — raw-field-mutation detection (debug)":
    test "raw mutation that doesn't call markMutated panics in debug":
      let r = parse("rule \"original\"", preserveFormat = true)
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
      let r = parse("rule \"a\"\nrule \"b\"", preserveFormat = true)
      check r.isOk
      let text = encode(r.get, emPreserve)
      check text.contains("rule")
      check text.contains("\"a\"")
      check text.contains("\"b\"")

    test "explicit markMutated after raw mutation skips the assertion":
      # Strings that look like bare idents canonical-emit unquoted, so
      # we use one that requires quoting to keep the round-trip visible.
      let r = parse("rule \"x with space\"", preserveFormat = true)
      check r.isOk
      var doc = r.get
      doc.nodes[0].entries[0].argValue.strVal = "y with space"
      doc.markMutated()  # caller acknowledges; encode takes slow path
      let text = encode(doc, emPreserve)
      check "\"y with space\"" in text

suite "trivia preservation — framing-only edits preserve interior":
  # When only a node's `name` or `typeAnnotation` changes (no entry or
  # child mutated), the preserving emit canonical-emits just the new
  # `(tag)name` and then preserves `sourceText[headSpan.finish..<
  # span.finish]` verbatim. The pre-headSpan code fell back to fully
  # canonical for this edit class, losing interior trivia. These tests
  # pin the new contract.

  test "rename node preserves inter-entry trivia":
    let src = "old  a=1   b=2     c=3\n"
    let r = parse(src, preserveFormat = true)
    check r.isOk
    if r.isOk:
      var doc = r.get
      doc.nodes[0].setName(doc, "new")
      let text = encode(doc, emPreserve)
      check text.startsWith("new")
      check "  a=1   " in text       # original 2 + 3 spaces around a=1
      check "     c=3" in text       # original 5 spaces before c=3

  test "rename node preserves trailing comment":
    let src = "old a=1 // important context\nother"
    let r = parse(src, preserveFormat = true)
    check r.isOk
    if r.isOk:
      var doc = r.get
      doc.nodes[0].setName(doc, "renamed")
      let text = encode(doc, emPreserve)
      check "renamed" in text
      check "// important context" in text

  test "add type annotation preserves child block layout":
    let src = "rule {\n  // inner note\n  enabled #true\n  threshold 0.7\n}\n"
    let r = parse(src, preserveFormat = true)
    check r.isOk
    if r.isOk:
      var doc = r.get
      doc.nodes[0].setTypeAnnotation(doc, "v2")
      let text = encode(doc, emPreserve)
      check "(v2)rule" in text
      check "// inner note" in text     # interior preserved
      check "enabled #true" in text     # exact entry spacing preserved
      check "threshold 0.7" in text

suite "trivia preservation — tagged source mutation (proptest counterexample)":
  # Proptest property #3 (stateful round-trip) found this in 5 examples
  # on first run. Pre-fix: parser set `n.span.start = nameTok.span.start`
  # — pointing at the name, NOT at `(tag)`. Doc-level walk emitted
  # `sourceText[0..span.start]` as inter-node trivia, which included the
  # original `(type)` prefix. The dirty node then canonical-emitted its
  # framing as `(type)node`, producing `(type)(type)node a=0` — invalid
  # syntax, re-parse failed.
  #
  # Fix: visitBeginNode sets `span.start = tagStart` when a tag is
  # present, and headLen covers the full `(tag)name` framing. visitEndNode
  # preserves span.start and only updates span.finish.

  test "mutating a tagged-source node produces parseable output":
    let src = "(type)node"
    let r = parse(src, preserveFormat = true)
    check r.isOk
    if r.isOk:
      var doc = r.get
      doc.nodes[0].setProp(doc, "a", newIntValue(0))
      let text = encode(doc, emPreserve)
      check "(type)" in text
      check text.count("(type)") == 1   # no doubling
      let r2 = parse(text, preserveFormat = true)
      check r2.isOk
      if r2.isOk:
        check docEqual(doc, r2.get)

suite "trivia preservation — malformed-span fallback (regression)":
  # Test the structural guarantee of the forward-walk emit: spans that
  # don't satisfy the walk's monotonicity invariants (out-of-order,
  # overlapping, out-of-range, past sourceText.len) fall the encoder
  # back to canonical instead of silently producing corrupt output.
  #
  # Historical context: pre-forward-walk, emPreserve did in-place
  # splicing into a buffer derived from doc.sourceText. Span offsets
  # came from the parser against the ORIGINAL sourceText length, but
  # the buffer's length changed as earlier splices fired — and Nim's
  # string slicing on out-of-range bounds silently returns the wrong
  # substring (empty for negative high, full string for over-range)
  # rather than crashing. That made malformed-span corruption invisible.
  # Six rounds of code review chased the bug-class across six sites.
  #
  # The forward-walk architecture eliminates the bug class structurally
  # (reads from immutable sourceText, writes to append-only output) and
  # bounds-checks each cursor advance. Programmatically-constructed
  # ASTs with malformed spans — which a real fuzzer or future mutation
  # API can produce — now fall back cleanly. These tests pin that
  # contract.

  test "child span pointing past sourceText.len falls back to canonical":
    let r = parse("rule a=1 b=2", preserveFormat = true)
    check r.isOk
    var doc = r.get
    # Force the dirty branch: edit one entry so myHash != parseHash.
    doc.nodes[0].setProp(doc, "b", newIntValue(99))
    # Corrupt one entry's span to point past sourceText.len.
    let n = addr doc.nodes[0]
    n[].entries[0].span = initSpan(initPosition(100), initPosition(200))
    # Encode must not crash and must not silently splice junk.
    let text = encode(doc, emPreserve)
    # Canonical output: contains the edited "b=99" and the rule name.
    check "rule" in text
    check "b=99" in text
    # No phantom 200-byte slice from over-range bounds.
    check text.len < 200

  test "out-of-order entry spans fall back to canonical":
    let r = parse("rule a=1 b=2 c=3", preserveFormat = true)
    check r.isOk
    var doc = r.get
    doc.nodes[0].setProp(doc, "c", newIntValue(99))
    # Swap entry[0] and entry[1] spans so the walk sees out-of-order.
    let n = addr doc.nodes[0]
    let s0 = n[].entries[0].span
    n[].entries[0].span = n[].entries[1].span
    n[].entries[1].span = s0
    # Forward walk detects `s < cursor` on the second iteration and
    # falls back to canonical — no silent splice into stale offsets.
    let text = encode(doc, emPreserve)
    check "rule" in text
    check "c=99" in text

  test "zero-width span (start == finish) handled cleanly":
    let r = parse("rule a=1 b=2", preserveFormat = true)
    check r.isOk
    var doc = r.get
    doc.nodes[0].setProp(doc, "b", newIntValue(99))
    let n = addr doc.nodes[0]
    # Collapse entry[0]'s span to a zero-width point at offset 5.
    n[].entries[0].span = initSpan(initPosition(5), initPosition(5))
    let text = encode(doc, emPreserve)
    check "rule" in text
    check "b=99" in text

  test "top-level node span overshooting sourceText falls back":
    let r = parse("rule a=1\nother b=2\n", preserveFormat = true)
    check r.isOk
    var doc = r.get
    doc.nodes[1].setProp(doc, "b", newIntValue(99))
    # Corrupt the second top-level node's span to overshoot.
    doc.nodes[1].span = initSpan(initPosition(5),
                                  initPosition(doc.sourceText.len + 500))
    let text = encode(doc, emPreserve)
    check "rule" in text
    check "other" in text
    check "b=99" in text
    # No giant junk slice from the over-range bound.
    check text.len < doc.sourceText.len + 500
