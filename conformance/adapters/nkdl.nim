## conformance/adapters/nkdl.nim — run the clean-room corpus against nkdl.
##
## This is the ONLY file under conformance/ permitted to import nkdl. The
## generator (`../gen`) and the expected model (`../model`) contain zero nkdl
## code, so "nkdl agrees with the corpus" is a genuine independent check.
##
## For each generated document it parses the input with nkdl, maps nkdl's
## `KdlDoc` into the neutral model, and asserts the serialized JSON matches the
## generator's expected JSON. A failure is either a real nkdl bug or a
## generator bug — investigate by probing nkdl directly, never by silently
## "fixing" the corpus.

import std/[json, unittest, formatfloat]

import proptest

import ../model
import ../gen
import ../coverage
import ../groups

import ../../src/parser          # parse
import ../../src/ast as nast      # KdlDoc/KdlNode/KdlEntry/KdlValue (aliased)
import ../../src/intern           # Interner, lookup, InvalidInterned
import ../../src/spans            # Result.isOk / .get

func annoOf(h: InternedStr, ig: Interner): string =
  if h == InvalidInterned: "" else: ig.lookup(h)

proc mapVal(v: nast.KdlValue, ig: Interner): model.KValue =
  let anno = annoOf(v.typeAnnotation, ig)
  case v.kind
  of nast.kvString: kStr(v.strVal, anno)
  of nast.kvInt:    kInt(v.intVal, anno)
  of nast.kvFloat:
    # Map nkdl's double onto the exact-decimal oracle. Specials are the inf/nan
    # keyword numbers; finite doubles re-render to decimal (stdlib Schubfach)
    # and parse via the SAME `numFromText` the generator uses, so agreement
    # means nkdl recovered the same number — not that both trust one double.
    if v.floatVal != v.floatVal: kNan(anno)
    elif v.floatVal == Inf:      kInf(anno)
    elif v.floatVal == NegInf:   kNegInf(anno)
    else:
      var s = ""
      s.addFloatRoundtrip(v.floatVal)
      numFromText(s, anno)
  of nast.kvBool:   kBool(v.boolVal, anno)
  of nast.kvNull:   kNull(anno)
  of nast.kvBigInt: kStr("<bigint>", anno)   # generator never emits these yet

proc mapNode(n: nast.KdlNode, ig: Interner): model.KNode =
  result.name = ig.lookup(n.name)
  result.typeAnno = annoOf(n.typeAnnotation, ig)
  for e in n.entries:
    case e.kind
    of nast.keArgument: result.entries.add arg(mapVal(e.argValue, ig))
    of nast.keProperty: result.entries.add prop(ig.lookup(e.propName),
                                                 mapVal(e.propValue, ig))
  for c in n.children:
    result.children.add mapNode(c, ig)

proc mapDoc(d: nast.KdlDoc): model.KDoc =
  for n in d.nodes: result.add mapNode(n, d.interner)

suite "conformance — nkdl adapter (clean-room corpus vs nkdl)":

  property "nkdl parses each generated document to the expected model":
    with Settings(maxExamples: 500, testId: "conf-nkdl-doc")
    given ds in docSurface()
    let r = parse(ds.text)
    ensure r.isOk
    ensure toJson(mapDoc(r.get)) == toJson(ds.doc)

suite "conformance — nkdl runs the covering-array corpus (A4)":
  # The CURATED corpus (constrained covering array), not random generation:
  # every covering-array row, instantiated to a witness, must parse to its
  # expected model. This is the deterministic, production-complete check.

  test "every value group: each covering-array witness parses to its model":
    for (g, instantiate) in valueGroups():
      for row in coveringArray(g):
        let s = instantiate(row)
        let doc: model.KDoc = @[KNode(name: "node", entries: @[arg(s.value)])]
        let r = parse("node " & s.text & "\n")
        check r.isOk
        if r.isOk:
          check toJson(mapDoc(r.get)) == toJson(doc)

  test "every doc group: each node-shaped witness parses to its model":
    for (g, instantiate) in docGroups():
      for row in coveringArray(g):
        let s = instantiate(row)
        let r = parse(s.text)
        check r.isOk
        if r.isOk:
          check toJson(mapDoc(r.get)) == toJson(s.doc)
