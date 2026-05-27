## Cycle 9'.9 — full corpus equivalence sweep for DocBuilder.
##
## For every fixture in the kdl-org v2 conformance corpus:
## - Positive case (has expected_kdl/<case>): both parse() and
##   parseDocumentWith[DocBuilder] must accept, and the resulting
##   KdlDocs must be nodeEqual.
## - Negative case (no expected_kdl): both paths must reject.
##
## Cases listed in conformance/skips.txt (for the hand parser) are
## skipped here too — DocBuilder shares parser.nim's grammar coverage
## and inherits the same allowable deviations.
##
## Additional skips specific to the DocBuilder slice (e.g. features
## the visitor protocol doesn't yet route) live in
## conformance/skips_doc_builder.txt — a separate file so it's clear
## which deviations are DocBuilder-only.

import std/[algorithm, os, sets, strutils, unittest]

import ../src/[ast, doc_builder, parser, spans, typed_parser]

const CorpusRoot = currentSourcePath.parentDir / "conformance" / "test_cases"
const SkipsPath = currentSourcePath.parentDir / "conformance" / "skips.txt"
const DocBuilderSkipsPath =
  currentSourcePath.parentDir / "conformance" / "skips_doc_builder.txt"

proc loadSkips(path: string): HashSet[string] =
  result = initHashSet[string]()
  if not fileExists(path): return
  for line in readFile(path).splitLines():
    let s = line.strip()
    if s.len == 0 or s.startsWith('#'): continue
    let cut = s.find('|')
    let name = (if cut >= 0: s[0 ..< cut].strip() else: s)
    if name.len > 0:
      result.incl(name)

type
  CaseOutcome = enum
    coPass, coFail, coSkip
  CaseReport = object
    name: string
    outcome: CaseOutcome
    reason: string

proc evalCase(name, inputPath: string, expectedExists: bool): CaseReport =
  result.name = name
  let inputText = readFile(inputPath)
  let viaParser = parse(inputText)
  var b = newDocBuilder(inputText, name)
  let visitorRes = parseDocumentWith(inputText, b)

  if not expectedExists:
    # Negative case — both paths must reject.
    if viaParser.isErr and visitorRes.isErr:
      result.outcome = coPass
      return
    var bits: seq[string] = @[]
    if viaParser.isOk:   bits.add("parser accepted")
    if visitorRes.isOk:  bits.add("DocBuilder accepted")
    result.outcome = coFail
    result.reason = bits.join(", ") &
                    " — case has no expected_kdl so input must reject"
    return

  # Positive case.
  if viaParser.isErr:
    result.outcome = coFail
    result.reason = "parser rejected: " & viaParser.getErr.hint
    return
  if visitorRes.isErr:
    result.outcome = coFail
    result.reason = "DocBuilder rejected: " & visitorRes.getErr.hint
    return
  let viaVisitor = b.finish()
  if viaParser.get.nodes.len != viaVisitor.nodes.len:
    result.outcome = coFail
    result.reason = "top-level node count differs: parser=" &
                    $viaParser.get.nodes.len & " visitor=" &
                    $viaVisitor.nodes.len
    return
  for i in 0 ..< viaParser.get.nodes.len:
    if not nodeEqual(viaParser.get, viaVisitor,
                     viaParser.get.nodes[i], viaVisitor.nodes[i]):
      result.outcome = coFail
      result.reason = "structural mismatch at node[" & $i & "]"
      return
  result.outcome = coPass

suite "DocBuilder conformance equivalence (cycle 9'.9)":
  test "DocBuilder agrees with parser() on every corpus fixture":
    let parserSkips = loadSkips(SkipsPath)
    let docBuilderSkips = loadSkips(DocBuilderSkipsPath)
    let inputDir = CorpusRoot / "input"
    let expectedDir = CorpusRoot / "expected_kdl"

    var names: seq[string] = @[]
    for kind, path in walkDir(inputDir):
      if kind != pcFile: continue
      let n = path.extractFilename
      if not n.endsWith(".kdl"): continue
      names.add(n)
    names.sort()

    var passed = 0
    var failed: seq[CaseReport] = @[]
    var skipped = 0
    for n in names:
      if n in parserSkips or n in docBuilderSkips:
        inc skipped
        continue
      let inputPath = inputDir / n
      let expectedPath = expectedDir / n
      let r = evalCase(n, inputPath, fileExists(expectedPath))
      case r.outcome
      of coPass: inc passed
      of coFail: failed.add(r)
      of coSkip: inc skipped

    if failed.len > 0:
      echo "  Failures (showing first 10):"
      for r in failed[0 ..< min(10, failed.len)]:
        echo "    ", r.name, ": ", r.reason

    echo "  Total: ", names.len, " | Passed: ", passed,
         " | Failed: ", failed.len, " | Skipped: ", skipped
    check failed.len == 0
