## conformance/tests/test_coverage.nim — clean-room covering-array engine (no nkdl).
##
## A1: the corpus's surface axis is covered by a *constrained* covering array —
## pairwise (t=2) within each grammar interaction group, with invalid cells
## excluded. The integer group is the tracer: factors base × hexcase × sign ×
## underscore, where `hexcase` only exists when `base = hex` (a real grammar
## constraint — there is no "uppercase" for a decimal number). A correct engine
## must therefore (a) include the valid pair (base=hex, hexcase=upper) and
## (b) EXCLUDE the impossible pair (base=dec, hexcase=upper).

import std/[unittest, algorithm, sequtils]
import ../coverage

proc integerGroup(): InteractionGroup =
  ## base{dec,hex,oct,bin} × hexcase{lower,upper,∅} × sign{none,plus,minus}
  ## × underscore{yes,no}, t=2, constrained: hexcase present ⇔ base=hex.
  InteractionGroup(
    name: "integer",
    t: 2,
    factors: @[
      Factor(name: "int.base",       levels: @["dec", "hex", "oct", "bin"]),
      Factor(name: "int.hexcase",    levels: @["lower", "upper", ""]),  # "" = absent
      Factor(name: "int.sign",       levels: @["none", "plus", "minus"]),
      Factor(name: "int.underscore", levels: @["yes", "no"]),
    ],
    valid: proc(c: Tagset): bool =
      let hex = lvl(c, "int.base") == "hex"
      let caseSet = lvl(c, "int.hexcase") != ""
      hex == caseSet)

proc target(pairs: varargs[Assignment]): string =
  canon(@pairs)

suite "A1 — constrained covering array (integer group)":

  test "includes a valid constrained pair: (base=hex, hexcase=upper)":
    let ts = coverTargets(integerGroup()).mapIt(canon(it))
    check target(("int.base", "hex"), ("int.hexcase", "upper")) in ts

  test "EXCLUDES the impossible pair: (base=dec, hexcase=upper)":
    let ts = coverTargets(integerGroup()).mapIt(canon(it))
    check target(("int.base", "dec"), ("int.hexcase", "upper")) notin ts
    check target(("int.base", "oct"), ("int.hexcase", "lower")) notin ts

  test "includes an unconstrained cross pair: (base=dec, sign=minus)":
    let ts = coverTargets(integerGroup()).mapIt(canon(it))
    check target(("int.base", "dec"), ("int.sign", "minus")) in ts

  test "every target is a t-tuple of distinct factors, no absent levels":
    for tgt in coverTargets(integerGroup()):
      check tgt.len == 2
      check tgt.allIt(it.level != "")
      let factors = tgt.mapIt(it.factor)
      check factors.sorted == factors.deduplicate.sorted  # distinct factors

suite "A2 — greedy covering array over the integer group":

  test "the array covers every required target":
    let g = integerGroup()
    let rows = coveringArray(g)
    var covered: seq[string]
    for r in rows:
      for sub in pairsOf(r, g.t): covered.add canon(sub)
    for tgt in coverTargets(g):
      check canon(tgt) in covered

  test "every row is a valid full configuration":
    let g = integerGroup()
    for r in coveringArray(g):
      check g.valid(r)
      check r.len == g.factors.len     # full: one assignment per factor

  test "the array is smaller than brute-forcing every configuration":
    let g = integerGroup()
    check coveringArray(g).len < coverTargets(g).len

  test "construction is deterministic":
    let g = integerGroup()
    check coveringArray(g).mapIt(canon(it)) == coveringArray(g).mapIt(canon(it))
