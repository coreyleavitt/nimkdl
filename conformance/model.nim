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

import std/json

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
    raise newException(Defect, "canonicalKdl(string) lands in the string-projection slice")

func canonicalKdl*(v: KValue): string =
  ## The canonical-KDL text for a *value*, including its `(type)` annotation
  ## prefix when present (e.g. `(u16)80`). For numbers the body is the decimal
  ## text; for the keyword values it is the `#`-prefixed keyword. (Annotation
  ## strings that are not bare identifiers will gain quoting in the string
  ## slice; the integer corpus uses none.)
  let body = canonicalValueBody(v)
  if v.typeAnno.len > 0: "(" & v.typeAnno & ")" & body else: body

func canonicalKdlNode*(n: KNode, depth = 0): string =
  ## Canonical-KDL for a node: `[indent](type)?name (entry)* ( { children } )?`.
  ## Children are indented four spaces per level (the kdl-org canonical style).
  ## The node name is assumed to be a bare identifier for now — quoted/escaped
  ## identifiers arrive with the string/identifier slice.
  var pad = ""
  for _ in 0 ..< depth: pad.add "    "
  result = pad
  if n.typeAnno.len > 0: result.add "(" & n.typeAnno & ")"
  result.add n.name
  for e in n.entries:
    result.add ' '
    case e.kind
    of keArg:  result.add canonicalKdl(e.val)
    of keProp: result.add e.key & "=" & canonicalKdl(e.pval)
  if n.children.len > 0:
    result.add " {\n"
    for c in n.children:
      result.add canonicalKdlNode(c, depth + 1) & "\n"
    result.add pad & "}"

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
    result["kind"] = %(if isReal(v.num): "real" else: "int")
    case v.num.kind
    of nkFinite: result["value"] = %canonicalDecimal(v.num)
    of nkInf:    result["value"] = %"inf"
    of nkNegInf: result["value"] = %"-inf"
    of nkNan:    result["value"] = %"nan"

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
