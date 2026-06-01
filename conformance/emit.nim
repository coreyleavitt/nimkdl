## conformance/emit.nim — write the covering array(s) to the on-disk corpus.
##
## Turns the constructive generator into the shareable artifact (GH #27). Each
## covering-array row instantiates to ONE witness, written three ways from a
## single model:
##   input/NNN.kdl         — the surface text (what an implementation parses)
##   expected/NNN.json     — the neutral, precise oracle (exact-decimal numbers)
##   expected_kdl/NNN.kdl  — the kdl-org canonical form (drop-in superset compat)
## plus coverage-certificate.json — per interaction group, the strength and the
## production targets covered, with a `complete` flag (the gap-finder: the
## chosen rows must cover every required t-tuple).
##
## Deterministic: the covering array is a pure function of the group definition,
## so re-emitting is byte-stable. Clean-room — imports model/coverage/groups
## (and the stdlib), NOTHING from `../src`. Implementations consume the emitted
## corpus through their own adapter; they never appear here.

import std/[os, json, strutils, sets]
import ./model
import ./coverage
import ./groups
import ./negative

type
  Fixture* = object
    name*: string      ## zero-padded index, e.g. "007"
    input*: string     ## the input KDL text
    doc*: KDoc         ## the expected model

  GroupCert* = object
    name*: string
    strength*: int
    factors*: seq[string]
    targets*: int      ## required coverage targets (t-tuples)
    rows*: int         ## configurations chosen by the covering array
    complete*: bool    ## do the chosen rows cover every target?

  CorpusStats* = object
    fixtures*: int       ## positive (must-parse) fixtures
    negatives*: int      ## negative (must-reject) fixtures
    groups*: seq[GroupCert]

func nodeWitness(v: KValue): KDoc =
  ## Wrap a value-level witness as the minimal document `node <value>`.
  @[KNode(name: "node", entries: @[arg(v)])]

proc certify(g: InteractionGroup): GroupCert =
  ## Compute the coverage certificate for a group AND check completeness — the
  ## clean-room gap-finder: every required target must be covered by some row.
  let targets = coverTargets(g)
  let rows = coveringArray(g)
  var covered: HashSet[string]
  for r in rows:
    for sub in pairsOf(r, g.t): covered.incl canon(sub)
  var complete = true
  for t in targets:
    if canon(t) notin covered: complete = false
  GroupCert(name: g.name, strength: g.t,
            factors: block:
              var fs: seq[string]
              for f in g.factors: fs.add f.name
              fs,
            targets: targets.len, rows: rows.len, complete: complete)

proc buildFixtures*(): seq[Fixture] =
  ## The full corpus as in-memory fixtures: every value group's covering array,
  ## each row wrapped as `node <value>`. New groups join via `valueGroups()`.
  var idx = 0
  for (g, instantiate) in valueGroups():
    for row in coveringArray(g):
      let s = instantiate(row)
      result.add Fixture(name: intToStr(idx, 3),
                         input: "node " & s.text & "\n",
                         doc: nodeWitness(s.value))
      inc idx
  for (g, instantiate) in docGroups():
    for row in coveringArray(g):
      let s = instantiate(row)
      result.add Fixture(name: intToStr(idx, 3), input: s.text, doc: s.doc)
      inc idx

proc emitCorpus*(outDir: string): CorpusStats =
  ## Write the corpus to `outDir`, overwriting any prior contents. Returns stats
  ## (fixture count + per-group certificate).
  removeDir(outDir)
  createDir(outDir / "input")
  createDir(outDir / "expected")
  createDir(outDir / "expected_kdl")

  let fixtures = buildFixtures()
  for f in fixtures:
    writeFile(outDir / "input" / f.name & ".kdl", f.input)
    writeFile(outDir / "expected" / f.name & ".json", pretty(toJson(f.doc)) & "\n")
    writeFile(outDir / "expected_kdl" / f.name & ".kdl", canonicalKdlDoc(f.doc))

  var groups: seq[GroupCert]
  for (g, _) in valueGroups(): groups.add certify(g)
  for (g, _) in docGroups():   groups.add certify(g)
  var certJson = %*{
    "kdl_version": 2,
    "format": "nkdl-conformance/1",
    "fixtures": fixtures.len,
    "groups": newJArray(),
  }
  for gc in groups:
    certJson["groups"].add %*{
      "name": gc.name, "strength": gc.strength, "factors": gc.factors,
      "targets": gc.targets, "rows": gc.rows, "complete": gc.complete,
    }
  writeFile(outDir / "coverage-certificate.json", pretty(certJson) & "\n")

  # Negative (must-reject) corpus: one input file per fixture + a manifest
  # mapping each to the spec production it violates. No expected model —
  # rejection IS the expectation (the kdl-org convention for invalid cases).
  let negatives = negativeFixtures()
  createDir(outDir / "negative" / "input")
  var negMan = newJArray()
  for f in negatives:
    writeFile(outDir / "negative" / "input" / f.name & ".kdl", f.input)
    negMan.add %*{"name": f.name, "violates": f.violates}
  writeFile(outDir / "negative" / "manifest.json", pretty(negMan) & "\n")

  CorpusStats(fixtures: fixtures.len, negatives: negatives.len, groups: groups)

when isMainModule:
  let dir = "conformance/corpus"
  let stats = emitCorpus(dir)
  echo "emitted ", stats.fixtures, " positive + ", stats.negatives,
       " negative fixtures to ", dir
  for gc in stats.groups:
    echo "  group ", gc.name, " t=", gc.strength,
         " targets=", gc.targets, " rows=", gc.rows,
         " complete=", gc.complete
