## Spec-coverage property suite — Tier 1: lexical value fidelity.
##
## For each generated `ValueSurface(text, value)`, parsing `node <text>` must
## yield exactly one node with one argument whose value equals `value`. The
## generator is the spec-derived oracle (see `kdlgen.nim` +
## `docs/rfc-spec-coverage-testing.md`). Gated by `NKDL_PROPTEST=1`.

import std/unittest

import proptest

import ../src/ast
import ../src/parser
import ../src/spans   # Result.isOk / .get

import ./kdlgen

proc denotes(s: ValueSurface): bool =
  ## The Tier-1 oracle: the bytes->value path through the public `parse()`
  ## surface must recover exactly the value the generator drew.
  let r = parse("node " & s.text)
  if r.isErr: return false
  let doc = r.get
  if doc.nodes.len != 1 or doc.nodes[0].entries.len != 1: return false
  valueEq(doc.nodes[0].entries[0].argValue, s.value)

suite "spec-coverage Tier 1 — lexical value fidelity":

  test "denotes is non-vacuous — it detects a value mismatch":
    # Guards every property below: if `denotes` ever became trivially true,
    # this fails. `5` does not denote the int 6.
    check denotes(ValueSurface(text: "5", value: newIntValue(5)))
    check not denotes(ValueSurface(text: "5", value: newIntValue(6)))

  property "decimal integers denote their value":
    with Settings(maxExamples: 300, testId: "sc-dec-int")
    given s in decimalIntSurfaces()
    ensure denotes(s)

  property "hex/octal/binary integers denote their value":
    with Settings(maxExamples: 400, testId: "sc-radix-int")
    given s in radixIntSurfaces()
    ensure denotes(s)

  property "digit-group underscores denote the same integer":
    with Settings(maxExamples: 400, testId: "sc-underscore-int")
    given s in underscoreIntSurfaces()
    ensure denotes(s)

  property "finite decimal floats denote their value":
    with Settings(maxExamples: 500, testId: "sc-float")
    given s in finiteFloatSurfaces()
    ensure denotes(s)

  property "keyword values denote their value":
    with Settings(maxExamples: 100, testId: "sc-keyword")
    given s in keywordSurfaces()
    ensure denotes(s)

  property "plain (unescaped) strings denote their bytes":
    with Settings(maxExamples: 400, testId: "sc-plain-string")
    given s in plainStringSurfaces()
    ensure denotes(s)

  property "escaped strings decode to the original bytes":
    with Settings(maxExamples: 500, testId: "sc-escaped-string")
    given s in escapedStringSurfaces()
    ensure denotes(s)
