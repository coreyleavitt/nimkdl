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

type ValueSurface* = object
  text*:  string
  value*: KValue

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
  map(floats(-1e12, 1e12, allowNan = false), booleans(),
      proc(f: float, plus: bool): ValueSurface =
        ValueSurface(text: renderFloat(f, plus), value: kFloat(f)))

# ---------------------------------------------------------------------------
# Keyword values  (#true #false #null #inf #-inf #nan)
# ---------------------------------------------------------------------------

proc keywordSurfaces*(): Strategy[ValueSurface] =
  sampledFrom(@[kBool(true), kBool(false), kNull(),
                kFloat(Inf), kFloat(NegInf), kFloat(NaN)])
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

when isMainModule:
  # Clean-room proof: sample (text, expected-json) pairs, proptest+stdlib only.
  for vs in valueSurfaces().sampleN(12):
    echo vs.text, "   =>   ", $toJson(vs.value)
