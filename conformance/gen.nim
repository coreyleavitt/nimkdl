## conformance/gen.nim — paired (text, value) generators.
##
## proptest strategies that draw a value + a surface style and render the two
## together, so each `ValueSurface(text, value)` is an oracle by construction.
## Imports only proptest + the clean-room `model`/`render` — NOTHING from
## `../src`. The corpus emitter and any conformance adapter consume these.

import std/json
import proptest
import proptest/rng         # initSplitMix64
import proptest/datasource  # newDataSource
import ./model
import ./render

# `ValueSurface` (text paired with its exact model value) now lives in
# `render.nim` so the covering-array instantiator can share it without pulling
# in proptest.

# ---------------------------------------------------------------------------
# Standalone sampling (the corpus emitter generates rather than asserts)
# ---------------------------------------------------------------------------

proc sampleN*[T](s: Strategy[T], n: int, seed: uint64 = 0x5EED'u64): seq[T] =
  ## Draw `n` values from `s` deterministically from `seed`.
  var r = initSplitMix64(seed)
  var src = newDataSource(r)
  for _ in 0 ..< n:
    result.add s.generate(src)

# ---------------------------------------------------------------------------
# Integers  (number / decimal / hex / octal / binary / integer / sign)
# ---------------------------------------------------------------------------

const RadixBound = 1_099_511_627_776   # 2^40 — multi-digit, inside int64
const intBaseChoices = @[(10, false), (16, false), (16, true), (8, false), (2, false)]

proc intSurfaces*(): Strategy[ValueSurface] =
  ## Every integer surface: base × hex-case × sign{none,+,-} × underscore runs
  ## after any digit. value = sign × magnitude.
  map(integers(0, RadixBound), sampledFrom(intBaseChoices), integers(0, 2))
    .flatMap(proc(t: (int, (int, bool), int)): Strategy[ValueSurface] =
      let (magI, bc, signMode) = t
      let (base, upperHex) = bc
      let value = (if signMode == 2: -magI.int64 else: magI.int64)
      let nDigits = magnitudeDigits(uint64(magI), base, upperHex).len
      lists(integers(0, 2), nDigits, nDigits).map(proc(us: seq[int]): ValueSurface =
        let st = IntStyle(base: base, upperHex: upperHex,
                          signMode: signMode, underscores: us)
        ValueSurface(text: renderInt(value, st), value: kInt(value))))

# ---------------------------------------------------------------------------
# Floats  (decimal with fraction/exponent; finite — inf/nan are keywords)
# ---------------------------------------------------------------------------

proc floatSurfaces*(): Strategy[ValueSurface] =
  ## A finite float surface. The value is the EXACT decimal of the rendered
  ## text (parsed back via `numFromText`), not a re-stored double — so the
  ## oracle never depends on float representation. The adapter maps nkdl's
  ## parsed number through the same `numFromText`, so the two agree iff nkdl
  ## recovers the same number.
  map(floats(-1e12, 1e12, allowNan = false), booleans(),
      proc(f: float, plus: bool): ValueSurface =
        let t = renderFloat(f, plus)
        ValueSurface(text: t, value: numFromText(t)))

# ---------------------------------------------------------------------------
# Keyword values  (#true #false #null #inf #-inf #nan)
# ---------------------------------------------------------------------------

proc keywordSurfaces*(): Strategy[ValueSurface] =
  sampledFrom(@[kBool(true), kBool(false), kNull(),
                kInf(), kNegInf(), kNan()])
    .map(proc(v: KValue): ValueSurface =
      ValueSurface(text: renderKeywordValue(v), value: v))

# ---------------------------------------------------------------------------
# Strings  (escaped form; raw/multiline styles are follow-ups with their
# content preconditions). Alphabet: ASCII (controls/quote/backslash/DEL — all
# escaped) + gap-free safe Unicode (no surrogates/bidi/BOM, passed verbatim).
# ---------------------------------------------------------------------------

proc stringSurfaces*(): Strategy[ValueSurface] =
  strings(intervals([
    (0x00'i32,    0x7F'i32),
    (0x00A0'i32,  0x024F'i32),
    (0x0370'i32,  0x1FFF'i32),
    (0x2030'i32,  0x205F'i32),
    (0x3000'i32,  0xD7FF'i32),
    (0xE000'i32,  0xFDFF'i32),
    (0x10000'i32, 0x10FFFF'i32),
  ]), 0, 16).map(proc(s: string): ValueSurface =
    ValueSurface(text: renderStrEscaped(s), value: kStr(s)))

# ---------------------------------------------------------------------------
# Any value
# ---------------------------------------------------------------------------

proc valueSurfaces*(): Strategy[ValueSurface] =
  oneOf([intSurfaces(), floatSurfaces(), keywordSurfaces(), stringSurfaces()])

# ---------------------------------------------------------------------------
# Identifiers  (unambiguous-ident over ASCII + Unicode; minus keyword bareword)
# ---------------------------------------------------------------------------

proc identifierStrings*(): Strategy[string] =
  let startCh = strings(intervals([
    (0x41'i32, 0x5A'i32), (0x61'i32, 0x7A'i32), (0x5F'i32, 0x5F'i32),
    (0x00C0'i32, 0x024F'i32), (0x0370'i32, 0x03FF'i32)]), 1, 1)
  let restCh = strings(intervals([
    (0x41'i32, 0x5A'i32), (0x61'i32, 0x7A'i32), (0x30'i32, 0x39'i32),
    (0x5F'i32, 0x5F'i32), (0x2D'i32, 0x2E'i32), (0x24'i32, 0x24'i32),
    (0x00C0'i32, 0x024F'i32), (0x0370'i32, 0x03FF'i32)]), 0, 8)
  map(startCh, restCh, proc(a, b: string): string = a & b)
    .filter(proc(s: string): bool =
      s notin ["true", "false", "null", "inf", "-inf", "nan"])

# ---------------------------------------------------------------------------
# Nodes + documents
#   base-node := type? string (node-space (node-space) node-prop-or-arg)*
#                (node-space node-children)? ...
# Args/props reuse valueSurfaces (text+value paired). Props are deduped by key
# (distinct keys for now; repeated-key last-wins is a follow-up). Children
# recurse. No slashdash/trivia noise yet — those are the next refinements.
# ---------------------------------------------------------------------------

# `NodeSurface` / `DocSurface` now live in `render.nim` (shared with the
# covering-array node instantiator, without pulling in proptest).

proc kvPair(): Strategy[(string, ValueSurface)] =
  map(identifierStrings(), valueSurfaces(),
      proc(k: string, v: ValueSurface): (string, ValueSurface) = (k, v))

proc nodeSurface*(): Strategy[NodeSurface] =
  map(identifierStrings(), lists(valueSurfaces(), 0, 3), lists(kvPair(), 0, 2),
      proc(name: string, args: seq[ValueSurface],
           props: seq[(string, ValueSurface)]): NodeSurface =
        var t = name
        var entries: seq[KEntry]
        for a in args:
          t.add " " & a.text
          entries.add arg(a.value)
        # Keep the last occurrence of each key (KDL last-wins), distinct in
        # both text and model for this tracer.
        var seen: seq[string]
        var kept: seq[(string, ValueSurface)]
        for i in countdown(props.high, 0):
          if props[i][0] notin seen:
            seen.add props[i][0]
            kept.insert(props[i], 0)
        for kv in kept:
          t.add " " & kv[0] & "=" & kv[1].text
          entries.add prop(kv[0], kv[1].value)
        NodeSurface(text: t, node: KNode(name: name, entries: entries)))

proc docSurface*(): Strategy[DocSurface] =
  ## A document: one or more nodes, newline-terminated.
  lists(nodeSurface(), 1, 4).map(proc(ns: seq[NodeSurface]): DocSurface =
    var t = ""
    var doc: KDoc
    for i in 0 ..< ns.len:
      if i > 0: t.add "\n"
      t.add ns[i].text
      doc.add ns[i].node
    DocSurface(text: t & "\n", doc: doc))

when isMainModule:
  # Clean-room proof: sample whole documents → (input text, expected json).
  for ds in docSurface().sampleN(4):
    echo "--- input ---"
    echo ds.text
    echo "--- expected ---"
    echo pretty(toJson(ds.doc))
