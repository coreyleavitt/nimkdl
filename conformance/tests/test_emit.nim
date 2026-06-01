## conformance/tests/test_emit.nim — the on-disk corpus emitter (clean-room).
##
## E1: drive the covering array(s) into the shareable artifact. Each fixture is
## written three ways from ONE model — `input/NNN.kdl` (the surface),
## `expected/NNN.json` (the precise neutral oracle), `expected_kdl/NNN.kdl` (the
## kdl-org canonical form) — plus a `coverage-certificate.json` that records,
## per interaction group, the strength and the production targets covered. The
## corpus is deterministic (the covering array is), so re-emitting is byte-stable.

import std/[unittest, os, json, strutils]
import ../model
import ../coverage
import ../groups
import ../emit

suite "E1 — corpus emitter":

  let outDir = getTempDir() / "nkdl_conf_emit_test"
  let stats = emitCorpus(outDir)

  test "one fixture per covering-array row, written in all three projections":
    var n = 0
    for (g, _) in valueGroups(): n += coveringArray(g).len
    for (g, _) in docGroups():   n += coveringArray(g).len
    check stats.fixtures == n
    var inputFiles = 0
    for _ in walkFiles(outDir / "input" / "*.kdl"): inc inputFiles
    check inputFiles == n
    for i in 0 ..< n:
      let name = intToStr(i, 3)
      check fileExists(outDir / "input" / name & ".kdl")
      check fileExists(outDir / "expected" / name & ".json")
      check fileExists(outDir / "expected_kdl" / name & ".kdl")

  test "expected/NNN.json is a JSON array (a document of nodes)":
    let j = parseJson(readFile(outDir / "expected" / "000.json"))
    check j.kind == JArray
    check j.len == 1
    check j[0]["name"].getStr == "node"

  test "expected_kdl is the canonical projection of the same model":
    # Re-deriving the canonical text from the emitted JSON's source model must
    # match the emitted .kdl byte-for-byte (the projections agree by sharing one
    # model, not by coincidence).
    let row0 = coveringArray(integerGroup())[0]
    let s = instantiateInteger(row0)
    let doc: model.KDoc = @[KNode(name: "node", entries: @[arg(s.value)])]
    check readFile(outDir / "expected_kdl" / "000.kdl") == canonicalKdlDoc(doc)

  test "coverage certificate records each group at pairwise strength, complete":
    let cert = parseJson(readFile(outDir / "coverage-certificate.json"))
    var totalRows = 0
    for g in cert["groups"]:
      check g["strength"].getInt == 2
      check g["targets"].getInt > 0
      check g["complete"].getBool          # gap-finder: rows cover every target
      totalRows += g["rows"].getInt
    check totalRows == stats.fixtures        # every row becomes one fixture
    let names = block:
      var s: seq[string]
      for g in cert["groups"]: s.add g["name"].getStr
      s
    check "integer" in names and "float" in names

  test "negative corpus is emitted with a production-tagged manifest":
    check stats.negatives > 0
    let man = parseJson(readFile(outDir / "negative" / "manifest.json"))
    check man.len == stats.negatives
    for f in man:
      check fileExists(outDir / "negative" / "input" / f["name"].getStr & ".kdl")
      check f["violates"].getStr.len > 0      # every fixture cites a rule

  test "re-emitting is byte-stable (deterministic corpus)":
    let a = readFile(outDir / "input" / "000.kdl")
    discard emitCorpus(outDir)
    check readFile(outDir / "input" / "000.kdl") == a
