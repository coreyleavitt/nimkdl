## Cycle 9'.1 — DocBuilder tracer. Proves the capability-driven visitor
## protocol can carry enough information for a visitor to reconstruct
## the same KdlDoc as the hand-written parser.nim.
##
## This is the safety-net cycle for cycle 10 (parser.nim refactor to be
## visitor-parameterized). If DocBuilder via parseDocumentWith produces
## structurally equivalent KdlDoc to parse(), the refactor is safe.
##
## Slice 1 scope: bare-ident node names, nested children (no annotations,
## no args, no props, no slashdash). Later slices extend coverage.

import std/[os, unittest]

import ../src/[ast, parser, doc_builder, typed_parser, spans]

const CorpusRoot = currentSourcePath.parentDir / "conformance" / "test_cases"

proc roundTrip(inputPath: string): tuple[viaParser, viaVisitor: KdlDoc] =
  let src = readFile(inputPath)
  let pRes = parse(src)
  doAssert pRes.isOk, "parser failed on " & inputPath & ": " & $pRes.getErr
  result.viaParser = pRes.get

  var builder = newDocBuilder(src, "test")
  let vRes = parseDocumentWith(src, builder)
  doAssert vRes.isOk, "visitor failed on " & inputPath & ": " & $vRes.getErr
  result.viaVisitor = builder.finish()

proc assertEquivalent(viaParser, viaVisitor: KdlDoc) =
  check viaParser.nodes.len == viaVisitor.nodes.len
  for i in 0 ..< viaParser.nodes.len:
    check nodeEqual(viaParser, viaVisitor,
                    viaParser.nodes[i], viaVisitor.nodes[i])

suite "DocBuilder tracer (cycle 9'.1)":

  test "single bare-ident node, no entries, no children":
    let src = "node\n"
    let pRes = parse(src)
    check pRes.isOk
    let viaParser = pRes.get

    var builder = newDocBuilder(src, "test")
    let vRes = parseDocumentWith(src, builder)
    check vRes.isOk
    let viaVisitor = builder.finish()

    assertEquivalent(viaParser, viaVisitor)

  test "multiple sibling nodes":
    let src = "alpha\nbeta\ngamma\n"
    let pRes = parse(src)
    check pRes.isOk
    var builder = newDocBuilder(src, "test")
    let vRes = parseDocumentWith(src, builder)
    check vRes.isOk
    assertEquivalent(pRes.get, builder.finish())

  test "single-level children":
    let src = "outer {\n  inner\n}\n"
    let pRes = parse(src)
    check pRes.isOk
    var builder = newDocBuilder(src, "test")
    let vRes = parseDocumentWith(src, builder)
    check vRes.isOk
    assertEquivalent(pRes.get, builder.finish())

  test "three-level nested children (conformance: nested_children.kdl)":
    let (viaP, viaV) = roundTrip(CorpusRoot / "input" / "nested_children.kdl")
    assertEquivalent(viaP, viaV)

  test "empty children block":
    let src = "node {\n}\n"
    let pRes = parse(src)
    check pRes.isOk
    var builder = newDocBuilder(src, "test")
    let vRes = parseDocumentWith(src, builder)
    check vRes.isOk
    assertEquivalent(pRes.get, builder.finish())

suite "DocBuilder type-annotation routing (cycle 9'.2)":

  test "node type annotation (type)node":
    let (viaP, viaV) = roundTrip(CorpusRoot / "input" / "node_type.kdl")
    assertEquivalent(viaP, viaV)

  test "arg value type annotation node (type)arg":
    let (viaP, viaV) = roundTrip(CorpusRoot / "input" / "arg_type.kdl")
    assertEquivalent(viaP, viaV)

  test "prop value type annotation node key=(type)#true":
    let (viaP, viaV) = roundTrip(CorpusRoot / "input" / "prop_type.kdl")
    assertEquivalent(viaP, viaV)

  test "arg string with type annotation":
    let (viaP, viaV) = roundTrip(CorpusRoot / "input" / "arg_string_type.kdl")
    assertEquivalent(viaP, viaV)

suite "DocBuilder quoted/raw node + prop names (cycle 9'.3)":

  test "quoted node name \"0node\"":
    let (viaP, viaV) = roundTrip(CorpusRoot / "input" / "quoted_node_name.kdl")
    assertEquivalent(viaP, viaV)

  test "raw-string node name #\"\\node\"#":
    let (viaP, viaV) = roundTrip(CorpusRoot / "input" / "raw_node_name.kdl")
    assertEquivalent(viaP, viaV)

  test "quoted node type annotation (\"type/\")node":
    let (viaP, viaV) = roundTrip(CorpusRoot / "input" / "quoted_node_type.kdl")
    assertEquivalent(viaP, viaV)

  test "quoted prop name \"0prop\"=val":
    let (viaP, viaV) = roundTrip(CorpusRoot / "input" / "quoted_prop_name.kdl")
    assertEquivalent(viaP, viaV)

suite "DocBuilder slashdash (cycle 9'.4)":

  test "/-node skips a top-level node":
    let (viaP, viaV) = roundTrip(CorpusRoot / "input" / "initial_slashdash.kdl")
    assertEquivalent(viaP, viaV)

  test "/- arg skips one prop in a node":
    let (viaP, viaV) = roundTrip(CorpusRoot / "input" / "slashdash_prop.kdl")
    assertEquivalent(viaP, viaV)

  test "/- {...} skips a children block":
    let (viaP, viaV) = roundTrip(CorpusRoot / "input" / "slashdash_child.kdl")
    assertEquivalent(viaP, viaV)

  test "/- {} skips an empty children block":
    let (viaP, viaV) = roundTrip(CorpusRoot / "input" / "slashdash_empty_child.kdl")
    assertEquivalent(viaP, viaV)

  test "/- node inside a children block":
    let (viaP, viaV) = roundTrip(CorpusRoot / "input" / "slashdash_node_in_child.kdl")
    assertEquivalent(viaP, viaV)

  test "/- node /- arg chains slashdashes (slashdash_in_slashdash)":
    let (viaP, viaV) = roundTrip(CorpusRoot / "input" / "slashdash_in_slashdash.kdl")
    assertEquivalent(viaP, viaV)

  test "slashdash interleaved with real children blocks":
    let (viaP, viaV) = roundTrip(CorpusRoot / "input" / "slashdash_multiple_child_blocks.kdl")
    assertEquivalent(viaP, viaV)

  test "/- arg=correct then /- arg=wrong (repeated-prop interaction)":
    let (viaP, viaV) = roundTrip(CorpusRoot / "input" / "slashdash_repeated_prop.kdl")
    assertEquivalent(viaP, viaV)

suite "DocBuilder reserved-bareword + keyword-as-key + bidi (cycle 9'.5)":

  proc bothReject(src: string) =
    let pRes = parse(src)
    check pRes.isErr
    var b = newDocBuilder(src, "test")
    let vRes = parseDocumentWith(src, b)
    check vRes.isErr

  test "true as bare prop key rejected (true_prop_key_fail)":
    bothReject(readFile(CorpusRoot / "input" / "true_prop_key_fail.kdl"))

  test "null as bare prop key rejected":
    bothReject(readFile(CorpusRoot / "input" / "null_prop_key_fail.kdl"))

  test "bare inf/-inf/nan as arg values rejected":
    bothReject(readFile(CorpusRoot / "input" / "floating_point_keyword_identifier_strings_fail.kdl"))

  test "true as bare node name rejected":
    bothReject("true\n")

  test "null as bare node name rejected":
    bothReject("null\n")

  test "tkKeyword #true used as prop key rejected":
    bothReject("node #true=1\n")

  test "bidi codepoint U+202E in quoted node name rejected":
    bothReject("\"a‮b\"\n")

  test "bidi codepoint in quoted prop key rejected":
    bothReject("node \"a‮b\"=1\n")

  test "bare-id with `true` PREFIX is accepted (trueish)":
    let (viaP, viaV) = roundTrip(CorpusRoot / "input" / "true_prefix_in_bare_id.kdl")
    assertEquivalent(viaP, viaV)

  test "bare-id with `null` PREFIX is accepted (nulled)":
    let (viaP, viaV) = roundTrip(CorpusRoot / "input" / "null_prefix_in_bare_id.kdl")
    assertEquivalent(viaP, viaV)
