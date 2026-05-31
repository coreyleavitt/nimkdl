## kdlgen — paired KDL surface generators for spec-coverage testing.
##
## Each generator yields a `ValueSurface` = (text, value): a syntactically
## valid KDL surface form paired with the `KdlValue` it MUST denote. The
## property suite (`test_spec_coverage`) asserts that `parse("node " & text)`
## yields exactly one node with one argument whose value equals `value`.
##
## ## Why a generator is the oracle
##
## No KDL parser fully conforms to the spec (the kdl-org reference misses
## corpus cases too), so a differential against any *parser* can't be ground
## truth. The spec grammar is the only authority. We encode it here in the
## **generation** direction, which is structurally simpler than parsing — no
## ambiguity, no lookahead, no error recovery — so each branch is correct by
## audit against one grammar production. See
## `docs/rfc-spec-coverage-testing.md`.
##
## ## The one non-negotiable
##
## The renderer must NOT call nkdl's encoder/formatter (`emitter`, `numlit`,
## `doc_emit`). It hand-writes its own surface forms so a shared bug cannot
## hide from itself. The float slice is the one sanctioned exception (it leans
## on stdlib `addFloatRoundtrip`, which is not nkdl and tests a different
## algorithm than any encoder).

import std/formatfloat   # addFloatRoundtrip — stdlib, NOT nkdl's formatter
import proptest
import ../src/ast

type
  ValueSurface* = object
    ## A valid KDL surface form of one value, paired with the value it denotes.
    text*:  string
    value*: KdlValue

func valueEq*(a, b: KdlValue): bool =
  ## Kind + payload equality, ignoring `span` and the (absent for these
  ## generators) `typeAnnotation`. NaN is treated as equal to NaN (the
  ## generator and parser must agree on `#nan`, which `==` would reject).
  if a.kind != b.kind: return false
  case a.kind
  of kvInt:    a.intVal == b.intVal
  of kvString: a.strVal == b.strVal
  of kvBool:   a.boolVal == b.boolVal
  of kvNull:   true
  of kvFloat:
    (a.floatVal != a.floatVal and b.floatVal != b.floatVal) or  # both NaN
    a.floatVal == b.floatVal
  of kvBigInt:
    a.bigHi == b.bigHi and a.bigLo == b.bigLo and
    a.bigNegative == b.bigNegative

# ---------------------------------------------------------------------------
# Slice 1 — decimal integers
# ---------------------------------------------------------------------------

proc decimalIntSurfaces*(): Strategy[ValueSurface] =
  ## Plain base-10 integers, including negatives. Renders via `$` (KDL's
  ## decimal-integer surface is identical to Nim's, so this is independent of
  ## nkdl's own formatter).
  integers(-1_000_000, 1_000_000).map(proc(n: int): ValueSurface =
    ValueSurface(text: $n, value: newIntValue(n.int64)))

# ---------------------------------------------------------------------------
# Slice 2 — hex / octal / binary integers
# ---------------------------------------------------------------------------

const RadixBound = 1_099_511_627_776  # 2^40 — multi-digit, well inside int64

func renderInBase(n: int64, base: int, upperHex: bool): string =
  ## Independent base-2/8/16 renderer with the KDL prefix; the sign precedes
  ## the prefix (`-0xFF`). Hand-written so it shares no code with numlit.
  let neg = n < 0
  var mag = (if neg: uint64(-n) else: uint64(n))
  let prefix = (case base
                of 2: "0b"
                of 8: "0o"
                else: "0x")
  let digits = if upperHex: "0123456789ABCDEF" else: "0123456789abcdef"
  var body = ""
  if mag == 0'u64: body = "0"
  while mag > 0'u64:
    body = digits[int(mag mod uint64(base))] & body
    mag = mag div uint64(base)
  (if neg: "-" else: "") & prefix & body

proc radixIntSurfaces*(): Strategy[ValueSurface] =
  ## Hex / octal / binary integers, random sign and (for hex) digit case.
  let styles = @[(2, false), (8, false), (16, false), (16, true)]
  map(integers(-RadixBound, RadixBound), sampledFrom(styles),
      proc(n: int, st: (int, bool)): ValueSurface =
        ValueSurface(text: renderInBase(n.int64, st[0], st[1]),
                     value: newIntValue(n.int64)))

# ---------------------------------------------------------------------------
# Slice 3 — digit-group underscores
# ---------------------------------------------------------------------------

proc underscoreIntSurfaces*(): Strategy[ValueSurface] =
  ## Decimal integers with `_` inserted at a random subset of inter-digit
  ## gaps (never leading/trailing, never doubled — a valid subset). The
  ## lexer's `_`-stripping is base-independent, so decimal exercises the
  ## same path as radix.
  integers(-RadixBound, RadixBound).flatMap(proc(n: int): Strategy[ValueSurface] =
    let neg = n < 0
    let body = $(if neg: uint64(-n) else: uint64(n))   # magnitude digits
    let gaps = max(0, body.len - 1)
    lists(booleans(), gaps, gaps).map(proc(ins: seq[bool]): ValueSurface =
      var s = ""
      for i in 0 ..< body.len:
        s.add body[i]
        if i < body.high and ins[i]: s.add '_'
      ValueSurface(text: (if neg: "-" else: "") & s, value: newIntValue(n.int64))))

# ---------------------------------------------------------------------------
# Slice 4 — decimal floats
# ---------------------------------------------------------------------------

proc renderFloat(f: float): string =
  ## Shortest round-tripping decimal via stdlib Schubfach (NOT nkdl's
  ## formatter — a sanctioned independent oracle; we test nkdl's float
  ## *decoder*). Ensure a `.`/exponent so it lexes as a float, not an int.
  result = ""
  result.addFloatRoundtrip(f)
  if '.' notin result and 'e' notin result and 'E' notin result:
    result.add ".0"

proc finiteFloatSurfaces*(): Strategy[ValueSurface] =
  ## Finite, non-keyword floats (inf/nan are the keyword slice).
  floats(-1e12, 1e12, allowNan = false).map(proc(f: float): ValueSurface =
    ValueSurface(text: renderFloat(f), value: newFloatValue(f)))

# ---------------------------------------------------------------------------
# Slice 5 — keyword values
# ---------------------------------------------------------------------------

proc keywordSurfaces*(): Strategy[ValueSurface] =
  ## The six `#`-keyword values.
  sampledFrom(@[
    ("#true",  newBoolValue(true)),
    ("#false", newBoolValue(false)),
    ("#null",  newNullValue()),
    ("#inf",   newFloatValue(Inf)),
    ("#-inf",  newFloatValue(NegInf)),
    ("#nan",   newFloatValue(NaN)),
  ]).map(proc(p: (string, KdlValue)): ValueSurface =
    ValueSurface(text: p[0], value: p[1]))
