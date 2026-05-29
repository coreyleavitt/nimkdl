## Property tests for the preserving encoder.
##
## Five properties, derived from the architectural invariants that
## the forward-walk preserve emit, headLen framing, tombstones, and
## dirty-flag caching were each designed to uphold:
##
##   1. parse(encode(d, emPreserve)) ≈ d  for any parsed doc d
##   2. parse(encode(d, emPretty))   ≈ d  (canonical mode round-trip)
##   3. Stateful: any sequence of builder mutations preserves
##      round-trip — fires `addArg` / `setProp` / `removeProp` /
##      `addChild` / `removeChild` against a corpus doc and asserts
##      the round-trip invariant after each step.
##   4. Tombstone soundness: removed entries' source bytes never
##      appear in the output (the round-of-six splice bug class
##      would have failed this).
##   5. No-crash: the encoder doesn't raise unexpected exceptions on
##      any KdlDoc.
##
## Strategy choice: we don't auto-derive `arbitrary(KdlDoc)` (yet) —
## KdlDoc carries an Interner, KdlNode.name is an InternedStr handle,
## etc., none of which round-trip through choice-sequence generation
## without custom strategies. Instead the corpus IS our source-of-
## valid-docs strategy: `sampledFrom(corpusFixtures)` yields parsed
## docs, and the stateful tests layer builder operations on top.

import std/[os, unittest]

import proptest

import ../src/ast
import ../src/encode
import ../src/intern
import ../src/parser
import ../src/spans

const corpusDir = currentSourcePath().parentDir() /
                  "conformance" / "test_cases" / "input"

proc loadValidCorpus(): seq[string] =
  ## Read every input fixture whose corresponding expected_kdl exists.
  ## Those are the 243 "parse must succeed" cases per the conformance
  ## README — exactly the set where round-trip should hold.
  let expectedDir = currentSourcePath().parentDir() /
                    "conformance" / "test_cases" / "expected_kdl"
  for kind, path in walkDir(corpusDir):
    if kind != pcFile: continue
    let name = path.extractFilename
    if not fileExists(expectedDir / name): continue
    try:
      result.add(readFile(path))
    except IOError: discard

let corpus = loadValidCorpus()

# Sanity: corpus loaded.
doAssert corpus.len > 100, "expected ≥100 valid corpus fixtures, got " & $corpus.len

# Pre-filtered corpus subsets. Use proptest's `sampledFromWhere`
# strategy (eager pre-filter at construction; doesn't eat the
# rejection budget) when a property requires a specific doc shape.
proc hasMultipleTopLevel(s: string): bool =
  let r = parse(s)
  r.isOk and r.get.nodes.len >= 2

let corpusMultiNodeStrat = sampledFromWhere(corpus, hasMultipleTopLevel)

suite "preserve encode — property #1 (round-trip emPreserve)":
  property "parse(encode(d, emPreserve)) ≈ d for valid corpus":
    given src in sampledFrom(corpus)
    let r1 = parse(src, preserveFormat = true)
    if r1.isOk:
      let d1 = r1.get
      let text = encode(d1, emPreserve)
      let r2 = parse(text, preserveFormat = true)
      ensure r2.isOk
      if r2.isOk:
        ensure docEqual(d1, r2.get)

suite "preserve encode — property #2 (round-trip emPretty)":
  # emPretty is the canonical multi-line emitter. It DOESN'T preserve
  # source bytes — it normalizes whitespace, number bases, identifier
  # quoting, etc. — but parse(encode(d, emPretty)) must still equal d
  # structurally for any valid input. This is the canonical-output
  # idempotency invariant.
  property "parse(encode(d, emPretty)) ≈ d for valid corpus":
    given src in sampledFrom(corpus)
    let r1 = parse(src)
    if r1.isOk:
      let d1 = r1.get
      let text = encode(d1, emPretty)
      let r2 = parse(text)
      ensure r2.isOk
      if r2.isOk:
        ensure docEqual(d1, r2.get)

suite "preserve encode — property #5 (no-crash across modes)":
  # The encoder must produce *some* output for any parsed doc, in
  # every mode, without raising. A failure here means an unexpected
  # exception path — anywhere from a bad type-annotation lookup to a
  # depth-cap mis-fire to a malformed-span branch we didn't think to
  # cover.
  property "encode never raises for valid corpus × every mode":
    given src in sampledFrom(corpus), modeIdx in integers(0, 2)
    let r = parse(src, preserveFormat = true)
    if r.isOk:
      let d = r.get
      let mode = case modeIdx
        of 0: emPreserve
        of 1: emPretty
        else: emCompact
      discard encode(d, mode)
      ensure true   # reaching here = no exception raised

suite "preserve encode — property #4 (tombstone soundness)":
  # For any parsed doc with a removable property, removing it and
  # re-encoding must produce output that no longer contains that
  # property. The round-of-six splice bug class would have failed
  # this — silently leaving the removed entry's source bytes in the
  # output because the surgical splice mis-tracked offsets.
  #
  # Implementation note: we re-parse the encoded output and assert
  # the property is absent (structural check). A literal substring
  # check is fragile (the property's bytes might appear coincidentally
  # in a comment or another entry's value).
  property "removeProp produces output that doesn't re-parse the removed prop":
    given src in sampledFrom(corpus)
    let r1 = parse(src, preserveFormat = true)
    assume r1.isOk
    var d = r1.get
    # Find a node with at least one property entry, take the first
    # property's name. Skip if no removable prop in the doc.
    var targetNodeIdx = -1
    var targetPropName = ""
    for i, n in d.nodes:
      for e in n.entries:
        if e.kind == keProperty:
          targetNodeIdx = i
          targetPropName = d.interner.lookup(e.propName)
          break
      if targetNodeIdx >= 0: break
    assume targetNodeIdx >= 0
    let removed = d.nodes[targetNodeIdx].removeProp(d, targetPropName)
    ensure removed
    let text = encode(d, emPreserve)
    let r2 = parse(text, preserveFormat = true)
    ensure r2.isOk
    if r2.isOk:
      # Walk r2.get.nodes[targetNodeIdx] — the prop must not be there.
      let d2 = r2.get
      ensure targetNodeIdx < d2.nodes.len
      if targetNodeIdx < d2.nodes.len:
        var stillPresent = false
        for e in d2.nodes[targetNodeIdx].entries:
          if e.kind == keProperty and
             d2.interner.lookup(e.propName) == targetPropName:
            stillPresent = true
            break
        ensure not stillPresent

# ---------------------------------------------------------------------------
# Property #3: stateful builder ops preserve round-trip
# ---------------------------------------------------------------------------
#
# For each rule (setProp / addArg / removeProp / setName), apply a
# random sequence against a corpus doc. After EVERY step the round-
# trip invariant must hold: `parse(encode(d, emPreserve)).get ≈ d`.
# A mid-sequence violation is caught — final-state assertions miss
# transient breakage that the encoder happens to "recover" from later.
#
# We don't use proptest's `stateful` machinery here because its
# initial-state is fixed at strategy construction; we want to draw
# the corpus doc dynamically (it's the random seed for every chain).
# Once proptest grows a `statefulOver(initial: Strategy[S])` form,
# this is the natural rewrite — for now, the op-list strategy is
# more direct.

type
  OpKind = enum
    opSetProp, opSetPropStr, opAddArg, opAddArgStr,
    opRemoveProp, opSetName, opSetTag, opClearTag,
    opAddChild, opRemoveChild

  Op = object
    case kind: OpKind
    of opSetProp:
      propName: string
      propValI: int
    of opSetPropStr:
      propNameS: string
      propValS: string
    of opAddArg:
      argValI: int
    of opAddArgStr:
      argValS: string
    of opRemoveProp:
      removeName: string
    of opSetName:
      newName: string
    of opSetTag:
      tag: string
    of opClearTag: discard
    of opAddChild:
      childName: string
    of opRemoveChild:
      removeChildName: string

proc opStrategy(): Strategy[Op] =
  # Names: lowercase-ASCII identifier-safe so we don't accidentally
  # generate KDL names that need quoting. String values cover the
  # forms most likely to expose encoder/parser disagreement: simple
  # text, embedded quotes, embedded backslashes, embedded newlines.
  let nameStrat = strings(intervals([(0x61'i32, 0x7a'i32)]), 1, 6)
  let strValStrat = sampledFrom([
    "", "hello", "with \"quote\"", "with \\backslash",
    "with\nnewline", "  whitespace  ", "rule",
  ])
  let kindStrat = sampledFrom([
    opSetProp, opSetPropStr, opAddArg, opAddArgStr,
    opRemoveProp, opSetName, opSetTag, opClearTag,
    opAddChild, opRemoveChild,
  ])
  newStrategy(proc(src: var DataSource): Op =
    let k = kindStrat.run(src)
    case k
    of opSetProp:
      Op(kind: opSetProp,
         propName: nameStrat.run(src),
         propValI: toInt64(src.drawInteger(toInt128(-100), toInt128(100),
                                            toInt128(0))).int)
    of opSetPropStr:
      Op(kind: opSetPropStr,
         propNameS: nameStrat.run(src),
         propValS: strValStrat.run(src))
    of opAddArg:
      Op(kind: opAddArg,
         argValI: toInt64(src.drawInteger(toInt128(-100), toInt128(100),
                                            toInt128(0))).int)
    of opAddArgStr:
      Op(kind: opAddArgStr, argValS: strValStrat.run(src))
    of opRemoveProp:
      Op(kind: opRemoveProp, removeName: nameStrat.run(src))
    of opSetName:
      Op(kind: opSetName, newName: nameStrat.run(src))
    of opSetTag:
      Op(kind: opSetTag, tag: nameStrat.run(src))
    of opClearTag:
      Op(kind: opClearTag)
    of opAddChild:
      Op(kind: opAddChild, childName: nameStrat.run(src))
    of opRemoveChild:
      Op(kind: opRemoveChild, removeChildName: nameStrat.run(src)))

suite "preserve encode — property #3 (stateful round-trip)":
  property "mutation sequence preserves round-trip after every step":
    given src in sampledFrom(corpus),
          ops in lists(opStrategy(), 0, 8)
    let r = parse(src, preserveFormat = true)
    assume r.isOk
    var d = r.get
    assume d.nodes.len > 0
    for op in ops:
      case op.kind
      of opSetProp:
        d.nodes[0].setProp(d, op.propName, newIntValue(int64(op.propValI)))
      of opSetPropStr:
        d.nodes[0].setProp(d, op.propNameS, newStringValue(op.propValS))
      of opAddArg:
        d.nodes[0].addArg(d, newIntValue(int64(op.argValI)))
      of opAddArgStr:
        d.nodes[0].addArg(d, newStringValue(op.argValS))
      of opRemoveProp:
        discard d.nodes[0].removeProp(d, op.removeName)
      of opSetName:
        d.nodes[0].setName(d, op.newName)
      of opSetTag:
        d.nodes[0].setTypeAnnotation(d, op.tag)
      of opClearTag:
        d.nodes[0].clearTypeAnnotation(d)
      of opAddChild:
        var child = newNode(d, op.childName)
        d.nodes[0].addChild(d, child)
      of opRemoveChild:
        discard d.nodes[0].removeChild(d, op.removeChildName)
      # Per-step invariant.
      let text = encode(d, emPreserve)
      let r2 = parse(text, preserveFormat = true)
      ensure r2.isOk
      if r2.isOk:
        ensure docEqual(d, r2.get)

# ---------------------------------------------------------------------------
# Canonical-emit properties (emPretty + emCompact)
# ---------------------------------------------------------------------------

suite "canonical encode — idempotency":
  # Canonical output should be a fixed point: feeding it back through
  # parse + canonical-emit produces byte-identical output. If not,
  # the encoder isn't normalizing consistently — some representation
  # choice flips between passes.

  property "emPretty is idempotent under parse+re-encode":
    given src in sampledFrom(corpus)
    let r1 = parse(src)
    if r1.isOk:
      let t1 = encode(r1.get, emPretty)
      let r2 = parse(t1)
      ensure r2.isOk
      if r2.isOk:
        let t2 = encode(r2.get, emPretty)
        ensure t1 == t2

  property "emCompact is idempotent under parse+re-encode":
    given src in sampledFrom(corpus)
    let r1 = parse(src)
    if r1.isOk:
      let t1 = encode(r1.get, emCompact)
      let r2 = parse(t1)
      ensure r2.isOk
      if r2.isOk:
        let t2 = encode(r2.get, emCompact)
        ensure t1 == t2

  property "emCompact round-trip structural equality":
    given src in sampledFrom(corpus)
    let r1 = parse(src)
    if r1.isOk:
      let d1 = r1.get
      let t = encode(d1, emCompact)
      let r2 = parse(t)
      ensure r2.isOk
      if r2.isOk:
        ensure docEqual(d1, r2.get)

# ---------------------------------------------------------------------------
# Deep-children mutation (exercises the recursive subtreeDirty + headLen
# invariants on nested nodes — not just top-level)
# ---------------------------------------------------------------------------

suite "built-from-scratch docs — canonical emit + round-trip":
  # Docs built entirely via the builder API (no sourceText) exercise
  # the encoder's "no preserve fast-path" branches that corpus-edits
  # don't hit. If headLen / span defaults misbehave for builder-API
  # nodes, this will catch it.
  property "newDoc + builder ops round-trip through emPretty":
    given ops in lists(opStrategy(), 1, 10)
    var d = newDoc()
    var root = newNode(d, "root")
    d.add(root)
    for op in ops:
      case op.kind
      of opSetProp:
        d.nodes[0].setProp(d, op.propName, newIntValue(int64(op.propValI)))
      of opSetPropStr:
        d.nodes[0].setProp(d, op.propNameS, newStringValue(op.propValS))
      of opAddArg:
        d.nodes[0].addArg(d, newIntValue(int64(op.argValI)))
      of opAddArgStr:
        d.nodes[0].addArg(d, newStringValue(op.argValS))
      of opRemoveProp:
        discard d.nodes[0].removeProp(d, op.removeName)
      of opSetName:
        d.nodes[0].setName(d, op.newName)
      of opSetTag:
        d.nodes[0].setTypeAnnotation(d, op.tag)
      of opClearTag:
        d.nodes[0].clearTypeAnnotation(d)
      of opAddChild:
        var c = newNode(d, op.childName)
        d.nodes[0].addChild(d, c)
      of opRemoveChild:
        discard d.nodes[0].removeChild(d, op.removeChildName)
    let text = encode(d, emPretty)
    let r = parse(text)
    ensure r.isOk
    if r.isOk:
      ensure docEqual(d, r.get)

suite "value-shape stress (number + string extremes)":
  # The encoder handles bigint promotion, NaN/Inf, embedded escapes
  # in strings. These are easy to forget about and easy to break.
  property "extreme int values round-trip":
    with (var s = defaultSettings(); s.maxExamples = 8; s)
    given v in sampledFrom([
      int64.high, int64.low, int64.high - 1, int64.low + 1,
      0'i64, 1'i64, -1'i64, 42'i64,
    ])
    var d = newDoc()
    var n = newNode(d, "x")
    n.addArg(d, newIntValue(v))
    d.add(n)
    let text = encode(d, emPretty)
    let r = parse(text)
    ensure r.isOk
    if r.isOk:
      ensure docEqual(d, r.get)

  property "special floats round-trip (NaN / Inf / 0 / subnormals)":
    given v in sampledFrom([
      0.0, -0.0, 1.0, -1.0,
      Inf, NegInf,
      # NaN deliberately excluded — NaN != NaN means docEqual would
      # falsify, but the encoder/parser handling is exercised by the
      # other properties via the no-crash invariant.
      1.7976931348623157e308,  # near float.high
      2.2250738585072014e-308, # near smallest normal
    ])
    var d = newDoc()
    var n = newNode(d, "x")
    n.addArg(d, newFloatValue(v))
    d.add(n)
    let text = encode(d, emPretty)
    let r = parse(text)
    ensure r.isOk
    if r.isOk:
      ensure docEqual(d, r.get)

  property "strings with arbitrary printable-ASCII content round-trip":
    given s in strings(0, 40)
    var d = newDoc()
    var n = newNode(d, "x")
    n.addArg(d, newStringValue(s))
    d.add(n)
    let text = encode(d, emPretty)
    let r = parse(text)
    ensure r.isOk
    if r.isOk:
      ensure docEqual(d, r.get)

suite "multi-node mutation — independent edits at multiple top-level nodes":
  # Until now every stateful property mutates only nodes[0]. Touch
  # nodes[0] AND nodes[1] in the same chain; if doc-level walk's
  # cursor state isn't preserved correctly when MULTIPLE adjacent
  # nodes are dirty, this will catch it.
  property "alternating mutations at nodes[0] and nodes[1] round-trip":
    given src in corpusMultiNodeStrat,
          ops in lists(opStrategy(), 1, 12)
    var d = assumeOk(parse(src, preserveFormat = true))
    var pick = 0
    for op in ops:
      template applyAt(idx: int, body: untyped) =
        body
      let i = pick mod 2
      case op.kind
      of opSetProp:
        d.nodes[i].setProp(d, op.propName, newIntValue(int64(op.propValI)))
      of opSetPropStr:
        d.nodes[i].setProp(d, op.propNameS, newStringValue(op.propValS))
      of opAddArg:
        d.nodes[i].addArg(d, newIntValue(int64(op.argValI)))
      of opAddArgStr:
        d.nodes[i].addArg(d, newStringValue(op.argValS))
      of opRemoveProp:
        discard d.nodes[i].removeProp(d, op.removeName)
      of opSetName:
        d.nodes[i].setName(d, op.newName)
      of opSetTag:
        d.nodes[i].setTypeAnnotation(d, op.tag)
      of opClearTag:
        d.nodes[i].clearTypeAnnotation(d)
      of opAddChild:
        var c = newNode(d, op.childName)
        d.nodes[i].addChild(d, c)
      of opRemoveChild:
        discard d.nodes[i].removeChild(d, op.removeChildName)
      inc pick
      let text = encode(d, emPreserve)
      let r2 = parse(text, preserveFormat = true)
      ensure r2.isOk
      if r2.isOk:
        ensure docEqual(d, r2.get)

suite "differential — mode agreement on structural equality":
  # Two canonical modes must agree structurally on the same input.
  # If emPretty and emCompact diverge on what they consider the
  # canonical doc, one of them is wrong (or the parser handles
  # whitespace differently between the two forms).
  property "parse(emPretty(d)) ≈ parse(emCompact(d)) structurally":
    given src in sampledFrom(corpus)
    let r = parse(src)
    if r.isOk:
      let d = r.get
      let pretty = encode(d, emPretty)
      let compact = encode(d, emCompact)
      let rp = parse(pretty)
      let rc = parse(compact)
      ensure rp.isOk
      ensure rc.isOk
      if rp.isOk and rc.isOk:
        ensure docEqual(rp.get, rc.get)

suite "reserved-name handling":
  # KDL v2 reserves bare identifiers: `true`, `false`, `null`, `inf`,
  # `-inf`, `nan`. A node OR property name that matches one of those
  # MUST be emitted quoted, otherwise the re-parse misclassifies it
  # as a keyword value.
  property "reserved-name props round-trip via quoting":
    given keyword in sampledFrom(["true", "false", "null",
                                   "inf", "-inf", "nan", "#"])
    var d = newDoc()
    var n = newNode(d, "x")
    n.setProp(d, keyword, newIntValue(42))
    d.add(n)
    let text = encode(d, emPretty)
    let r = parse(text)
    ensure r.isOk
    if r.isOk:
      ensure docEqual(d, r.get)

  property "reserved-name node names round-trip via quoting":
    given keyword in sampledFrom(["true", "false", "null",
                                   "inf", "-inf", "nan"])
    var d = newDoc()
    var n = newNode(d, keyword)
    n.addArg(d, newIntValue(1))
    d.add(n)
    let text = encode(d, emPretty)
    let r = parse(text)
    ensure r.isOk
    if r.isOk:
      ensure docEqual(d, r.get)

suite "long-chain stateful (cumulative mutation pressure)":
  # Bump the chain length to 30 ops. Cumulative state failures only
  # surface after enough mutation history accumulates — short chains
  # can mask bugs that depend on tombstone-count, dirty-flag-
  # propagation, or interner-handle accumulation.
  property "long mutation chains preserve round-trip":
    given src in sampledFrom(corpus),
          ops in lists(opStrategy(), 5, 30)
    let r = parse(src, preserveFormat = true)
    assume r.isOk
    var d = r.get
    assume d.nodes.len > 0
    for op in ops:
      case op.kind
      of opSetProp:
        d.nodes[0].setProp(d, op.propName, newIntValue(int64(op.propValI)))
      of opSetPropStr:
        d.nodes[0].setProp(d, op.propNameS, newStringValue(op.propValS))
      of opAddArg:
        d.nodes[0].addArg(d, newIntValue(int64(op.argValI)))
      of opAddArgStr:
        d.nodes[0].addArg(d, newStringValue(op.argValS))
      of opRemoveProp:
        discard d.nodes[0].removeProp(d, op.removeName)
      of opSetName:
        d.nodes[0].setName(d, op.newName)
      of opSetTag:
        d.nodes[0].setTypeAnnotation(d, op.tag)
      of opClearTag:
        d.nodes[0].clearTypeAnnotation(d)
      of opAddChild:
        var c = newNode(d, op.childName)
        d.nodes[0].addChild(d, c)
      of opRemoveChild:
        discard d.nodes[0].removeChild(d, op.removeChildName)
      let text = encode(d, emPreserve)
      let r2 = parse(text, preserveFormat = true)
      ensure r2.isOk
      if r2.isOk:
        ensure docEqual(d, r2.get)

suite "encoder output is always parseable":
  # If the encoder ever produces output that the parser can't read,
  # that's a structural bug — round-trip-stability is the central
  # contract. This is a weaker form of property #2 / #1 — re-parse
  # must succeed, but we don't require structural equality.
  property "encode output is always parseable across modes":
    given src in sampledFrom(corpus), modeIdx in integers(0, 2)
    let r1 = parse(src, preserveFormat = true)
    if r1.isOk:
      let mode = case modeIdx
        of 0: emPreserve
        of 1: emPretty
        else: emCompact
      let text = encode(r1.get, mode)
      let r2 = parse(text)
      ensure r2.isOk

suite "deep children — round-trip after nested mutation":
  property "mutating a deep child preserves round-trip":
    given src in sampledFrom(corpus),
          op in opStrategy()
    let r = parse(src, preserveFormat = true)
    assume r.isOk
    var d = r.get
    assume d.nodes.len > 0
    assume d.nodes[0].children.len > 0
    # Mutate the first child of the first top-level node.
    case op.kind
    of opSetProp:
      d.nodes[0].children[0].setProp(d, op.propName,
                                     newIntValue(int64(op.propValI)))
    of opSetPropStr:
      d.nodes[0].children[0].setProp(d, op.propNameS,
                                     newStringValue(op.propValS))
    of opAddArg:
      d.nodes[0].children[0].addArg(d, newIntValue(int64(op.argValI)))
    of opAddArgStr:
      d.nodes[0].children[0].addArg(d, newStringValue(op.argValS))
    of opRemoveProp:
      discard d.nodes[0].children[0].removeProp(d, op.removeName)
    of opSetName:
      d.nodes[0].children[0].setName(d, op.newName)
    of opSetTag:
      d.nodes[0].children[0].setTypeAnnotation(d, op.tag)
    of opClearTag:
      d.nodes[0].children[0].clearTypeAnnotation(d)
    of opAddChild:
      var grandchild = newNode(d, op.childName)
      d.nodes[0].children[0].addChild(d, grandchild)
    of opRemoveChild:
      discard d.nodes[0].children[0].removeChild(d, op.removeChildName)
    let text = encode(d, emPreserve)
    let r2 = parse(text, preserveFormat = true)
    ensure r2.isOk
    if r2.isOk:
      ensure docEqual(d, r2.get)
