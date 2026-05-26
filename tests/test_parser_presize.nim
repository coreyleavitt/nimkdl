## Tests for parser-side pre-sized sequences.
##
## The parser produces `KdlDoc.nodes` (top-level) which can grow large
## for catalog-style configs (thousands of nodes). Pre-allocating from
## an estimate derived from the token stream avoids O(log N) reallocs
## of progressively-larger seqs where each item is a ~56-byte KdlNode.

import std/[strutils, unittest]

import spans
import lexer
import parser
import ast


suite "parser pre-size — top-level node estimator":

  test "estimateDocNodes returns a positive count":
    check estimateDocNodes(10) > 0
    check estimateDocNodes(1000) > 0

  test "estimateDocNodes scales with token count":
    # More tokens → more nodes expected, in the same order of magnitude.
    check estimateDocNodes(1000) > estimateDocNodes(100)

  test "estimateDocNodes floors at a sensible minimum":
    # Tiny docs shouldn't get a pathologically small estimate (would
    # immediately force growth on the first node).
    check estimateDocNodes(0) >= 4
    check estimateDocNodes(1) >= 4

  test "estimator never under-allocates for fixture configs":
    # The load-bearing property: pre-sizing must not UNDER-estimate (that
    # would force O(log N) reallocs). Over-estimation is fine — the per-
    # doc variance in tree shape (deep-and-narrow vs flat-and-wide) means
    # any cheap heuristic on byte count will over-shoot for tree-heavy
    # configs. The fixed memory cost of a slightly-over-allocated seq
    # holding ~56-byte KdlNodes is negligible.
    const FixtureCi = staticRead("../benchmarks/fixtures/ci.kdl")
    var doc1 = parse(FixtureCi)
    check doc1.isOk
    if doc1.isOk:
      let actual = doc1.get.nodes.len
      let est = estimateDocNodes(FixtureCi.len div 6)  # rough token count
      check est >= actual  # never under — the only failure mode that matters
