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

# ---------------------------------------------------------------------------
# Numbers   (grammar: number / decimal / hex / octal / binary / integer)
# ---------------------------------------------------------------------------

func magnitudeDigits(mag: uint64, base: int, upperHex: bool): string =
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

func renderKeywordValue*(v: KValue): string =
  ## `#true|#false|#null|#inf|#-inf|#nan`. Precondition: v is bool/null, or a
  ## non-finite float.
  case v.kind
  of kvBool: (if v.b: "#true" else: "#false")
  of kvNull: "#null"
  of kvFloat:
    if v.f != v.f: "#nan"
    elif v.f == Inf: "#inf"
    elif v.f == NegInf: "#-inf"
    else: "#" & "?"          # unreachable given the precondition
  else: "#?"                 # unreachable

# ---------------------------------------------------------------------------
# Strings   (grammar: quoted-string / string-character / escapes)
# ---------------------------------------------------------------------------

func renderStrEscaped*(s: string): string =
  ## `"…"` with named escapes for the special chars and `\u{HH}` for the
  ## disallowed-literal C0 controls + DEL. Works for ANY ASCII string (no
  ## precondition). Input is treated as bytes; multi-byte UTF-8 passes through.
  result = "\""
  for ch in s:
    case ch
    of '"':    result.add "\\\""
    of '\\':   result.add "\\\\"
    of '\n':   result.add "\\n"
    of '\t':   result.add "\\t"
    of '\r':   result.add "\\r"
    of '\b':   result.add "\\b"
    of '\x0C': result.add "\\f"
    else:
      if ord(ch) < 0x20 or ord(ch) == 0x7F:   # disallowed-literal ⇒ must escape
        result.add "\\u{" & toLowerAscii(toHex(ord(ch), 2)) & "}"
      else:
        result.add ch
  result.add "\""

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
  echo renderKeywordValue(kFloat(NegInf))
  echo annoPrefix("u16") & renderInt(80, IntStyle(base: 10))
  echo renderStrEscaped("a\tb\"c\x01")
