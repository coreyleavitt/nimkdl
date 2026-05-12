## Tests for parser.nim — single nodes, attributes, children, slashdash,
## type annotations, and structural errors.

import std/[strutils, unittest]

import ../src/ast
import ../src/intern
import ../src/parser
import ../src/spans

template parseOk(src: string, body: untyped) =
  ## Parse `src`, fail the test on Err, bind `doc` for the body.
  let res = parse(src)
  if res.isErr:
    checkpoint("unexpected parse error: " & res.getErr.hint)
    fail()
  else:
    let doc {.inject.} = res.get
    body

template parseErrCheck(src: string, expectedCode: ParseErrorCode) =
  let res = parse(src)
  check res.isErr
  if res.isErr:
    check res.getErr.code == expectedCode

# Helper: resolve a node's name as a string
proc nameOf(doc: KdlDoc, n: KdlNode): string =
  doc.interner.lookup(n.name)

suite "parser: empty + trivial":
  test "empty source produces empty doc":
    parseOk(""):
      check doc.nodes.len == 0

  test "blank lines only produce empty doc":
    parseOk("\n\n\n"):
      check doc.nodes.len == 0

  test "single bare node":
    parseOk("rule"):
      check doc.nodes.len == 1
      check nameOf(doc, doc.nodes[0]) == "rule"

  test "two nodes separated by newline":
    parseOk("a\nb"):
      check doc.nodes.len == 2
      check nameOf(doc, doc.nodes[0]) == "a"
      check nameOf(doc, doc.nodes[1]) == "b"

  test "two nodes separated by semicolon":
    parseOk("a; b"):
      check doc.nodes.len == 2

  test "trailing line-continuation at EOF parses cleanly":
    # Spec corpus eof_after_escape.kdl: `node \<EOF>` (no newline).
    # Line continuation at EOF is a valid terminator — an implicit empty
    # line after the document. Equivalent to `node` followed by EOL.
    parseOk("node \\"):
      check doc.nodes.len == 1
      check nameOf(doc, doc.nodes[0]) == "node"
      check doc.nodes[0].entries.len == 0

suite "parser: arguments":
  test "node with string argument":
    parseOk("rule \"compaction\""):
      let n = doc.nodes[0]
      check n.entries.len == 1
      check n.entries[0].kind == keArgument
      check n.entries[0].argValue.strVal == "compaction"

  test "node with number argument":
    parseOk("limit 42"):
      let n = doc.nodes[0]
      check n.entries[0].argValue.kind == kvInt
      check n.entries[0].argValue.intVal == 42

  test "node with float argument":
    parseOk("ratio 0.75"):
      let n = doc.nodes[0]
      check n.entries[0].argValue.kind == kvFloat
      check n.entries[0].argValue.floatVal == 0.75

  test "node with negative int":
    parseOk("offset -7"):
      let n = doc.nodes[0]
      check n.entries[0].argValue.kind == kvInt
      check n.entries[0].argValue.intVal == -7

  test "hex literal decodes":
    parseOk("mask 0xFF"):
      check doc.nodes[0].entries[0].argValue.intVal == 0xFF

  test "octal literal decodes":
    parseOk("perm 0o755"):
      check doc.nodes[0].entries[0].argValue.intVal == 0o755

  test "binary literal decodes":
    parseOk("flags 0b1010"):
      check doc.nodes[0].entries[0].argValue.intVal == 10

  test "keywords decode to values":
    parseOk("config a=#true b=#false c=#null"):
      let n = doc.nodes[0]
      check n.entries[0].propValue.boolVal
      check not n.entries[1].propValue.boolVal
      check n.entries[2].propValue.kind == kvNull

  test "multiple args in source order":
    parseOk("range 1 2 3"):
      let n = doc.nodes[0]
      var args: seq[int64] = @[]
      for a in n.arguments:
        args.add(a.intVal)
      check args == @[1'i64, 2'i64, 3'i64]

suite "parser: properties":
  test "single property":
    parseOk("rule enabled=#true"):
      let n = doc.nodes[0]
      check n.entries.len == 1
      check n.entries[0].kind == keProperty
      check doc.interner.lookup(n.entries[0].propName) == "enabled"
      check n.entries[0].propValue.boolVal

  test "multiple properties in source order":
    parseOk("config a=1 b=2 c=3"):
      let n = doc.nodes[0]
      var keys: seq[string] = @[]
      for (k, _) in n.properties:
        keys.add(doc.interner.lookup(k))
      check keys == @["a", "b", "c"]

  test "mixed args and props":
    parseOk("rule \"id\" enabled=#true 42"):
      let n = doc.nodes[0]
      check n.entries.len == 3
      check n.entries[0].kind == keArgument
      check n.entries[1].kind == keProperty
      check n.entries[2].kind == keArgument

suite "parser: children":
  test "single child":
    parseOk("rule {\n  action \"inject\"\n}"):
      let n = doc.nodes[0]
      check n.children.len == 1
      check nameOf(doc, n.children[0]) == "action"

  test "multiple children":
    parseOk("rule {\n  a\n  b\n  c\n}"):
      let n = doc.nodes[0]
      check n.children.len == 3

  test "nested children":
    parseOk("outer {\n  middle {\n    inner\n  }\n}"):
      check doc.nodes.len == 1
      check doc.nodes[0].children.len == 1
      check doc.nodes[0].children[0].children.len == 1

  test "empty children block":
    parseOk("rule {}"):
      check doc.nodes[0].children.len == 0

suite "parser: slashdash":
  test "slashdash on node skips it":
    parseOk("/- skipped\nkept"):
      check doc.nodes.len == 1
      check nameOf(doc, doc.nodes[0]) == "kept"

  test "slashdash on entry skips just the entry":
    parseOk("rule /- skipped=1 kept=2"):
      let n = doc.nodes[0]
      check n.entries.len == 1
      check doc.interner.lookup(n.entries[0].propName) == "kept"

  test "slashdash on children block skips block":
    # Slashdashed children block, then a sibling node — no entries may
    # follow the block (spec corpus slashdash_child_block_before_entry).
    parseOk("rule /- {\n  hidden\n}\nsibling visible=#true"):
      let n = doc.nodes[0]
      check nameOf(doc, n) == "rule"
      check n.children.len == 0
      check n.entries.len == 0
      check doc.nodes.len == 2
      check nameOf(doc, doc.nodes[1]) == "sibling"

  test "multiple slashdashed children blocks around a real one":
    # Spec corpus slashdash_multiple_child_blocks.kdl: entries followed
    # by any mix of real and slashdashed children blocks; only the real
    # block's children survive.
    parseOk("node foo /-{\n    one\n} /-{\n    two\n} {\n    three\n} /-{\n    four\n}"):
      let n = doc.nodes[0]
      check nameOf(doc, n) == "node"
      check n.entries.len == 1  # only foo
      check n.children.len == 1
      check nameOf(doc, n.children[0]) == "three"

  test "slashdashed children block may abut preceding entry (no ws)":
    # Spec corpus zero_space_before_slashdash_children.kdl: `/-` (and the
    # `{` block it introduces) does not require whitespace before it.
    parseOk("node \"string\"/-{}"):
      check doc.nodes.len == 1
      check doc.nodes[0].entries.len == 1
      check doc.nodes[0].children.len == 0

  test "slashdashed children block may abut preceding real children":
    parseOk("node \"string\" {}/-{}"):
      check doc.nodes.len == 1
      check doc.nodes[0].entries.len == 1
      check doc.nodes[0].children.len == 0  # real {} was empty

suite "parser: token adjacency (G-token-adjacency)":
  test "node name directly abutted by string entry is rejected":
    # Spec corpus zero_space_before_first_arg_fail.kdl
    parseErrCheck("node\"string\"", peParseExpected)

  test "property value directly abutted by next property key is rejected":
    # Spec corpus zero_space_before_prop_fail.kdl
    parseErrCheck("node foo=\"value\"bar=5", peParseExpected)

  test "first entry directly abutted by next argument is rejected":
    # Spec corpus zero_space_before_second_arg_fail.kdl
    parseErrCheck("node \"string\"1", peParseExpected)

suite "parser: residual slashdash entry-position check":
  test "entry after slashdashed children block is rejected":
    # Spec corpus slashdash_child_block_before_entry_err_fail.kdl: once
    # any children block (real or slashdashed) is consumed, no more
    # entries are allowed.
    parseErrCheck("node /-{\n    child\n} foo {\n    bar\n}",
                  peParseUnexpected)

suite "parser: type annotations":
  test "type annotation on node":
    parseOk("(version)rule"):
      let n = doc.nodes[0]
      check doc.interner.lookup(n.typeAnnotation) == "version"

  test "type annotation on value":
    parseOk("size (u32)1024"):
      let v = doc.nodes[0].entries[0].argValue
      check doc.interner.lookup(v.typeAnnotation) == "u32"

  test "type annotation on property value":
    parseOk("config max=(seconds)30"):
      let v = doc.nodes[0].entries[0].propValue
      check doc.interner.lookup(v.typeAnnotation) == "seconds"

suite "parser: realistic":
  test "rule fragment":
    let src = """
rule "compaction" {
  enabled #true
  action "inject" {
    template "context pressure rising"
  }
}
"""
    parseOk(src):
      check doc.nodes.len == 1
      let rule = doc.nodes[0]
      check nameOf(doc, rule) == "rule"
      check rule.entries[0].argValue.strVal == "compaction"
      check rule.children.len == 2
      check nameOf(doc, rule.children[0]) == "enabled"
      let act = rule.children[1]
      check nameOf(doc, act) == "action"
      check act.entries[0].argValue.strVal == "inject"
      check act.children.len == 1
      check act.children[0].entries[0].argValue.strVal ==
            "context pressure rising"

suite "parser: error reporting":
  test "unclosed children block":
    parseErrCheck("rule {\n  child\n", peParseExpected)

  test "lexer error surfaces":
    parseErrCheck("\"unterminated", peLexUnterminatedString)

  test "missing node name after type annotation":
    parseErrCheck("(t) ", peParseExpected)

  test "depth limit triggers diagnostic":
    var src = ""
    for _ in 0 .. MaxParserDepth + 2:
      src.add("a {\n")
    for _ in 0 .. MaxParserDepth + 2:
      src.add("}\n")
    parseErrCheck(src, peParseDepthExceeded)

suite "parser: number literal edges (C1, C2)":
  test "int64.high decodes":
    parseOk("v 9223372036854775807"):
      check doc.nodes[0].entries[0].argValue.intVal == 9223372036854775807'i64

  test "int64.low decodes (regression: prior overflow guard rejected it)":
    parseOk("v -9223372036854775808"):
      # This is the headline C2 fix: previously rejected as
      # peLexInvalidNumber because the magnitude overflows when
      # accumulated in int64. Now correct via uint64 accumulator.
      check doc.nodes[0].entries[0].argValue.intVal == int64.low

  test "one past int64.high promotes to kvBigInt":
    parseOk("v 9223372036854775808"):
      let av = doc.nodes[0].entries[0].argValue
      check av.kind == kvBigInt
      check av.bigHi == 0
      check av.bigLo == uint64(int64.high) + 1'u64
      check not av.bigNegative

  test "one below int64.low promotes to kvBigInt (negative)":
    parseOk("v -9223372036854775809"):
      let av = doc.nodes[0].entries[0].argValue
      check av.kind == kvBigInt
      check av.bigHi == 0
      check av.bigLo == uint64(int64.high) + 2'u64
      check av.bigNegative

  test "huge hex literal (uint64.max) promotes to kvBigInt":
    parseOk("v 0xFFFFFFFFFFFFFFFF"):
      let av = doc.nodes[0].entries[0].argValue
      check av.kind == kvBigInt
      check av.bigHi == 0
      check av.bigLo == high(uint64)
      check not av.bigNegative

  test "literal exceeding 128 bits is rejected":
    parseErrCheck("v 0x10000000000000000_00000000000000000",
                  peLexInvalidNumber)

  test "malformed float (exponent without digits) is rejected":
    parseErrCheck("v 1.5e", peLexInvalidNumber)

  test "regular finite float decodes":
    parseOk("v 1.5e10"):
      check doc.nodes[0].entries[0].argValue.kind == kvFloat
      check doc.nodes[0].entries[0].argValue.floatVal == 1.5e10

suite "parser: round trip preserves structure":
  test "structural identity check via repr":
    # We don't have the encoder yet (#524); for now just verify that
    # parse → repr renders nontrivial output rather than crashing.
    parseOk("a 1 b=2 { c }"):
      let s = $doc
      check "a" in s
      check "1" in s
      check "b=2" in s
      check "c" in s
