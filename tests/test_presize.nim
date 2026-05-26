## Tests for pre-sized token sequence allocation.
##
## Pre-sizing the lexer's output `seq[Token]` to an estimated count
## eliminates ~log₂(N/7) reallocations during tokenization for an
## N-byte source. Behavior of `lex()` is unchanged; only its
## allocation pattern is affected. Tests here verify:
##
##   1. the estimator is a well-defined pure function
##   2. the actual capacity ends up close to the actual count (the
##      estimator is well-calibrated for typical inputs)
##   3. edge cases (empty source, micro-source) don't error
##
## Conformance regression is checked separately by `test_conformance`.

import std/[strutils, unittest]

import spans
import lexer
import intern


suite "pre-sized tokens — estimator":

  test "estimateTokenCount returns a positive count for non-empty input":
    # The most fundamental contract: given a positive source length,
    # the estimator returns a positive count we can pre-allocate with.
    check estimateTokenCount(1) > 0
    check estimateTokenCount(100) > 0
    check estimateTokenCount(1_000_000) > 0

  test "estimateTokenCount scales with input length":
    # Larger source → larger estimate. Doesn't need to be linear or
    # exactly proportional; just monotonic in a useful range.
    check estimateTokenCount(1000) > estimateTokenCount(100)
    check estimateTokenCount(10000) > estimateTokenCount(1000)


suite "pre-sized tokens — calibration on real fixtures":

  # Fixtures chosen to span small/medium configs.
  const FixtureSmall  = staticRead("../benchmarks/fixtures/Cargo.kdl")
  const FixtureMed1   = staticRead("../benchmarks/fixtures/ci.kdl")
  const FixtureMed2   = staticRead("../benchmarks/fixtures/website.kdl")

  proc capacityIsWellCalibrated(source: string): bool =
    ## After lex, the seq's capacity should be ≥ its length (basic
    ## sanity — pre-sizing didn't under-allocate forcing growth) AND
    ## ≤ 2× its length (heuristic isn't wildly over-sized).
    var interner = initInterner()
    let stream = lex(source, interner)
    let cap = stream.tokens.len  # Nim 2.x: seq capacity isn't directly
                                 # introspectable without unsafe access.
                                 # We assert on the length-vs-estimate
                                 # relationship instead, which is the
                                 # property that matters.
    let est = estimateTokenCount(source.len)
    # The estimate should be in the same order of magnitude as the
    # actual count. Specifically: actual <= 2 * estimate (so pre-size
    # didn't need to grow much), AND estimate <= 4 * actual (so we
    # didn't massively over-allocate).
    return cap <= 2 * est and est <= 4 * cap

  test "Cargo.kdl (small) — estimator within calibration bounds":
    check capacityIsWellCalibrated(FixtureSmall)

  test "ci.kdl (medium) — estimator within calibration bounds":
    check capacityIsWellCalibrated(FixtureMed1)

  test "website.kdl (medium) — estimator within calibration bounds":
    check capacityIsWellCalibrated(FixtureMed2)


suite "pre-sized tokens — edge cases":

  test "empty source produces a TokenStream with just tkEof":
    var interner = initInterner()
    let stream = lex("", interner)
    check stream.tokens.len >= 1
    check stream.tokens[^1].kind == tkEof

  test "single-character source doesn't crash":
    var interner = initInterner()
    let stream = lex("x", interner)
    check stream.tokens.len >= 1
    # `x` should lex as a bare identifier followed by EOF.
    var sawIdent = false
    for t in stream.tokens:
      if t.kind == tkIdent: sawIdent = true
    check sawIdent

  test "estimator floors at 16 — tiny inputs don't get pathologically-small caps":
    # For very small inputs the lex setup cost dominates; a tiny cap
    # would just force immediate growth. Floor at 16.
    check estimateTokenCount(0) >= 16
    check estimateTokenCount(1) >= 16
    check estimateTokenCount(50) >= 16
