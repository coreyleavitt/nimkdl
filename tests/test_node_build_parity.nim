## test_node_build_parity.nim — metamorphic corpus parity for the new builder.
##
## `expected_kdl` is the canonical rendering of `input`; both denote the SAME
## KDL data model. So for every valid kdl-org fixture the self-contained builder
## must satisfy  parseNodes(input) == parseNodes(expected_kdl)  (node.`==`).
## This validates the strangler builder corpus-wide using only new code — no old
## parser, no JSON oracle. Negative fixtures (no expected_kdl) are a separate
## slice (they exercise reserved-type validation, not yet ported).

import std/[unittest, os, options, strutils, sets]
import ../src/node_build

const Conf = currentSourcePath.parentDir / "conformance"
const Root = Conf / "test_cases"

proc loadSkips(): HashSet[string] =
  for f in ["skips.txt", "skips_doc_builder.txt"]:
    let p = Conf / f
    if not fileExists(p): continue
    for line in readFile(p).splitLines():
      let s = line.strip()
      if s.len == 0 or s.startsWith("#"): continue
      var name = s
      let bar = s.find('|')
      if bar >= 0: name = s[0 ..< bar].strip()
      if name.endsWith(".kdl"): name = name[0 ..^ 5]
      result.incl(name)

suite "node_build parity — metamorphic over kdl-org corpus":
  test "parseNodes(input) == parseNodes(expected_kdl) for valid fixtures":
    let skips = loadSkips()
    var checked = 0
    var mism: seq[string]
    for entry in walkDir(Root / "input"):
      if not entry.path.endsWith(".kdl"): continue
      let base = entry.path.extractFilename
      let stem = base[0 ..^ 5]
      if stem in skips: continue
      let exp = Root / "expected_kdl" / base
      if not fileExists(exp): continue   # negative fixture — separate slice
      let ri = parseNodes(readFile(entry.path))
      let re = parseNodes(readFile(exp))
      if ri.isErr:
        mism.add(base & " input-rejected:" & $ri.getErr.code); continue
      if re.isErr:
        mism.add(base & " expected-rejected:" & $re.getErr.code); continue
      if ri.get != re.get:
        mism.add(base & " tree-mismatch")
      inc checked
    if mism.len > 0:
      checkpoint("DIVERGENCES (" & $mism.len & "/" & $(checked + mism.len) & "): " &
                 mism.join("  |  "))
    check checked > 150
    check mism.len == 0
