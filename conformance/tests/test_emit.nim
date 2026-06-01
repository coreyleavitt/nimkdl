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
    let n = coveringArray(integerGroup()).len
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

  test "coverage certificate records the integer group at pairwise strength":
    let cert = parseJson(readFile(outDir / "coverage-certificate.json"))
    let g = cert["groups"][0]
    check g["name"].getStr == "integer"
    check g["strength"].getInt == 2
    check g["targets"].getInt > 0
    check g["rows"].getInt == stats.fixtures
    # gap-finder: the chosen rows cover every required target.
    check g["complete"].getBool

  test "re-emitting is byte-stable (deterministic corpus)":
    let a = readFile(outDir / "input" / "000.kdl")
    discard emitCorpus(outDir)
    check readFile(outDir / "input" / "000.kdl") == a
