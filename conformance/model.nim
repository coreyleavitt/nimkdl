## Clean-room KDL document model for the conformance corpus.
##
## A neutral encoding of the spec's data model — a KDL document is a sequence of
## nodes; a node has a name, an optional type annotation, a sequence of entries
## (arguments and properties), and child nodes; a value is a string / number /
## boolean / null with an optional type annotation. Derived from
## `docs/kdl-2.0-spec.md` ALONE.
##
## INVARIANT: this module (and the whole `conformance/` tree, save `adapters/`)
## imports NOTHING from `../src` — not the lexer, parser, AST, numlit, or
## emitter. The corpus we test nkdl against must contain zero nkdl code, or
## "nkdl passes" is circular. The only dependency is the stdlib.
##
## NUMBERS ARE EXACT DECIMAL, not a Nim int64/float. The spec (§Number) draws
## no logical int/float distinction and leaves representation to the
## implementation, so a double-backed oracle is *wrong*, not merely biased:
## `1.23E+1000` exceeds IEEE-754 double range yet the kdl-org canonical corpus
## keeps it verbatim. We therefore store a number as sign + integer-digit
## string + optional fraction-digit string + optional signed exponent-digit
## string (plus the inf/-inf/nan keyword specials). The integer-vs-real *surface
## category* (did it carry a fraction or exponent?) is preserved because
## canonicalization depends on it; radix (hex/oct/bin) is purely a surface
## concern handled by the renderer — the model always holds decimal.

import std/[json, strutils]

type
  KNumKind* = enum
    nkFinite, nkInf, nkNegInf, nkNan

  KNumber* = object
    ## An exact KDL number. `nkFinite` carries the decimal magnitude as digit
    ## strings (already canonical: no underscores, no sign, no radix prefix,
    ## leading zeros stripped to at least one digit). The specials are the
    ## `#inf` / `#-inf` / `#nan` keyword numbers.
    case kind*: KNumKind
    of nkFinite:
      negative*: bool
      intDigits*: string      ## decimal integer part, ≥ 1 digit
      fracDigits*: string      ## fraction digits, `""` == none
      hasExp*: bool
      expNegative*: bool
      expDigits*: string       ## exponent digits, `""` when `not hasExp`
    of nkInf, nkNegInf, nkNan:
      discard

  KValueKind* = enum
    kvNull, kvBool, kvNumber, kvString

  KValue* = object
    ## A KDL value with an optional `(type)` annotation (`""` == none).
    typeAnno*: string
    case kind*: KValueKind
    of kvNull:   discard
    of kvBool:   b*: bool
    of kvNumber: num*: KNumber
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

func isReal*(n: KNumber): bool =
  ## A number is "real" (vs integer) by *surface category*: it carried a
  ## fraction or an exponent. The specials are real too.
  case n.kind
  of nkFinite: n.fracDigits.len > 0 or n.hasExp
  else: true

# ---------------------------------------------------------------------------
# Constructors (terse builders for generators)
# ---------------------------------------------------------------------------

func kNull*(anno = ""): KValue = KValue(kind: kvNull, typeAnno: anno)
func kBool*(b: bool, anno = ""): KValue = KValue(kind: kvBool, b: b, typeAnno: anno)
func kStr*(s: string, anno = ""): KValue = KValue(kind: kvString, s: s, typeAnno: anno)

func num*(negative: bool; intDigits: string; fracDigits = "";
          hasExp = false; expNegative = false; expDigits = "";
          anno = ""): KValue =
  ## Exact finite number from already-canonical decimal digit strings.
  KValue(kind: kvNumber, typeAnno: anno, num: KNumber(
    kind: nkFinite, negative: negative, intDigits: intDigits,
    fracDigits: fracDigits, hasExp: hasExp, expNegative: expNegative,
    expDigits: expDigits))

func kInt*(i: int64, anno = ""): KValue =
  ## Convenience: an integer from a Nim int64 (exact decimal, two's-complement
  ## magnitude so `low(int64)` is representable).
  let neg = i < 0
  let mag = (if neg: (not uint64(i)) + 1'u64 else: uint64(i))
  num(neg, $mag, anno = anno)

func kInf*(anno = ""): KValue = KValue(kind: kvNumber, typeAnno: anno, num: KNumber(kind: nkInf))
func kNegInf*(anno = ""): KValue = KValue(kind: kvNumber, typeAnno: anno, num: KNumber(kind: nkNegInf))
func kNan*(anno = ""): KValue = KValue(kind: kvNumber, typeAnno: anno, num: KNumber(kind: nkNan))

func stripLeadingZeros(d: string): string =
  ## Drop leading `0`s, keeping at least one digit (`"007" -> "7"`, `"0" -> "0"`).
  if d.len == 0: return "0"
  var k = 0
  while k < d.len - 1 and d[k] == '0': inc k
  d[k .. ^1]

func numFromText*(s: string, anno = ""): KValue =
  ## Parse a *clean* decimal literal — `sign? intDigits ('.' frac)? ([eE] sign?
  ## exp)?` with NO underscores or radix prefix — into an exact finite number.
  ## Callers pass already-clean text (stdlib Schubfach output, or an
  ## implementation's number re-rendered to decimal). Canonicalizes: drop a
  ## leading `+`, strip leading zeros in the integer and exponent parts. The
  ## fraction is kept verbatim. This is how the adapter maps an impl's number
  ## onto the exact-decimal oracle, and how `floatSurfaces` pairs text↔value.
  var i = 0
  var negative = false
  if i < s.len and s[i] in {'+', '-'}:
    negative = s[i] == '-'; inc i
  var intD = ""
  while i < s.len and s[i] in {'0' .. '9'}: intD.add s[i]; inc i
  if intD.len == 0: intD = "0"
  var fracD = ""
  if i < s.len and s[i] == '.':
    inc i
    while i < s.len and s[i] in {'0' .. '9'}: fracD.add s[i]; inc i
  var hasExp = false
  var expNeg = false
  var expD = ""
  if i < s.len and s[i] in {'e', 'E'}:
    hasExp = true; inc i
    if i < s.len and s[i] in {'+', '-'}:
      expNeg = s[i] == '-'; inc i
    while i < s.len and s[i] in {'0' .. '9'}: expD.add s[i]; inc i
  doAssert i == s.len, "numFromText: trailing junk in '" & s & "'"
  num(negative, stripLeadingZeros(intD), fracD,
      hasExp, expNeg, (if hasExp: stripLeadingZeros(expD) else: ""), anno)

func arg*(v: KValue): KEntry = KEntry(kind: keArg, val: v)
func prop*(k: string, v: KValue): KEntry = KEntry(kind: keProp, key: k, pval: v)

# ---------------------------------------------------------------------------
# Canonical decimal — the single source of truth for both the canonical-KDL
# projection and the neutral-JSON `value` field.
# ---------------------------------------------------------------------------

func canonicalDecimal*(n: KNumber): string =
  ## Assemble a finite number into its canonical decimal text:
  ## `[-] intDigits [. fracDigits] [E (+|-) expDigits]`. The exponent marker is
  ## always uppercase `E` with an explicit sign (per the kdl-org canonical
  ## corpus: `1e10 => 1E+10`, `1.0e-10 => 1.0E-10`). The fraction is kept
  ## verbatim (no trailing-zero stripping: `1.0 => 1.0`).
  doAssert n.kind == nkFinite
  if n.negative: result.add '-'
  result.add n.intDigits
  if n.fracDigits.len > 0:
    result.add '.'
    result.add n.fracDigits
  if n.hasExp:
    result.add 'E'
    result.add (if n.expNegative: '-' else: '+')
    result.add n.expDigits

func canonicalQuoted*(s: string): string =
  ## The canonical KDL quoted-string form of a value `s` (UTF-8 bytes). Named
  ## escapes for `" \ \n \r \t` + backspace/form-feed, `\u{hh}` for the
  ## disallowed-literal C0 controls and DEL; space and all other printables stay
  ## literal. Transcribed from the kdl-org `all_escapes` canonical case. This is
  ## the single source of truth for both `canonicalKdl(string)` and the
  ## generator's quoted surface renderer.
  result = "\""
  for ch in s:
    case ch
    of '"':    result.add "\\\""
    of '\\':   result.add "\\\\"
    of '\n':   result.add "\\n"
    of '\t':   result.add "\\t"
    of '\r':   result.add "\\r"
    of '\x08': result.add "\\b"
    of '\x0C': result.add "\\f"
    else:
      if ord(ch) < 0x20 or ord(ch) == 0x7F:
        result.add "\\u{" & toLowerAscii(toHex(ord(ch), 2)) & "}"
      else:
        result.add ch
  result.add "\""

func isBarewordIdent*(s: string): bool =
  ## Is `s` a valid KDL identifier string (§Identifier String) — i.e. writable
  ## as a bareword? Used to decide whether the canonical form quotes a string,
  ## node name, property key, or annotation. The kdl-org canonical form barewords
  ## whenever possible (`"arg"` → `arg`, `(type)"str"` → `(type)str`).
  if s.len == 0: return false
  if s in ["true", "false", "null", "inf", "-inf", "nan"]: return false
  for ch in s:           # no non-identifier characters anywhere
    if ch in {'(', ')', '{', '}', '[', ']', '/', '\\', '"', '#', ';', '=',
              ' ', '\t', '\n', '\r'} or ord(ch) < 0x20 or ord(ch) == 0x7F:
      return false
  if s[0] in {'0' .. '9'}: return false        # may not start like a number
  # sign/dot initial rules: must not look like a number
  if s[0] in {'+', '-'}:
    if s.len >= 2 and s[1] in {'0' .. '9'}: return false
    if s.len >= 3 and s[1] == '.' and s[2] in {'0' .. '9'}: return false
  if s[0] == '.' and s.len >= 2 and s[1] in {'0' .. '9'}: return false
  true

func canonicalIdent*(s: string): string =
  ## The canonical KDL spelling of an identifier-position string: a bareword when
  ## it is a valid identifier, otherwise a quoted string.
  if isBarewordIdent(s): s else: canonicalQuoted(s)

func canonicalValueBody(v: KValue): string =
  case v.kind
  of kvNull: "#null"
  of kvBool: (if v.b: "#true" else: "#false")
  of kvNumber:
    case v.num.kind
    of nkFinite: canonicalDecimal(v.num)
    of nkInf:    "#inf"
    of nkNegInf: "#-inf"
    of nkNan:    "#nan"
  of kvString:
    canonicalIdent(v.s)            # bareword when a valid identifier, else quoted

func canonicalKdl*(v: KValue): string =
  ## The canonical-KDL text for a *value*, including its `(type)` annotation
  ## prefix when present (e.g. `(u16)80`). For numbers the body is the decimal
  ## text; for the keyword values it is the `#`-prefixed keyword. Strings and
  ## annotations are barewords when they are valid identifiers, else quoted.
  let body = canonicalValueBody(v)
  if v.typeAnno.len > 0: "(" & canonicalIdent(v.typeAnno) & ")" & body else: body

func canonicalKdlNode*(n: KNode, depth = 0): string =
  ## Canonical-KDL for a node: `[indent](type)?name (entry)* ( { children } )?`.
  ## Children are indented four spaces per level (the kdl-org canonical style).
  ## The node name is assumed to be a bare identifier for now — quoted/escaped
  ## identifiers arrive with the string/identifier slice.
  var pad = ""
  for _ in 0 ..< depth: pad.add "    "
  result = pad
  if n.typeAnno.len > 0: result.add "(" & canonicalIdent(n.typeAnno) & ")"
  result.add canonicalIdent(n.name)
  for e in n.entries:
    result.add ' '
    case e.kind
    of keArg:  result.add canonicalKdl(e.val)
    of keProp: result.add canonicalIdent(e.key) & "=" & canonicalKdl(e.pval)
  if n.children.len > 0:
    result.add " {\n"
    for c in n.children:
      result.add canonicalKdlNode(c, depth + 1) & "\n"
    result.add pad & "}"

func valueNormal*(n: KNumber): string =
  ## The representation-INDEPENDENT canonical VALUE of a number — the equality
  ## oracle. A KDL number denotes a value, not a spelling (spec §Number: "no
  ## logical distinction… up to implementations to represent"), so `12E-56`,
  ## `1.2E-55` and `10000000000`/`1E+10` must all map to one string.
  ##
  ## Integers → plain decimal (already canonical). Finite reals → exact
  ## normalized scientific: one nonzero leading digit, trailing zeros stripped,
  ## explicit signed exponent — computed symbolically on the digit strings, so
  ## no precision is lost. Specials → inf/-inf/nan.
  case n.kind
  of nkInf:    return "inf"
  of nkNegInf: return "-inf"
  of nkNan:    return "nan"
  of nkFinite: discard
  if not isReal(n):
    return canonicalDecimal(n)                 # integer: plain decimal
  # value = (intDigits & fracDigits) × 10^(writtenExp − fracLen)
  var digits = n.intDigits & n.fracDigits
  # exponent stays a BiggestInt; corpus exponents are tiny, and even 1.23E+1000
  # fits — only absurd (>18-digit) exponents would exceed it.
  var e10: BiggestInt = -n.fracDigits.len
  if n.hasExp:
    let w = parseBiggestInt(n.expDigits)
    e10 += (if n.expNegative: -w else: w)
  # strip leading zeros
  var lo = 0
  while lo < digits.len - 1 and digits[lo] == '0': inc lo
  digits = digits[lo .. ^1]
  # strip trailing zeros (each one bumps the exponent)
  var hi = digits.len
  while hi > 1 and digits[hi - 1] == '0': dec hi; inc e10
  digits = digits[0 ..< hi]
  if digits == "0": return "0"                 # exact zero
  let e = e10 + (digits.len - 1)               # exponent of the leading digit
  var mant = $digits[0]
  if digits.len > 1: mant.add "." & digits[1 .. ^1]
  result = (if n.negative: "-" else: "") & mant &
           "E" & (if e < 0: "-" else: "+") & $abs(e)

func canonicalKdlDoc*(doc: KDoc): string =
  ## Canonical-KDL for a whole document — one node per line, trailing newline.
  ## This is the kdl-org `expected_kdl` projection of the corpus.
  for n in doc:
    result.add canonicalKdlNode(n) & "\n"

# ---------------------------------------------------------------------------
# Neutral JSON serialization — the on-disk `expected.json` form.
# ---------------------------------------------------------------------------

func annoJson(anno: string): JsonNode =
  if anno.len == 0: newJNull() else: %anno

func toJson*(v: KValue): JsonNode =
  ## Tagged, language-neutral. A number's `value` is its exact canonical
  ## decimal STRING (specials are "inf"/"-inf"/"nan"); a JSON *number* would
  ## lose bits and cannot hold the specials or magnitudes like `1.23E+1000`.
  ## `kind` is "int" or "real" by surface category.
  result = newJObject()
  result["type"] = annoJson(v.typeAnno)
  case v.kind
  of kvNull:   result["kind"] = %"null";   result["value"] = newJNull()
  of kvBool:   result["kind"] = %"bool";   result["value"] = %v.b
  of kvString: result["kind"] = %"string"; result["value"] = %v.s
  of kvNumber:
    # `value` is the representation-INDEPENDENT canonical value (so equality is
    # exact value-equality, not spelling-equality). `kind` is the int/real
    # surface category.
    result["kind"] = %(if isReal(v.num): "real" else: "int")
    result["value"] = %valueNormal(v.num)

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
                     arg(kStr("hi")), arg(kInf())],
          children: @[KNode(name: "child", entries: @[arg(kBool(true))])]),
  ]
  echo pretty(toJson(doc))
