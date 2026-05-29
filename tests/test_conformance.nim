## Conformance harness for the clean-core rebuild against the
## kdl-org v2 test corpus.
##
## Walks `tests/conformance/test_cases/input/` and for each case:
##
## 1. Parses via the hand parser
## 2. Parses via the reference interpreter
## 3. If an `expected_kdl/<case>` counterpart exists: both must
##    succeed, both must agree (`docEqual`), and
##    `parse(emitDoc(doc))` must round-trip to a `docEqual` result
##    (P4 — canonical-mode structural round-trip).
## 4. If no expected counterpart: both must reject the input.
##
## A second test sweep asserts P5 (preserve byte-exact):
##    `emitDocPreserve(parse(x, preserveFormat=true)) == x`.
##
## Cases listed in `skips.txt` are skipped with a one-line reason.
## Skips are deliberate deviations from spec; we want the skip count
## to be visible.

import std/[algorithm, os, sets, strutils, unittest]

import ../src/ast
import ../src/doc_emit
import ../src/emitter
import ../src/grammar
import ../src/parser
import ../src/spans

const CorpusRoot = currentSourcePath.parentDir / "conformance" / "test_cases"
const SkipsPath  = currentSourcePath.parentDir / "conformance" / "skips.txt"

proc loadSkips(): HashSet[string] =
  result = initHashSet[string]()
  if not fileExists(SkipsPath): return
  for line in readFile(SkipsPath).splitLines():
    let s = line.strip()
    if s.len == 0 or s.startsWith('#'): continue
    let cut = s.find('|')
    let name = (if cut >= 0: s[0 ..< cut].strip() else: s)
    if name.len > 0:
      result.incl(name)

proc emitCanonical(doc: KdlDoc): string =
  var e = newBufferEmitter()
  emitDoc(doc, e)
  e.finish()

proc emitPreserve(doc: KdlDoc): string =
  var e = newBufferEmitter()
  emitDocPreserve(doc, e)
  e.finish()

type
  CaseOutcome = enum
    coPass, coFail, coSkip

  CaseReport = object
    name: string
    outcome: CaseOutcome
    reason: string

proc evalCase(name, inputPath, expectedPath: string,
              expectedExists: bool): CaseReport =
  result.name = name
  let inputText = readFile(inputPath)

  let viaFast = parse(inputText, preserveFormat = true)
  let viaRef  = referenceInterpret(inputText)

  if not expectedExists:
    if viaFast.isErr and viaRef.isErr:
      result.outcome = coPass
      return
    var bits: seq[string] = @[]
    if viaFast.isOk: bits.add("hand parser accepted")
    if viaRef.isOk:  bits.add("reference interpreter accepted")
    result.outcome = coFail
    result.reason = bits.join(", ") &
                    " — case has no expected_kdl so input must reject"
    return

  if viaFast.isErr:
    result.outcome = coFail
    result.reason = "hand parser rejected: " & viaFast.getErr.hint
    return
  if viaRef.isErr:
    result.outcome = coFail
    result.reason = "reference interpreter rejected: " & viaRef.getErr.hint
    return
  if not docEqual(viaFast.get, viaRef.get):
    result.outcome = coFail
    result.reason = "hand parser and reference interpreter disagree"
    return

  let encoded = emitCanonical(viaFast.get)
  let reparsed = parse(encoded, preserveFormat = true)
  if reparsed.isErr:
    result.outcome = coFail
    result.reason = "canonical-emit output failed to re-parse: " &
                    reparsed.getErr.hint
    return
  if not docEqual(viaFast.get, reparsed.get):
    result.outcome = coFail
    result.reason = "emit→parse round-trip is not structurally equal"
    return

  let expectedText = readFile(expectedPath)
  let expectedDoc = parse(expectedText, preserveFormat = true)
  if expectedDoc.isErr:
    result.outcome = coFail
    result.reason = "could not parse corpus expected_kdl: " &
                    expectedDoc.getErr.hint
    return
  if not docEqual(viaFast.get, expectedDoc.get):
    result.outcome = coFail
    result.reason = "parsed input does not equal corpus expected_kdl"
    return

  result.outcome = coPass

suite "KDL v2 conformance corpus":
  test "corpus is vendored at the recorded SHA":
    let shaPath = CorpusRoot.parentDir / "CORPUS_SHA"
    check fileExists(shaPath)
    check readFile(shaPath).strip().len == 40

  test "P4 — every case passes (or is skipped with a documented reason)":
    let skips = loadSkips()
    var inputs: seq[string] = @[]
    for path in walkDir(CorpusRoot / "input"):
      if path.path.endsWith(".kdl"):
        inputs.add(path.path.extractFilename)
    inputs.sort()

    var pass, fail, skip = 0
    var firstFailures: seq[CaseReport] = @[]
    for name in inputs:
      if name in skips:
        inc skip
        continue
      let inPath  = CorpusRoot / "input" / name
      let expPath = CorpusRoot / "expected_kdl" / name
      let report = evalCase(name, inPath, expPath, fileExists(expPath))
      case report.outcome
      of coPass: inc pass
      of coFail:
        inc fail
        firstFailures.add(report)
      of coSkip: inc skip

    echo "conformance: ", pass, " pass, ", fail, " fail, ",
         skip, " skip (of ", inputs.len, " cases)"
    let dumpPath = currentSourcePath.parentDir /
                   ".last-conformance-failures.log"
    var buf = ""
    for r in firstFailures:
      buf.add(r.name & " | " & r.reason & "\n")
    if buf.len == 0:
      buf = "(no failures)\n"
    writeFile(dumpPath, buf)
    if firstFailures.len > 0:
      echo "  (full failure list at ", dumpPath, ")"
    for r in firstFailures[0 ..< min(10, firstFailures.len)]:
      echo "  FAIL ", r.name, " — ", r.reason

    check fail == 0

  test "P5 — emitDocPreserve(parse(x, preserveFormat=true)) == x":
    let skips = loadSkips()
    var inputs: seq[string] = @[]
    for path in walkDir(CorpusRoot / "input"):
      if path.path.endsWith(".kdl"):
        inputs.add(path.path.extractFilename)
    inputs.sort()

    var pass, fail, skip = 0
    var firstFailures: seq[string] = @[]
    for name in inputs:
      if name in skips:
        inc skip; continue
      let inPath  = CorpusRoot / "input" / name
      let expPath = CorpusRoot / "expected_kdl" / name
      if not fileExists(expPath):
        inc skip; continue
      let inputText = readFile(inPath)
      let r = parse(inputText, preserveFormat = true)
      if r.isErr:
        inc fail
        firstFailures.add(name & " | parse failed: " & r.getErr.hint)
        continue
      let preserved = emitPreserve(r.get)
      if preserved == inputText:
        inc pass
      else:
        inc fail
        firstFailures.add(name & " | byte-equivalence failed")
    echo "byte-equivalence: ", pass, " preserve, ", fail, " fail, ",
         skip, " skip (of ", inputs.len, " cases)"
    for r in firstFailures[0 ..< min(10, firstFailures.len)]:
      echo "  FAIL ", r
    check fail == 0
