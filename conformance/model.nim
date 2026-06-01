## Clean-room KDL document model for the conformance corpus.
##
## This is a neutral encoding of the spec's data model — a KDL document is a
## sequence of nodes; a node has a name, an optional type annotation, a
## sequence of entries (arguments and properties), and child nodes; a value is
## a string / number / boolean / null with an optional type annotation. It is
## derived from `docs/kdl-2.0-spec.md` ALONE.
##
## INVARIANT: this module (and the whole `tests/corpus/` tree) imports NOTHING
## from `../../src` — not the lexer, parser, AST, numlit, or emitter. The
## corpus we test nkdl against must contain zero nkdl code, or "nkdl passes" is
## circular. The only dependency is the stdlib. nkdl (and other impls) consume
## the emitted corpus through a separate adapter; they never appear here.
##
## The model carries the *expected* value of a generated input; the renderer
## (separate) produces the input *text*. Generation is simpler than parsing
## (no ambiguity / lookahead / error recovery), so the (text, model) pair is an
## oracle by construction — no parser required to produce it.

import std/json

type
  KValueKind* = enum
    kvNull, kvBool, kvInt, kvFloat, kvString

  KValue* = object
    ## A KDL value with an optional `(type)` annotation (`""` == none).
    typeAnno*: string
    case kind*: KValueKind
    of kvNull:   discard
    of kvBool:   b*: bool
    of kvInt:    i*: int64
    of kvFloat:  f*: float
    of kvString: s*: string

  KEntryKind* = enum keArg, keProp
  KEntry* = object
    case kind*: KEntryKind
    of keArg:
      val*: KValue
    of keProp:
      key*: string
      pval*: KValue

  KNode* = object
    name*: string
    typeAnno*: string          ## `""` == none
    entries*: seq[KEntry]
    children*: seq[KNode]

  KDoc* = seq[KNode]

# ---------------------------------------------------------------------------
# Constructors (terse builders for generators)
# ---------------------------------------------------------------------------

func kNull*(anno = ""): KValue = KValue(kind: kvNull, typeAnno: anno)
func kBool*(b: bool, anno = ""): KValue = KValue(kind: kvBool, b: b, typeAnno: anno)
func kInt*(i: int64, anno = ""): KValue = KValue(kind: kvInt, i: i, typeAnno: anno)
func kFloat*(f: float, anno = ""): KValue = KValue(kind: kvFloat, f: f, typeAnno: anno)
func kStr*(s: string, anno = ""): KValue = KValue(kind: kvString, s: s, typeAnno: anno)

func arg*(v: KValue): KEntry = KEntry(kind: keArg, val: v)
func prop*(k: string, v: KValue): KEntry = KEntry(kind: keProp, key: k, pval: v)

# ---------------------------------------------------------------------------
# Neutral JSON serialization — the on-disk `expected.json` form.
# ---------------------------------------------------------------------------

func annoJson(anno: string): JsonNode =
  if anno.len == 0: newJNull() else: %anno

func toJson*(v: KValue): JsonNode =
  ## Tagged, language-neutral. Non-finite floats are strings ("inf"/"-inf"/
  ## "nan") since JSON has no IEEE specials. `int` stays a JSON integer.
  result = newJObject()
  result["type"] = annoJson(v.typeAnno)
  case v.kind
  of kvNull:   result["kind"] = %"null";   result["value"] = newJNull()
  of kvBool:   result["kind"] = %"bool";   result["value"] = %v.b
  of kvInt:    result["kind"] = %"int";    result["value"] = %v.i
  of kvString: result["kind"] = %"string"; result["value"] = %v.s
  of kvFloat:
    result["kind"] = %"float"
    if v.f != v.f:            result["value"] = %"nan"
    elif v.f == Inf:          result["value"] = %"inf"
    elif v.f == NegInf:       result["value"] = %"-inf"
    else:                     result["value"] = %v.f

func toJson*(n: KNode): JsonNode =
  result = newJObject()
  result["name"] = %n.name
  result["type"] = annoJson(n.typeAnno)
  var args = newJArray()
  var props = newJArray()
  for e in n.entries:
    case e.kind
    of keArg:  args.add toJson(e.val)
    of keProp: props.add %*[%e.key, toJson(e.pval)]
  result["args"] = args
  result["props"] = props
  var kids = newJArray()
  for c in n.children: kids.add toJson(c)
  result["children"] = kids

func toJson*(doc: KDoc): JsonNode =
  result = newJArray()
  for n in doc: result.add toJson(n)

when isMainModule:
  # Proof of the clean-room shape: a document → its neutral expected JSON,
  # with zero nkdl involvement.
  let doc: KDoc = @[
    KNode(name: "node", typeAnno: "",
          entries: @[arg(kInt(16)), prop("port", kInt(80, "u16")),
                     arg(kStr("hi")), arg(kFloat(Inf))],
          children: @[KNode(name: "child", entries: @[arg(kBool(true))])]),
  ]
  echo pretty(toJson(doc))
