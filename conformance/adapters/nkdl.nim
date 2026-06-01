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

import std/[json, unittest]

import proptest

import ../model
import ../gen

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
  of nast.kvFloat:  kFloat(v.floatVal, anno)
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
