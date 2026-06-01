## conformance/coverage.nim — constrained covering-array engine (clean-room).
##
## The corpus's SURFACE axis (how a value/structure is written: number base,
## sign, underscores, string style, trivia, slashdash, …) is covered by a
## *constrained covering array*: pairwise (t=2) interaction coverage WITHIN each
## grammar interaction group, with invalid cells excluded. This is the
## best-in-class criterion (NIST interaction rule: ≤2-factor interactions
## trigger the large majority of faults) scoped to where the grammar actually
## couples factors — far cheaper than blind pairwise over all factors, far
## stronger than independent single-factor coverage.
##
## A group declares factors (each with a level domain; a `""` level means "this
## factor is absent in this configuration") plus a strength `t` and a validity
## predicate encoding constraints (e.g. a number's hex-case only exists when the
## base is hex). The required coverage targets are every distinct t-tuple of
## present (non-absent) assignments that appears in SOME valid full
## configuration — so impossible combinations are never demanded.
##
## Imports only the stdlib — NOTHING from `../src`.

import std/[algorithm, sets]

type
  Assignment* = tuple[factor: string, level: string]
    ## One (factor, level) choice. `level == ""` denotes the factor being absent.
  Tagset* = seq[Assignment]
    ## A (partial or full) configuration: at most one level per factor.
  Factor* = object
    name*: string
    levels*: seq[string]   ## level domain; may include `""` for "absent"
  InteractionGroup* = object
    name*: string
    factors*: seq[Factor]
    t*: int                ## interaction strength (2 = pairwise)
    valid*: proc(c: Tagset): bool {.closure.}  ## constraint over a FULL config
  Target* = Tagset
    ## A required coverage target: a t-tuple of present assignments.

func lvl*(c: Tagset, factor: string): string =
  ## The level `c` assigns to `factor`, or `""` if unassigned/absent.
  for a in c:
    if a.factor == factor: return a.level
  ""

func canon*(t: Target): string =
  ## Canonical, order-independent key for a target (sorted by factor).
  var xs = t
  xs.sort(proc(a, b: Assignment): int = cmp(a.factor, b.factor))
  for a in xs:
    if result.len > 0: result.add '\x1f'
    result.add a.factor & '=' & a.level

func present*(c: Tagset): Tagset =
  ## The non-absent assignments of `c`.
  for a in c:
    if a.level != "": result.add a

proc fullConfigs(g: InteractionGroup): seq[Tagset] =
  ## Every full configuration (cartesian product of factor levels) that
  ## satisfies the group's validity predicate.
  var configs: seq[Tagset] = @[@[]]
  for f in g.factors:
    var nxt: seq[Tagset]
    for c in configs:
      for lv in f.levels:
        nxt.add c & (factor: f.name, level: lv)
    configs = nxt
  for c in configs:
    if g.valid.isNil or g.valid(c): result.add c

proc combinations[T](xs: seq[T], k: int): seq[seq[T]] =
  ## All k-element combinations of `xs` (order preserved, no repeats).
  if k == 0: return @[newSeq[T]()]
  if xs.len < k: return @[]
  let head = xs[0]
  let rest = xs[1 .. ^1]
  for c in combinations(rest, k - 1): result.add head & c
  for c in combinations(rest, k):     result.add c

proc pairsOf*(c: Tagset, t: int): seq[Target] =
  ## The t-tuples of present assignments that configuration `c` covers.
  combinations(present(c), t)

proc coverTargets*(g: InteractionGroup): seq[Target] =
  ## Every distinct t-tuple of present assignments realizable by some valid full
  ## configuration of the group. Impossible (constraint-violating) tuples never
  ## appear, because they appear in no valid configuration.
  var seen: HashSet[string]
  for c in fullConfigs(g):
    for sub in pairsOf(c, g.t):
      let k = canon(sub)
      if k notin seen:
        seen.incl k
        result.add sub

proc coveringArray*(g: InteractionGroup): seq[Tagset] =
  ## A small set of valid full configurations whose union of covered t-tuples is
  ## every required target. Greedy set-cover: repeatedly take the configuration
  ## covering the most still-uncovered targets. Deterministic (candidate order
  ## is the fixed cartesian-product order; ties resolve to the first index) and
  ## near-optimal — good enough while groups are small; IPOG is the drop-in
  ## upgrade if a group's configuration space ever grows too large to enumerate.
  var uncovered: HashSet[string]
  for t in coverTargets(g): uncovered.incl canon(t)
  let candidates = fullConfigs(g)
  var covSets: seq[HashSet[string]]
  for c in candidates:
    var s: HashSet[string]
    for sub in pairsOf(c, g.t): s.incl canon(sub)
    covSets.add s
  while uncovered.len > 0:
    var bestI = -1
    var bestGain = 0
    for i in 0 ..< candidates.len:
      var gain = 0
      for k in covSets[i]:
        if k in uncovered: inc gain
      if gain > bestGain:
        bestGain = gain; bestI = i
    doAssert bestI >= 0, "covering array: a target is unreachable by any config"
    result.add candidates[bestI]
    for k in covSets[bestI]: uncovered.excl k
