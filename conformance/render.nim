## conformance/render.nim — clean-room KDL surface renderers.
##
## Pure functions: a neutral value + explicit style choices → KDL source text.
## Imports only the stdlib and the neutral `model` — NOTHING from `../src`.
## The generator (`gen.nim`) draws the style choices and calls these; the
## paired `(text, value)` is then an oracle by construction.
##
## Renderers have documented PRECONDITIONS on the value (e.g. a raw string body
## must not collide with the closing `"#…`); the generator is responsible for
## only selecting a style whose preconditions the value satisfies.

import std/[strutils, formatfloat]
import ./model

type
  ValueSurface* = object
    ## A rendered value paired with the exact model value it denotes — an oracle
    ## by construction. Produced by `gen.nim` (random) and `groups.nim`
    ## (covering-array instantiation); both share this shape.
    text*:  string
    value*: KValue
  NodeSurface* = object
    text*: string
    node*: KNode
  DocSurface* = object
    ## A whole-document surface (text) paired with its exact model. Node-shaped
    ## covering-array witnesses (structural group) produce this directly, rather
    ## than wrapping a single value.
    text*: string
    doc*:  KDoc

# ---------------------------------------------------------------------------
# Numbers   (grammar: number / decimal / hex / octal / binary / integer)
# ---------------------------------------------------------------------------

func magnitudeDigits*(mag: uint64, base: int, upperHex: bool): string =
  let ds = if upperHex: "0123456789ABCDEF" else: "0123456789abcdef"
  if mag == 0'u64: return "0"
  var m = mag
  while m > 0'u64:
    result = ds[int(m mod uint64(base))] & result
    m = m div uint64(base)

func basePrefix(base: int): string =
  (case base
   of 16: "0x"
   of 8:  "0o"
   of 2:  "0b"
   else:  "")

type IntStyle* = object
  base*: int            ## 10 | 16 | 8 | 2
  upperHex*: bool
  signMode*: int        ## 0 none | 1 '+' | 2 '-'
  underscores*: seq[int]  ## `_`-run length (0..) after each magnitude digit

func renderInt*(i: int64, st: IntStyle): string =
  ## `sign? prefix? digit (digit|'_')*`. The sign is derived from `signMode`,
  ## independent of `i`'s sign — the generator pairs them so the VALUE matches.
  let mag = (if i < 0: uint64(-i) else: uint64(i))
  let digits = magnitudeDigits(mag, st.base, st.upperHex)
  let signTxt = ["", "+", "-"][st.signMode]
  result = signTxt & basePrefix(st.base)
  for k in 0 ..< digits.len:
    result.add digits[k]
    if k < st.underscores.len:
      for _ in 0 ..< st.underscores[k]: result.add '_'

func renderFloat*(f: float, plus: bool): string =
  ## Finite float via stdlib Schubfach (NOT nkdl). Ensures a `.`/exponent so it
  ## lexes as a float; an optional leading `+`. Precondition: f is finite.
  var body = ""
  body.addFloatRoundtrip(f)
  if '.' notin body and 'e' notin body and 'E' notin body: body.add ".0"
  result = (if plus and body.len > 0 and body[0] notin {'-', '+'}: "+" else: "") & body

type FloatStyle* = object
  ## Explicit decimal-float surface choices. Built from digit STRINGS, never a
  ## Nim float — so the rendered text and the model value share exact digits and
  ## no precision is ever lost (`1.23E+1000` renders as written).
  negative*, plus*: bool      ## leading sign; at most one true
  intDigits*: string          ## integer part (≥ 1 digit)
  fracDigits*: string         ## fraction digits, `""` == no fraction
  hasExp*: bool
  expUpper*: bool             ## `E` vs `e`
  expPlus*: bool              ## explicit `+` on a positive exponent
  expNegative*: bool          ## `-` exponent (mutually exclusive with expPlus)
  expDigits*: string          ## exponent digits (when hasExp)
  underscore*: bool           ## insert one `_` inside the integer part

func withUnderscore(digits: string): string =
  ## Insert one `_` after the first digit (`"25" -> "2_5"`). Precondition: ≥ 2 digits.
  digits[0] & "_" & digits[1 .. ^1]

func renderFloatSurface*(st: FloatStyle): string =
  ## `sign? intDigits ('.' frac)? ((e|E) sign? exp)?`. The optional single `_`
  ## lands in the first multi-digit component (fraction if present, else
  ## exponent) — the integer part is a single digit here. Precondition: a float
  ## must carry a fraction or an exponent (the generator enforces it).
  if st.negative: result.add '-'
  elif st.plus:   result.add '+'
  result.add st.intDigits
  var usLeft = st.underscore
  if st.fracDigits.len > 0:
    result.add '.'
    if usLeft and st.fracDigits.len >= 2:
      result.add withUnderscore(st.fracDigits); usLeft = false
    else:
      result.add st.fracDigits
  if st.hasExp:
    result.add (if st.expUpper: 'E' else: 'e')
    if st.expNegative: result.add '-'
    elif st.expPlus:   result.add '+'
    if usLeft and st.expDigits.len >= 2:
      result.add withUnderscore(st.expDigits); usLeft = false
    else:
      result.add st.expDigits

func renderKeywordValue*(v: KValue): string =
  ## `#true|#false|#null|#inf|#-inf|#nan`. Precondition: v is bool/null, or a
  ## non-finite number (one of the inf/-inf/nan specials).
  case v.kind
  of kvBool: (if v.b: "#true" else: "#false")
  of kvNull: "#null"
  of kvNumber:
    case v.num.kind
    of nkInf:    "#inf"
    of nkNegInf: "#-inf"
    of nkNan:    "#nan"
    of nkFinite: "#?"        # unreachable given the precondition
  else: "#?"                 # unreachable

# ---------------------------------------------------------------------------
# Strings   (grammar: quoted-string / string-character / escapes)
# ---------------------------------------------------------------------------

func renderStrEscaped*(s: string): string =
  ## The canonical quoted-string surface. Delegates to `model.canonicalQuoted`
  ## (single source of truth) — a quoted-escaped surface IS the canonical form.
  canonicalQuoted(s)

func renderMultiline*(value: string, indentWidth: int, raw: bool): string =
  ## A multi-line string surface (§Multi-line String). The generation direction
  ## of the dedent rule: every content line is indented by `indentWidth` spaces,
  ## and the closing `"""` sits on its own line at that same indent — so a parser
  ## that strips the closing line's whitespace prefix recovers exactly `value`.
  ## `raw` wraps with a single `#` (raw multi-line — no escapes). Precondition
  ## (generator's job): `value` has no blank lines and, when raw, no `"""#`.
  let prefix = repeat(' ', indentWidth)
  let h = (if raw: "#" else: "")
  result = h & "\"\"\"\n"
  for line in value.split('\n'):
    result.add prefix & line & "\n"
  result.add prefix & "\"\"\"" & h

func renderRawString*(s: string, hashes: int): string =
  ## `#…#"…"#…#` raw form with `hashes` leading/trailing `#`. No escapes — the
  ## body is emitted verbatim. Precondition (the generator's job): `s` contains
  ## neither a disallowed-literal code point nor the closing delimiter `"` +
  ## `hashes`×`#`, and is single-line.
  let pounds = repeat('#', hashes)
  pounds & "\"" & s & "\"" & pounds

# ---------------------------------------------------------------------------
# Type annotation + value dispatch
# ---------------------------------------------------------------------------

func annoPrefix*(anno: string): string =
  ## `(type)` prefix. The generator supplies `anno` as a valid identifier
  ## string (rendered bareword here; quoted-anno is a later style).
  if anno.len == 0: "" else: "(" & anno & ")"

when isMainModule:
  # Clean-room proof: neutral values → surface text, stdlib only.
  echo renderInt(16, IntStyle(base: 16, upperHex: true, signMode: 1, underscores: @[0, 1]))
  echo renderFloat(1.5, plus = true)
  echo renderKeywordValue(kNegInf())
  echo annoPrefix("u16") & renderInt(80, IntStyle(base: 10))
  echo renderStrEscaped("a\tb\"c\x01")
