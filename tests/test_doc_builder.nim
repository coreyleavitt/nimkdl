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

  var builder = newDocBuilder("test")
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

    var builder = newDocBuilder("test")
    let vRes = parseDocumentWith(src, builder)
    check vRes.isOk
    let viaVisitor = builder.finish()

    assertEquivalent(viaParser, viaVisitor)

  test "multiple sibling nodes":
    let src = "alpha\nbeta\ngamma\n"
    let pRes = parse(src)
    check pRes.isOk
    var builder = newDocBuilder("test")
    let vRes = parseDocumentWith(src, builder)
    check vRes.isOk
    assertEquivalent(pRes.get, builder.finish())

  test "single-level children":
    let src = "outer {\n  inner\n}\n"
    let pRes = parse(src)
    check pRes.isOk
    var builder = newDocBuilder("test")
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
    var builder = newDocBuilder("test")
    let vRes = parseDocumentWith(src, builder)
    check vRes.isOk
    assertEquivalent(pRes.get, builder.finish())
