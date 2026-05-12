## Tests for slice-1 of the v0.2 conformance push: bare-keyword rejection.
##
## Spec (kdl-org draft-marchan-kdl2, Identifier Strings):
##
##   "idents that are the language keywords (`inf`, `-inf`, `nan`, `true`,
##    `false`, and `null`) without their leading `#`. Identifiers that
##    match these patterns MUST be treated as a syntax error; such values
##    can only be written as quoted or raw strings."
##
## Covers all three identifier positions for each of the 6 keywords:
## node name, property key, value (bare-ident-as-string).

import std/unittest

import ../src/parser
import ../src/spans

template expectReserved(src: string) =
  let res = parse(src)
  check res.isErr
  if res.isErr:
    check res.getErr.code == peLexReservedKeyword

suite "reserved keyword as node name":
  test "'true' as node name":      expectReserved("true")
  test "'false' as node name":     expectReserved("false")
  test "'null' as node name":      expectReserved("null")
  test "'inf' as node name":       expectReserved("inf")
  test "'-inf' as node name":      expectReserved("-inf")
  test "'nan' as node name":       expectReserved("nan")

suite "reserved keyword as property key":
  test "'true' as property key":   expectReserved("node true=1")
  test "'false' as property key":  expectReserved("node false=1")
  test "'null' as property key":   expectReserved("node null=1")
  test "'inf' as property key":    expectReserved("node inf=1")
  test "'-inf' as property key":   expectReserved("node -inf=1")
  test "'nan' as property key":    expectReserved("node nan=1")

suite "reserved keyword as bare-ident value":
  test "'true' as value":          expectReserved("node true")
  test "'false' as value":         expectReserved("node false")
  test "'null' as value":          expectReserved("node null")
  test "'inf' as value":           expectReserved("node inf")
  test "'-inf' as value":          expectReserved("node -inf")
  test "'nan' as value":           expectReserved("node nan")
