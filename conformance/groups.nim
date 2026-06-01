## conformance/groups.nim — spec-transcribed surface interaction groups and
## their instantiators (clean-room: coverage + render + model, NO `../src`).
##
## Each grammar production whose surface has interacting choices is declared as
## an `InteractionGroup` (factors + constraints) PLUS an `instantiate*` that
## turns one covering-array row into a concrete `(text, value)` witness. The
## group is the spec transcription in the *recognition* direction (what choices
## exist); the instantiator is the same production in the *generation*
## direction (knows the value by construction). Keeping them adjacent makes the
## production the single source of truth for both coverage and witnesses.
##
## A value's surface factors split into two kinds, and the distinction is
## load-bearing:
##   • SEMANTIC factors change the model value (a number's sign);
##   • PRESENTATION factors are pure spelling (base, hex-case, underscores).
## The covering array covers both; only presentation factors are subject to the
## metamorphic "same value under different surface" invariant.

import std/strutils    # parseInt
import ./model
import ./render
import ./coverage

# ---------------------------------------------------------------------------
# Integer  (grammar §Number: decimal / hex / octal / binary, sign, underscores)
# ---------------------------------------------------------------------------

const intRepr = 42'i64
  ## Representative magnitude: ≥ 2 digits in every base (so underscores have a
  ## gap to sit in) and contains a hex letter (0x2A) so hex-case is observable.

proc integerGroup*(): InteractionGroup =
  ## base{dec,hex,oct,bin} × hexcase{lower,upper,∅} × sign{none,plus,minus}
  ## × underscore{yes,no}, pairwise, constrained: hex-case exists ⇔ base = hex
  ## (a decimal/octal/binary number has no notion of letter case).
  InteractionGroup(
    name: "integer",
    t: 2,
    factors: @[
      Factor(name: "int.base",       levels: @["dec", "hex", "oct", "bin"]),
      Factor(name: "int.hexcase",    levels: @["lower", "upper", ""]),  # "" = absent
      Factor(name: "int.sign",       levels: @["none", "plus", "minus"]),
      Factor(name: "int.underscore", levels: @["yes", "no"]),
    ],
    valid: proc(c: Tagset): bool =
      (lvl(c, "int.base") == "hex") == (lvl(c, "int.hexcase") != ""))

proc instantiateInteger*(row: Tagset): ValueSurface =
  ## Render one integer covering-array row to a witness. Presentation factors
  ## (base/case/underscore) shape only the text; the sign factor is semantic and
  ## flows into the model value, so the pair stays an oracle by construction.
  let base = case lvl(row, "int.base")
             of "hex": 16
             of "oct": 8
             of "bin": 2
             else: 10
  let upperHex = lvl(row, "int.hexcase") == "upper"
  let signMode = case lvl(row, "int.sign")
                 of "plus": 1
                 of "minus": 2
                 else: 0
  let value = (if signMode == 2: -intRepr else: intRepr)
  let nDigits = magnitudeDigits(uint64(intRepr), base, upperHex).len
  var underscores = newSeq[int](nDigits)
  if lvl(row, "int.underscore") == "yes" and nDigits >= 2:
    underscores[0] = 1            # one `_`-run after the first magnitude digit
  let st = IntStyle(base: base, upperHex: upperHex,
                    signMode: signMode, underscores: underscores)
  ValueSurface(text: renderInt(value, st), value: kInt(value))

# ---------------------------------------------------------------------------
# Float  (grammar §Number decimal: intDigits ('.' frac)? ((e|E) sign? exp)?)
# ---------------------------------------------------------------------------

const
  # Single-digit mantissa (kdl-org canonical discipline) and few-significant-
  # digit, double-EXACT magnitudes (1.25, 1e10, 1.25e10 are all < 2^53 and
  # dyadic-friendly), so a double-based impl reproduces the exact value and the
  # value normal form matches. The underscore lives in the fraction or exponent.
  fIntDigits  = "1"
  fFracDigits = "25"   ## 1.25 exact
  fExpDigits  = "10"   ## 1e10 / 1.25e10 exact, and ≥ 2 digits to host a `_`

proc floatGroup*(): InteractionGroup =
  ## shape{frac,exp,both} × sign{none,plus,minus} × expcase{e,E,∅}
  ## × expsign{none,plus,minus,∅} × underscore{yes,no}, pairwise.
  ## A float must carry a fraction or an exponent, so `shape` is SEMANTIC; the
  ## exponent marker case and sign exist ⇔ the shape has an exponent.
  InteractionGroup(
    name: "float",
    t: 2,
    factors: @[
      Factor(name: "float.shape",      levels: @["frac", "exp", "both"]),
      Factor(name: "float.sign",       levels: @["none", "plus", "minus"]),
      Factor(name: "float.expcase",    levels: @["e", "E", ""]),          # "" = no exponent
      Factor(name: "float.expsign",    levels: @["none", "plus", "minus", ""]),
      Factor(name: "float.underscore", levels: @["yes", "no"]),
    ],
    valid: proc(c: Tagset): bool =
      let hasExp = lvl(c, "float.shape") in ["exp", "both"]
      (lvl(c, "float.expcase") != "") == hasExp and
      (lvl(c, "float.expsign") != "") == hasExp)

proc instantiateFloat*(row: Tagset): ValueSurface =
  ## Render one float covering-array row to a witness. Presentation factors
  ## (exponent case, explicit `+`, underscore) shape only the text; the leading
  ## sign and the exponent sign are semantic and flow into the model value.
  let shape = lvl(row, "float.shape")
  let hasFrac = shape in ["frac", "both"]
  let hasExp  = shape in ["exp", "both"]
  let negative = lvl(row, "float.sign") == "minus"
  let expNeg = lvl(row, "float.expsign") == "minus"
  let st = FloatStyle(
    negative: negative,
    plus: lvl(row, "float.sign") == "plus",
    intDigits: fIntDigits,
    fracDigits: (if hasFrac: fFracDigits else: ""),
    hasExp: hasExp,
    expUpper: lvl(row, "float.expcase") == "E",
    expPlus: lvl(row, "float.expsign") == "plus",
    expNegative: expNeg,
    expDigits: (if hasExp: fExpDigits else: ""),
    underscore: lvl(row, "float.underscore") == "yes")
  let value = num(negative, fIntDigits,
                  (if hasFrac: fFracDigits else: ""),
                  hasExp, expNeg, (if hasExp: fExpDigits else: ""))
  ValueSurface(text: renderFloatSurface(st), value: value)

# ---------------------------------------------------------------------------
# Registry — every value-level group with its instantiator. emit.nim and the
# nkdl adapter iterate this so a new group is wired in one place.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# String  (grammar §String: single-line quoted + raw variants. Multi-line +
# dedent, \u and escaped-whitespace escapes are the string-v2 slice — distinct
# sub-grammars, tracked separately.)
# ---------------------------------------------------------------------------

proc stringContent(level: string): string =
  ## Representative values, each expressible in BOTH quoted and raw single-line
  ## form (no newline / disallowed-literal), chosen to exercise the escape↔raw
  ## distinction: a bare `"` (quoted must escape, raw must not) and a bare `\`.
  case level
  of "quote":     "ab\"cd"
  of "backslash": "ab\\cd"
  else:           "abc"

proc stringGroup*(): InteractionGroup =
  ## content{simple,quote,backslash} × style{quoted,raw} × hashes{one,two,∅},
  ## pairwise, constrained: the raw `#`-count exists ⇔ the style is raw.
  ## `content` is SEMANTIC (it is the value); style and hash-count are surface.
  InteractionGroup(
    name: "string",
    t: 2,
    factors: @[
      Factor(name: "str.content", levels: @["simple", "quote", "backslash"]),
      Factor(name: "str.style",   levels: @["quoted", "raw"]),
      Factor(name: "str.hashes",  levels: @["one", "two", ""]),   # "" = quoted
    ],
    valid: proc(c: Tagset): bool =
      (lvl(c, "str.style") == "raw") == (lvl(c, "str.hashes") != ""))

proc instantiateString*(row: Tagset): ValueSurface =
  ## Render one string covering-array row to a witness. `content` is the decoded
  ## value (semantic); `style`/`hashes` shape only the surface text.
  let value = stringContent(lvl(row, "str.content"))
  let text =
    if lvl(row, "str.style") == "raw":
      renderRawString(value, if lvl(row, "str.hashes") == "two": 2 else: 1)
    else:
      renderStrEscaped(value)
  ValueSurface(text: text, value: kStr(value))

# ---------------------------------------------------------------------------
# Keyword values  (§Boolean #true/#false, §Null #null, §Keyword Numbers
# #inf/#-inf/#nan). Each keyword has a single spelling, so the only surface
# variation is an optional type annotation — paired here so the group exercises
# the keyword × annotation interaction (annotation immediately before a keyword).
# ---------------------------------------------------------------------------

proc keywordValue(kind, anno: string): KValue =
  case kind
  of "true":    kBool(true, anno)
  of "false":   kBool(false, anno)
  of "null":    kNull(anno)
  of "inf":     kInf(anno)
  of "neg-inf": kNegInf(anno)
  else:         kNan(anno)

proc keywordGroup*(): InteractionGroup =
  ## kind{true,false,null,inf,-inf,nan} × annotated{yes,no}, pairwise.
  InteractionGroup(
    name: "keyword",
    t: 2,
    factors: @[
      Factor(name: "kw.kind",
             levels: @["true", "false", "null", "inf", "neg-inf", "nan"]),
      Factor(name: "kw.annotated", levels: @["yes", "no"]),
    ])

proc instantiateKeyword*(row: Tagset): ValueSurface =
  ## `(type)? #keyword`. The keyword's spelling is fixed; the annotation is the
  ## only surface variation. inf/-inf/nan map to the model's number specials.
  let anno = (if lvl(row, "kw.annotated") == "yes": "type" else: "")
  let value = keywordValue(lvl(row, "kw.kind"), anno)
  ValueSurface(text: annoPrefix(anno) & renderKeywordValue(value), value: value)

# ---------------------------------------------------------------------------
# Type annotation  (grammar §Type Annotation: `(` ws? string ws? `)` prefix on a
# value, separable from its target by whitespace; the string may be bareword or
# quoted). All surface variants denote the SAME tag → metamorphic. Canonical is
# a tight bareword annotation. (Node annotations are a small follow-up.)
# ---------------------------------------------------------------------------

proc annotationGroup*(): InteractionGroup =
  ## style{bareword,quoted} × innerWs{none,spaced} × gapWs{none,spaced}
  ## × valueKind{int,string}, pairwise, unconstrained. The annotated value is
  ## the semantic content; everything else is surface that canonicalizes away.
  InteractionGroup(
    name: "annotation",
    t: 2,
    factors: @[
      Factor(name: "anno.style",     levels: @["bareword", "quoted"]),
      Factor(name: "anno.innerWs",   levels: @["none", "spaced"]),
      Factor(name: "anno.gapWs",     levels: @["none", "spaced"]),
      Factor(name: "anno.valueKind", levels: @["int", "string"]),
    ])

proc instantiateAnnotation*(row: Tagset): ValueSurface =
  ## `(` ws? type ws? `)` ws? value. The tag is always `type`; innerWs/gapWs/
  ## style shape only the surface. The value carries `typeAnno = "type"`.
  let inner = (if lvl(row, "anno.style") == "quoted": "\"type\"" else: "type")
  let pad = (if lvl(row, "anno.innerWs") == "spaced": " " else: "")
  let gap = (if lvl(row, "anno.gapWs") == "spaced": " " else: "")
  let (valText, value) =
    if lvl(row, "anno.valueKind") == "string": ("\"s\"", kStr("s", "type"))
    else: ("1", kInt(1, "type"))
  ValueSurface(text: "(" & pad & inner & pad & ")" & gap & valText, value: value)

# ---------------------------------------------------------------------------
# Structural  (grammar: base-node := type? string (node-prop-or-arg)*
# node-children?  + the document being a list of nodes). NODE-SHAPED witnesses,
# not value-wrapped. The factors interact — `children × second` is the
# slashdash×children-checkpoint bug home (an entry/node after a children block).
# ---------------------------------------------------------------------------

proc structuralGroup*(): InteractionGroup =
  ## args{0,1,2} × props{yes,no} × children{yes,no} × second{yes,no}, pairwise,
  ## unconstrained (every shape is a legal document). `second` is a
  ## document-level factor: is there a sibling node after the primary one.
  InteractionGroup(
    name: "structural",
    t: 2,
    factors: @[
      Factor(name: "struct.args",     levels: @["0", "1", "2"]),
      Factor(name: "struct.props",    levels: @["yes", "no"]),
      Factor(name: "struct.children", levels: @["yes", "no"]),
      Factor(name: "struct.second",   levels: @["yes", "no"]),
    ])  # valid: nil ⇒ all configurations are realizable

proc instantiateStructural*(row: Tagset): DocSurface =
  ## Build a node-shaped witness directly (text + KDoc). Representative content:
  ## positional args 1/2, property `k=3`, a bare child `child`, a sibling
  ## `node2`. The crucial interaction row (children ∧ second) yields
  ## `node … { child }` followed by `node2` — entries/nodes after a child block.
  let nArgs    = parseInt(lvl(row, "struct.args"))
  let hasProp  = lvl(row, "struct.props") == "yes"
  let hasKids  = lvl(row, "struct.children") == "yes"
  let hasSecond = lvl(row, "struct.second") == "yes"

  var entries: seq[KEntry]
  if nArgs >= 1: entries.add arg(kInt(1))
  if nArgs >= 2: entries.add arg(kInt(2))
  if hasProp:    entries.add prop("k", kInt(3))
  var primary = KNode(name: "node", entries: entries)
  if hasKids: primary.children = @[KNode(name: "child")]
  var doc: KDoc = @[primary]
  if hasSecond: doc.add KNode(name: "node2")

  var t = "node"
  if nArgs >= 1: t.add " 1"
  if nArgs >= 2: t.add " 2"
  if hasProp:    t.add " k=3"
  if hasKids:    t.add " {\n    child\n}"
  t.add "\n"
  if hasSecond:  t.add "node2\n"
  DocSurface(text: t, doc: doc)

# ---------------------------------------------------------------------------
# Registry — every group with its instantiator. emit.nim and the nkdl adapter
# iterate these so a new group is wired in one place. Value groups wrap their
# witness as `node <value>`; doc groups produce a whole document directly.
# ---------------------------------------------------------------------------

type
  Instantiator* = proc(row: Tagset): ValueSurface {.nimcall.}
  NodeInstantiator* = proc(row: Tagset): DocSurface {.nimcall.}
  ValueGroup* = tuple[group: InteractionGroup, instantiate: Instantiator]
  DocGroup* = tuple[group: InteractionGroup, instantiate: NodeInstantiator]

proc valueGroups*(): seq[ValueGroup] =
  @[(integerGroup(),    Instantiator(instantiateInteger)),
    (floatGroup(),      Instantiator(instantiateFloat)),
    (stringGroup(),     Instantiator(instantiateString)),
    (keywordGroup(),    Instantiator(instantiateKeyword)),
    (annotationGroup(), Instantiator(instantiateAnnotation))]

proc docGroups*(): seq[DocGroup] =
  @[(structuralGroup(), NodeInstantiator(instantiateStructural))]
