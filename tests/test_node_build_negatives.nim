## test_node_build_negatives.nim — characterize the new builder's rejection gap.
##
## Negative kdl-org fixtures (input present, NO expected_kdl) must be rejected.
## The new builder rejects grammar errors via the cursor, but does NOT yet do
## semantic reserved-type validation (e.g. `(u8)256`) — that lands when reserved
## is ported to value.KdlValue. This test pins exactly which negatives the
## builder over-accepts so the gap is documented, not silent.

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

suite "node_build negatives — rejection gap characterization":
  test "report over-accepted negative fixtures":
    let skips = loadSkips()
    var negatives = 0
    var overAccepted: seq[string]
    for entry in walkDir(Root / "input"):
      if not entry.path.endsWith(".kdl"): continue
      let base = entry.path.extractFilename
      let stem = base[0 ..^ 5]
      if stem in skips: continue
      if fileExists(Root / "expected_kdl" / base): continue  # valid fixture
      inc negatives
      if parseNodes(readFile(entry.path)).isOk:
        overAccepted.add(stem)
    # The kdl-org negative corpus is entirely GRAMMAR violations, which the
    # cursor rejects — so the structural builder already rejects all of them.
    # Reserved-type SEMANTIC validation (u8 range, etc.) is a separate layer
    # (test_reserved_types) ported when reserved moves to value.KdlValue.
    if overAccepted.len > 0:
      checkpoint("over-accepted: " & overAccepted.join(", "))
    check negatives > 50
    check overAccepted.len == 0
