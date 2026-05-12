## Tests for encode.nim — pretty + compact output, identifier quoting,
## string escaping, number formatting, and full round-trip parse→encode→parse.

import std/[strutils, unittest]

import ../src/ast
import ../src/encode
import ../src/parser
import ../src/spans

template parseGet(src: string, doc: untyped, body: untyped) =
  let res = parse(src)
  if res.isErr:
    checkpoint("unexpected parse error: " & res.getErr.hint)
    fail()
  else:
    let doc {.inject.} = res.get
    body

template roundTrip(src: string, body: untyped) =
  ## Parse, encode, re-parse, assert structural equality. Body has
  ## both `original` and `roundtripped` injected for further checks.
  let r1 = parse(src)
  check r1.isOk
  if r1.isOk:
    let original {.inject.} = r1.get
    let encoded {.inject.} = encode(original, emPretty)
    let r2 = parse(encoded)
    check r2.isOk
    if r2.isOk:
      let roundtripped {.inject.} = r2.get
      check docEqual(original, roundtripped)
      body

suite "encode: identifiers":
  test "simple ident emits bare":
    parseGet("rule", doc):
      check encode(doc, emPretty) == "rule\n"

  test "ident with hyphen emits bare":
    parseGet("my-rule", doc):
      check encode(doc, emPretty) == "my-rule\n"

  test "ident starting with digit-like content gets quoted on output":
    # `123-foo` is a valid bare ident in KDL v2 but our conservative
    # encoder quotes anything starting with a digit. Round-trip via
    # quoted-ident must still parse equivalently.
    var doc = newDoc()
    var n = doc.newNode("123-foo")
    doc.nodes.add(n)
    let s = encode(doc, emPretty)
    check "\"123-foo\"" in s
    # And re-parse stability
    let r = parse(s)
    check r.isOk
    check docEqual(doc, r.get)

  test "reserved barewords get quoted":
    var doc = newDoc()
    doc.nodes.add(doc.newNode("true"))
    let s = encode(doc, emPretty)
    check s.startsWith("\"true\"")

suite "encode: values":
  test "string value (canonical bare form when possible)":
    parseGet("rule \"hello\"", doc):
      # KDL v2 canonical: "hello" is a valid bare ident and string-value,
      # so it emits unquoted. Round-trip stability covers the equivalence.
      check "rule hello" in encode(doc, emPretty)

  test "string value forces quote when bareword-unsafe":
    parseGet("rule \"has space\"", doc):
      check "\"has space\"" in encode(doc, emPretty)

  test "string with escapes":
    parseGet("rule \"a\\nb\"", doc):
      let s = encode(doc, emPretty)
      check "\\n" in s

  test "int value":
    parseGet("size 42", doc):
      check " 42" in encode(doc, emPretty)

  test "float value":
    parseGet("ratio 0.5", doc):
      check "0.5" in encode(doc, emPretty)

  test "bool values":
    parseGet("flags a=#true b=#false", doc):
      let s = encode(doc, emPretty)
      check "a=#true" in s
      check "b=#false" in s

  test "null value":
    parseGet("v #null", doc):
      check "#null" in encode(doc, emPretty)

  test "hex literal normalizes to decimal":
    parseGet("mask 0xFF", doc):
      let s = encode(doc, emPretty)
      check " 255" in s
      check "0x" notin s

  test "octal literal normalizes to decimal":
    parseGet("perm 0o755", doc):
      let s = encode(doc, emPretty)
      check " 493" in s

  test "binary literal normalizes to decimal":
    parseGet("flags 0b1010", doc):
      let s = encode(doc, emPretty)
      check " 10" in s

  test "underscore separators stripped":
    parseGet("n 1_000_000", doc):
      check "1000000" in encode(doc, emPretty)

  test "Inf / -Inf / NaN use keyword form":
    parseGet("specials a=#inf b=#-inf c=#nan", doc):
      let s = encode(doc, emPretty)
      check "#inf" in s
      check "#-inf" in s
      check "#nan" in s

suite "encode: type annotations":
  test "preserved on values":
    parseGet("size (u32)1024", doc):
      check "(u32)1024" in encode(doc, emPretty)

  test "preserved on nodes":
    parseGet("(version)rule", doc):
      check "(version)rule" in encode(doc, emPretty)

  test "preserved on property values":
    parseGet("config max=(seconds)30", doc):
      check "max=(seconds)30" in encode(doc, emPretty)

suite "encode: pretty layout":
  test "nested children indent":
    parseGet("outer { inner }", doc):
      let s = encode(doc, emPretty)
      check "    inner" in s
      check "}\n" in s

  test "deeply nested indents by 4 spaces per level":
    parseGet("a { b { c } }", doc):
      let s = encode(doc, emPretty)
      check "        c" in s   # 2 levels deep = 8 spaces

suite "encode: compact layout":
  test "no indentation":
    parseGet("outer { inner }", doc):
      let s = encode(doc, emCompact)
      check "\n" notin s
      check "outer {inner}" in s

  test "sibling nodes separated by semicolons":
    parseGet("a; b; c", doc):
      check encode(doc, emCompact) == "a; b; c"

  test "compact mode preserves children separator":
    parseGet("p { a; b; c }", doc):
      let s = encode(doc, emCompact)
      check "p {a; b; c}" == s

suite "encode: round-trip stability":
  test "simple node":
    roundTrip("rule"):
      discard

  test "node with mixed entries":
    roundTrip("rule \"id\" a=1 b=#true 42"):
      discard

  test "nested children":
    roundTrip("outer {\n  middle {\n    inner 42\n  }\n}"):
      discard

  test "realistic rule fragment":
    let src = """
rule "compaction" {
  enabled #true
  action "inject" {
    template "context pressure rising"
  }
}
"""
    roundTrip(src):
      check original.nodes.len == 1

  test "compact mode round-trips too":
    let r1 = parse("a 1 b=2 { c }")
    check r1.isOk
    let s = encode(r1.get, emCompact)
    let r2 = parse(s)
    check r2.isOk
    check docEqual(r1.get, r2.get)

suite "encode: edge cases":
  test "empty doc emits empty string":
    let doc = newDoc()
    check encode(doc, emPretty) == ""
    check encode(doc, emCompact) == ""

  test "node with no entries or children":
    parseGet("naked", doc):
      check encode(doc, emPretty) == "naked\n"

  test "empty children block round-trips":
    roundTrip("rule {\n}"):
      discard

suite "encode: big integers (slice-6, kvBigInt)":
  test "hex literal exceeding int64.high but fitting uint64":
    # Spec corpus hex.kdl: 0xabcdef1234567890 = 12379813812177893520
    parseGet("node 0xabcdef1234567890", doc):
      let output = encode(doc, emPretty)
      check output == "node 12379813812177893520\n"

  test "hex literal exceeding uint64.high (true 128-bit value)":
    # Spec corpus hex_int.kdl: 0xABCDEF0123456789abcdef
    #                                = 207698809136909011942886895
    parseGet("node 0xABCDEF0123456789abcdef", doc):
      let output = encode(doc, emPretty)
      check output == "node 207698809136909011942886895\n"

  test "decimal that overflows int64 promotes to kvBigInt":
    parseGet("node 12379813812177893520", doc):
      let output = encode(doc, emPretty)
      check output == "node 12379813812177893520\n"
