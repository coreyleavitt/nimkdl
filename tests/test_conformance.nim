## Conformance harness for lib/kdl against the kdl-org v2 test corpus.
##
## Walks `conformance/test_cases/input/` and for each case:
##
## 1. Parses via the hand parser
## 2. Parses via the reference interpreter
## 3. If an `expected_kdl/<case>` counterpart exists: both must succeed,
##    both must agree (docEqual), and `parse(encode(doc, preserveHashes = true))` must round-trip
##    to a `docEqual` result.
## 4. If no expected counterpart: both must reject the input.
##
## A case listed in `skips.txt` is skipped with a one-line reason logged
## to stdout. Skips are deliberate deviations from spec; we want the
## skip count to be visible.

import std/[algorithm, os, sets, strutils, unittest]

import ../src/ast
import ../src/encode
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

proc readKdl(path: string): string =
  if fileExists(path): readFile(path) else: ""

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

  let viaFast = parse(inputText, preserveHashes = true)
  let viaRef  = referenceInterpret(inputText)

  if not expectedExists:
    # Negative case — both interpreters must reject.
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

  # Positive case.
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

  # Round-trip through the encoder.
  let encoded = encode(viaFast.get)
  let reparsed = parse(encoded, preserveHashes = true)
  if reparsed.isErr:
    result.outcome = coFail
    result.reason = "encoder output failed to re-parse: " & reparsed.getErr.hint
    return
  if not docEqual(viaFast.get, reparsed.get):
    result.outcome = coFail
    result.reason = "encode→parse round-trip is not structurally equal"
    return

  # Also verify our encoded canonical form parses to the same shape as
  # the corpus's expected_kdl reference output. This is the strongest
  # check: it confirms we agree with the kdl-org reference on what
  # the canonical form should look like (structurally).
  let expectedText = readFile(expectedPath)
  let expectedDoc = parse(expectedText, preserveHashes = true)
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

  test "every case passes (or is skipped with a documented reason)":
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
        firstFailures.add(report)  # collect all; harness writes them out
      of coSkip: inc skip

    echo "conformance: ", pass, " pass, ", fail, " fail, ",
         skip, " skip (of ", inputs.len, " cases)"
    # Failure log lives at a project-relative path (Docker mounts the
    # project dir, so the host sees it). Write unconditionally — a
    # stale file from an earlier failing run would otherwise mislead
    # the developer after a green run.
    let dumpPath = currentSourcePath.parentDir / ".last-conformance-failures.log"
    var buf = ""
    for r in firstFailures:
      buf.add(r.name & " | " & r.reason & "\n")
    if buf.len == 0:
      buf = "(no failures)\n"
    writeFile(dumpPath, buf)
    if firstFailures.len > 0:
      echo "  (full failure list at ", dumpPath, ")"
    for r in firstFailures:
      echo "  FAIL ", r.name, " — ", r.reason

    check fail == 0

  test "byte-equivalence: encode(parse(x), emPreserve) == x":
    # Phase D of the trivia-preservation work. For every positive
    # corpus case (one with an `expected_kdl` companion), assert that
    # parsing the input and re-encoding it in `emPreserve` mode
    # produces the SAME bytes. This is a strict-superset property
    # over kdl-rs's preservation: every escape style, raw-string
    # `#`-count, dedent layout, number base, and bare-vs-quoted
    # choice survives.
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
        # Negative cases (input must reject) — no preservation to test.
        inc skip; continue
      let inputText = readFile(inPath)
      let r = parse(inputText, preserveHashes = true)
      if r.isErr:
        inc fail
        firstFailures.add(name & " | parse failed: " & r.getErr.hint)
        continue
      let preserved = encode(r.get, emPreserve)
      if preserved == inputText:
        inc pass
      else:
        inc fail
        firstFailures.add(name & " | byte-equivalence failed")
    echo "byte-equivalence: ", pass, " preserve, ", fail, " fail, ",
         skip, " skip (of ", inputs.len, " cases)"
    for r in firstFailures[0 ..< min(5, firstFailures.len)]:
      echo "  FAIL ", r
    check fail == 0
