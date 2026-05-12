## grammar — KDL v2 grammar as data + a table-driven reference interpreter.
##
## ## Why this module exists
##
## The hand-written parser in `parser.nim` is fast and produces good error
## messages, but a parser that's the only authority on what KDL means is
## an oracle of one. If a bug exists in `parser.nim`, no test that uses
## `parser.nim` as ground truth will catch it.
##
## This module gives us a **second, independently-shaped recognizer** for
## the language. The grammar lives as a `Table[string, Rule]` value — a
## *data structure* describing what's recognized, not imperative code.
## The reference interpreter walks that value recursively. The two
## interpretations have maximally different bug surfaces:
##
##   parser.nim         ↔  grammar.nim
##   ---------------------------------------------------
##   imperative RD      ↔  table-driven walk of values
##   mutable cursor     ↔  immutable state snapshots
##   inline AST build   ↔  parse-tree then AST conversion
##   tight error paths  ↔  PEG-style backtracking
##
## Anything they agree on is plausibly correct. Anywhere they disagree on
## conformance corpus inputs (#526) is a bug in at least one of them.
##
## ## Why the grammar is data, not generated code
##
## We could write a macro that emits a parser proc per rule. We chose
## data-driven because:
##
## 1. The grammar is inspectable — you can print it, walk it, transform
##    it. A code-emitting macro produces opaque procs.
## 2. The interpreter is one function (`interpret`) the reader can audit
##    in full. A macro-generated parser scatters logic across N procs,
##    each looking slightly different.
## 3. The cost of indirection is irrelevant — this is the slow oracle,
##    not the production hot path. The fast path is `parser.nim`.
##
## Validation is a plain `validate(g): seq[string]` proc. The canonical
## `KdlV2Grammar` is tied to a `doAssert validate(...).len == 0` at
## module init so typos in `refTo` targets fire on load, not on first
## bad input.
##
## ## Differential testing usage
##
## ```nim
## let viaFast = parse(src)
## let viaRef  = referenceInterpret(src)
## doAssert viaFast.isOk == viaRef.isOk
## if viaFast.isOk:
##   doAssert docEqual(viaFast.get, viaRef.get)
## ```
##
## The conformance harness (#526) runs this comparison on every input
## in the kdl-org test corpus, plus a curated set of locally-interesting
## fragments.

import std/[strutils, tables]

import ./ast
import ./intern
import ./lexer
import ./numlit
import ./spans

# ---------------------------------------------------------------------------
# Rule data model
# ---------------------------------------------------------------------------

type
  RuleKind* = enum
    rkTerm      ## terminal: a specific TokenKind must appear here
    rkRef       ## reference: this rule expands to another by name
    rkSeq       ## sequence: A then B then C
    rkAlt       ## alternation: A or B or C (first match wins, PEG semantics)
    rkOpt       ## optional: A?
    rkStar      ## zero-or-more: A*
    rkPlus      ## one-or-more: A+
    rkEof       ## matches at end-of-input
    rkNot       ## negative lookahead: succeeds if inner fails, consumes nothing
    rkPeek      ## positive lookahead: succeeds if inner matches, consumes nothing

  Rule* = ref object
    ## Grammar rule node. Reference type so we can build self-referential
    ## structures (rules call each other by name, but inline subrules can
    ## reference larger constructs without paying a string-lookup tax).
    label*: string       ## optional human-readable tag for diagnostics
    case kind*: RuleKind
    of rkTerm: terminal*: TokenKind
    of rkRef:  refName*: string
    of rkSeq, rkAlt: parts*: seq[Rule]
    of rkOpt, rkStar, rkPlus, rkNot, rkPeek: inner*: Rule
    of rkEof: discard

  Grammar* = object
    ## A complete grammar definition: rule table plus start-symbol name.
    rules*: Table[string, Rule]
    startRule*: string

# ---------------------------------------------------------------------------
# Combinator constructors
# ---------------------------------------------------------------------------
#
# Plain Nim `func`s, not macros. Building the grammar reads as normal
# code. These produce immutable Rule values; reuse a binding to share
# the same node across multiple rules.

func term*(t: TokenKind): Rule = Rule(kind: rkTerm, terminal: t)
func refTo*(name: string): Rule = Rule(kind: rkRef, refName: name)
func seqOf*(parts: varargs[Rule]): Rule =
  Rule(kind: rkSeq, parts: @parts)
func altOf*(parts: varargs[Rule]): Rule =
  Rule(kind: rkAlt, parts: @parts)
func opt*(inner: Rule): Rule = Rule(kind: rkOpt, inner: inner)
func star*(inner: Rule): Rule = Rule(kind: rkStar, inner: inner)
func plus*(inner: Rule): Rule = Rule(kind: rkPlus, inner: inner)
func neg*(inner: Rule): Rule = Rule(kind: rkNot, inner: inner)
func peek*(inner: Rule): Rule = Rule(kind: rkPeek, inner: inner)
func eof*(): Rule = Rule(kind: rkEof)

func labeled*(r: Rule, name: string): Rule =
  ## Attach a debug label to a rule. Doesn't change semantics; shows up
  ## in error messages and `$grammar` output.
  result = r
  result.label = name

# ---------------------------------------------------------------------------
# The KDL v2 grammar as a value
# ---------------------------------------------------------------------------
#
# This is the spec, expressed as data. Compare to kdl.dev/spec — every
# named production below corresponds to a named non-terminal there. The
# Nim form is necessarily flatter (we don't model lexical-level rules
# like number-literal grammar, because the lexer already handled them).

proc buildKdlGrammar*(): Grammar =
  result = Grammar(rules: initTable[string, Rule](), startRule: "document")

  template rule(name: string, body: Rule) =
    result.rules[name] = body

  # ---- Lexical-level terminals (lexer already classified) ----
  # Available terminal aliases: refer to the TokenKind via `term(tkXxx)`.

  # ---- Value-position rules ----
  rule "rawValue", altOf(
    term(tkString), term(tkRawString),
    term(tkNumber), term(tkKeyword),
    term(tkIdent)            # KDL v2: bare-ident-as-string-value
  )

  rule "typeAnno", seqOf(
    term(tkLParen),
    # type name may be a bare ident, quoted string, or raw string per spec
    altOf(term(tkIdent), term(tkString), term(tkRawString)),
    term(tkRParen)
  )

  rule "value", seqOf(
    opt(refTo("typeAnno")),
    refTo("rawValue")
  )

  rule "name", altOf(term(tkIdent), term(tkString), term(tkRawString))

  rule "property", seqOf(refTo("name"), term(tkEquals), refTo("value"))

  # Slashdash + any following newlines. KDL v2 lets `/-` skip the next
  # thing across newlines (e.g. `node 1 /-\n2 3` reads as `node 1 3`),
  # so wherever slashdash appears we model it together with its
  # trailing whitespace as a single optional-prefix sub-rule.
  rule "slashdashPrefix", seqOf(
    term(tkSlashDash),
    star(term(tkNewline))
  )

  # entry := optional slashdash + (property OR plain value).
  # No separate `argument` rule — interpRule's stamping is single-layer,
  # so passthrough rules (argument → value) collapse and lose their tag.
  # Distinguishing argument-vs-property by tag matters for the tree
  # walker, so we keep them at the same level of alt.
  rule "entry", seqOf(
    opt(refTo("slashdashPrefix")),
    altOf(refTo("property"), refTo("value"))
  )

  # Children block: { node* } — internal newlines consumed between nodes.
  # A REAL children block ends the node (after it, only the terminator is
  # allowed). The slashdashed form acts like a zero-content entry and
  # lives inside the entry-loop (see `slashdashChildren` + node rule).
  # Each child-position is its own named sub-rule so that buildChildrenBlock
  # can locate items via findImmediateAll("childItem") rather than positional
  # indexing into the children rule's structural ParseNode.
  rule "childItem", seqOf(
    opt(refTo("slashdashPrefix")),
    refTo("node"),
    star(term(tkNewline))
  )

  rule "children", seqOf(
    term(tkLBrace),
    star(term(tkNewline)),
    star(refTo("childItem")),
    term(tkRBrace)
  )

  # Slashdashed children block: `/- { ... }` (with optional newlines
  # between the `/-` and the brace) — semantically a no-op; entries may
  # follow it (matches the hand parser's behavior).
  rule "slashdashChildren", seqOf(
    refTo("slashdashPrefix"),
    refTo("children")
  )

  # Terminator: newline, semicolon, EOF, OR positive lookahead at `}` —
  # the children-block loop is what consumes the brace, so the terminator
  # for the last node before `}` just needs to confirm it's there.
  rule "terminator", altOf(
    term(tkNewline),
    term(tkSemicolon),
    peek(term(tkRBrace)),    # last node in a children block
    neg(refTo("anyToken"))   # successful negative lookahead = EOF
  )

  rule "anyToken", altOf(
    term(tkLBrace), term(tkRBrace), term(tkEquals), term(tkSemicolon),
    term(tkLParen), term(tkRParen), term(tkSlashDash), term(tkNewline),
    term(tkIdent), term(tkString), term(tkRawString),
    term(tkNumber), term(tkKeyword)
  )

  # Spec rule (per corpus slashdash_child_block_before_entry_err_fail):
  # entries first, then any mix of slashdashed and real children blocks
  # — but no entries after any children block. At-most-one *real*
  # children block is enforced post-build in buildNode.
  rule "childBlock", altOf(refTo("slashdashChildren"), refTo("children"))

  rule "node", seqOf(
    opt(refTo("typeAnno")),
    refTo("name"),
    star(refTo("entry")),
    star(refTo("childBlock")),
    refTo("terminator")
  )

  rule "document", seqOf(
    star(term(tkNewline)),
    star(seqOf(
      opt(refTo("slashdashPrefix")),
      refTo("node"),
      star(term(tkNewline))
    ))
  )

# Module-level instance for users / tests. Validated by the unit tests
# (see test_grammar.nim) rather than at module init — Grammar contains
# ref objects which don't const-evaluate cleanly enough for a static:
# block.
let KdlV2Grammar* = buildKdlGrammar()

# ---------------------------------------------------------------------------
# Compile-time validation
# ---------------------------------------------------------------------------
#
# Walk the grammar and verify every `rRef("name")` resolves to a rule in
# the table. A typo (`refTo("nodee")`) becomes a compile error here, not
# a runtime miss inside the interpreter.

proc validateRule(r: Rule, names: Table[string, bool], errors: var seq[string]) =
  case r.kind
  of rkRef:
    if r.refName notin names:
      errors.add("undefined rule reference: '" & r.refName & "'")
  of rkSeq, rkAlt:
    for p in r.parts: validateRule(p, names, errors)
  of rkOpt, rkStar, rkPlus, rkNot, rkPeek:
    validateRule(r.inner, names, errors)
  of rkTerm, rkEof: discard

proc validate*(g: Grammar): seq[string] =
  ## Returns a list of human-readable problems with `g` — empty if valid.
  var names = initTable[string, bool]()
  for k, _ in g.rules: names[k] = true
  if g.startRule notin names:
    result.add("start rule '" & g.startRule & "' is not defined")
  for name, rule in g.rules:
    validateRule(rule, names, result)

# Tie the canonical grammar to its validity check at module init.
# `KdlV2Grammar` is built above via plain `let` (the `kdlGrammar` macro
# below would be cleaner but macros need to be defined before their
# call site, and macroing the canonical grammar would force a larger
# reorder of this file). Failing here is a programmer-error crash, not
# user-input handling — it can only fire if buildKdlGrammar() above has
# a typo in a `refTo` target. Asserting at startup catches that the
# moment the module loads.
block:
  let errs = validate(KdlV2Grammar)
  doAssert errs.len == 0,
    "KdlV2Grammar is inconsistent: " & errs.join("; ")


# ---------------------------------------------------------------------------
# Pretty-print the grammar as docs
# ---------------------------------------------------------------------------

proc renderRule(r: Rule, depth = 0): string =
  if r.label.len > 0: result.add("⟨" & r.label & "⟩ ")
  case r.kind
  of rkTerm:
    result.add($r.terminal)
  of rkRef:
    result.add(r.refName)
  of rkSeq:
    var parts: seq[string] = @[]
    for p in r.parts: parts.add(renderRule(p, depth + 1))
    result.add(parts.join(" "))
  of rkAlt:
    var parts: seq[string] = @[]
    for p in r.parts: parts.add(renderRule(p, depth + 1))
    result.add("(" & parts.join(" | ") & ")")
  of rkOpt:
    result.add("(" & renderRule(r.inner, depth + 1) & ")?")
  of rkStar:
    result.add("(" & renderRule(r.inner, depth + 1) & ")*")
  of rkPlus:
    result.add("(" & renderRule(r.inner, depth + 1) & ")+")
  of rkNot:
    result.add("!(" & renderRule(r.inner, depth + 1) & ")")
  of rkPeek:
    result.add("&(" & renderRule(r.inner, depth + 1) & ")")
  of rkEof:
    result.add("EOF")

proc `$`*(g: Grammar): string =
  ## Render the grammar as a human-readable EBNF-ish form. Useful as
  ## executable documentation and for debugging mismatches.
  var lines: seq[string] = @[]
  lines.add("start: " & g.startRule)
  for name, rule in g.rules:
    lines.add(name & " := " & renderRule(rule))
  lines.join("\n")

# ---------------------------------------------------------------------------
# Reference interpreter
# ---------------------------------------------------------------------------
#
# Walks the grammar value recursively. Produces a tree of matched
# token spans; a separate pass converts the tree into a `KdlDoc`.
# This split keeps the recognition logic (driven by the grammar value)
# disjoint from the AST construction logic (hand-coded per rule name).

type
  ParseNode* = ref object
    ## A node in the raw parse tree. Each Rule that matches produces one
    ## of these. `tokens` is the linear sequence of tokens this match
    ## consumed; `children` is the matches from sub-rules in source order.
    ##
    ## Exported so callers (and tests) can drive the interpreter against
    ## a custom Grammar via `interpRule` without going through
    ## `referenceInterpret` and the canonical `KdlV2Grammar`.
    ruleName*: string         ## name of the rule that matched, "" for inline
    consumed*: Slice[int]     ## [start, finish) indices into the token stream
    tokens*: seq[Token]       ## flat list of consumed tokens (for terminals)
    children*: seq[ParseNode] ## child rule matches

  InterpState* = object
    tokens*: seq[Token]
    pos*: int
    grammar*: Grammar
    deepestError*: ParseError
    haveError*: bool

const InterpRecursionCap = 1024

proc interpRule*(s: var InterpState, ruleName: string, depth: int):
    Result[ParseNode, ParseError]

proc interp*(s: var InterpState, r: Rule, depth: int):
    Result[ParseNode, ParseError] =
  ## Walk a rule. Returns the matched parse node on success; updates
  ## `s.pos` to past the match. On failure, leaves `s.pos` at the entry
  ## point (PEG backtracking semantics) and returns Err.
  if depth >= InterpRecursionCap:
    let span =
      if s.pos < s.tokens.len: s.tokens[s.pos].span
      else: pointSpan(StartPosition)
    return err[ParseNode, ParseError](
      initError(peParseDepthExceeded, span, "reference interpreter overflow"))

  let entryPos = s.pos
  case r.kind

  of rkTerm:
    if s.pos < s.tokens.len and s.tokens[s.pos].kind == r.terminal:
      let tok = s.tokens[s.pos]
      inc s.pos
      return ok[ParseNode, ParseError](ParseNode(
        consumed: entryPos ..< s.pos, tokens: @[tok]))
    let span =
      if s.pos < s.tokens.len: s.tokens[s.pos].span
      else: pointSpan(StartPosition)
    let e = initError(peParseUnexpected, span,
                      "expected " & $r.terminal)
    if not s.haveError or entryPos > s.deepestError.span.start.offset:
      s.deepestError = e; s.haveError = true
    return err[ParseNode, ParseError](e)

  of rkEof:
    if s.pos >= s.tokens.len or s.tokens[s.pos].kind == tkEof:
      return ok[ParseNode, ParseError](ParseNode(
        consumed: entryPos ..< s.pos))
    let span = s.tokens[s.pos].span
    return err[ParseNode, ParseError](
      initError(peParseUnexpected, span, "expected end of input"))

  of rkRef:
    return interpRule(s, r.refName, depth + 1)

  of rkSeq:
    var collected: seq[ParseNode] = @[]
    for p in r.parts:
      let res = interp(s, p, depth + 1)
      if res.isErr:
        s.pos = entryPos     # PEG: failed seq rewinds
        return res
      collected.add(res.get)
    return ok[ParseNode, ParseError](ParseNode(
      consumed: entryPos ..< s.pos, children: collected))

  of rkAlt:
    for p in r.parts:
      let savedPos = s.pos
      let res = interp(s, p, depth + 1)
      if res.isOk: return res
      s.pos = savedPos       # try next alternative
    let span =
      if s.pos < s.tokens.len: s.tokens[s.pos].span
      else: pointSpan(StartPosition)
    return err[ParseNode, ParseError](
      initError(peParseUnexpected, span, "no alternative matched"))

  of rkOpt:
    let savedPos = s.pos
    let res = interp(s, r.inner, depth + 1)
    if res.isOk:
      return ok[ParseNode, ParseError](ParseNode(
        consumed: entryPos ..< s.pos, children: @[res.get]))
    s.pos = savedPos
    return ok[ParseNode, ParseError](ParseNode(
      consumed: entryPos ..< s.pos))

  of rkStar:
    var collected: seq[ParseNode] = @[]
    while true:
      let savedPos = s.pos
      let res = interp(s, r.inner, depth + 1)
      if res.isErr:
        s.pos = savedPos
        break
      # Guard against zero-width matches looping forever
      if s.pos == savedPos: break
      collected.add(res.get)
    return ok[ParseNode, ParseError](ParseNode(
      consumed: entryPos ..< s.pos, children: collected))

  of rkPlus:
    var collected: seq[ParseNode] = @[]
    let firstRes = interp(s, r.inner, depth + 1)
    if firstRes.isErr:
      s.pos = entryPos
      return err[ParseNode, ParseError](firstRes.getErr)
    collected.add(firstRes.get)
    while true:
      let savedPos = s.pos
      let res = interp(s, r.inner, depth + 1)
      if res.isErr:
        s.pos = savedPos
        break
      if s.pos == savedPos: break
      collected.add(res.get)
    return ok[ParseNode, ParseError](ParseNode(
      consumed: entryPos ..< s.pos, children: collected))

  of rkNot:
    let savedPos = s.pos
    let res = interp(s, r.inner, depth + 1)
    s.pos = savedPos         # negative lookahead never consumes
    if res.isOk:
      let span =
        if s.pos < s.tokens.len: s.tokens[s.pos].span
        else: pointSpan(StartPosition)
      return err[ParseNode, ParseError](
        initError(peParseUnexpected, span, "unexpected token"))
    return ok[ParseNode, ParseError](ParseNode(
      consumed: entryPos ..< s.pos))

  of rkPeek:
    let savedPos = s.pos
    let res = interp(s, r.inner, depth + 1)
    s.pos = savedPos         # positive lookahead also never consumes
    if res.isErr: return res
    return ok[ParseNode, ParseError](ParseNode(
      consumed: entryPos ..< s.pos))

proc interpRule*(s: var InterpState, ruleName: string, depth: int):
    Result[ParseNode, ParseError] =
  if ruleName notin s.grammar.rules:
    # Grammar references a rule that doesn't exist. `validate()` should
    # catch this at construction time; reaching here means someone bypassed
    # the macro. Return Err rather than panic via KeyError so the
    # diagnostic flows through the same channel as every other parse
    # failure.
    let span =
      if s.pos < s.tokens.len: s.tokens[s.pos].span
      else: pointSpan(StartPosition)
    return err[ParseNode, ParseError](initError(peParseUnexpected, span,
      "grammar references undefined rule '" & ruleName & "'"))
  let r = s.grammar.rules[ruleName]
  let res = interp(s, r, depth + 1)
  if res.isOk:
    var pn = res.get
    pn.ruleName = ruleName
    return ok[ParseNode, ParseError](pn)
  return res

# ---------------------------------------------------------------------------
# Parse tree → KdlDoc
# ---------------------------------------------------------------------------
#
# Walks the parse tree and constructs the AST. One proc per source-of-truth
# rule. Hand-coded — recognition is data-driven, but semantics still need
# human-authored mapping.

proc toSpan(consumed: Slice[int], toks: seq[Token]): Span =
  ## Span covering the token range a ParseNode consumed. Used by
  ## buildNode / buildEntry to produce real positional diagnostics
  ## (rather than the StartPosition-everywhere placeholder).
  if toks.len == 0 or consumed.a >= toks.len:
    return pointSpan(StartPosition)
  let startTok = toks[max(0, consumed.a)]
  let endTok = toks[min(toks.len - 1, max(consumed.a, consumed.b - 1))]
  initSpan(startTok.span.start, endTok.span.finish)

# treeFlatten / findFirst / findAll were dead-by-refactor when buildXxx
# moved to the scope-respecting findImmediate / findImmediateAll family
# in R1 (the unscoped variants picked up matches from nested rule
# scopes — see R1 grilling on H8). Deleted in R2.

proc collectTokens(n: ParseNode): seq[Token] =
  result.add(n.tokens)
  for c in n.children: result.add(collectTokens(c))

proc resolveName(toks: seq[Token], doc: var KdlDoc): InternedStr =
  ## Helper: bareword / quoted string / raw string used as a name.
  if toks.len == 0: return InvalidInterned
  case toks[0].kind
  of tkIdent: toks[0].ident
  of tkString: doc.interner.intern(toks[0].strVal)
  of tkRawString: doc.interner.intern(toks[0].rawVal)
  else: InvalidInterned

proc findImmediate(n: ParseNode, ruleName: string): ParseNode =
  ## Like `findFirst` but only walks the **immediate** children — does not
  ## recurse past unstamped wrappers. Use this when scope matters (e.g.
  ## a node's own typeAnno vs a nested entry's value-typeAnno).
  for c in n.children:
    if c.ruleName == ruleName: return c
    # Recurse only through structural wrappers that don't introduce a
    # new named scope. opt/star/seq matches have ruleName == "".
    if c.ruleName == "":
      let deeper = findImmediate(c, ruleName)
      if deeper != nil: return deeper
  return nil

proc buildValue(valueMatch: ParseNode, doc: var KdlDoc,
                errs: var seq[ParseError]): KdlValue =
  ## Build a KdlValue from a `value` rule match.
  ## Grammar: value := opt(typeAnno) rawValue
  ## So valueMatch.children = [opt(typeAnno) match, rawValue match]
  ##
  ## `errs` is the build-time error accumulator — decode failures
  ## (overflow, malformed float) push into it. `referenceInterpret`
  ## surfaces the first error after the whole build pass completes.
  var anno = InvalidInterned
  let typeAnno = findImmediate(valueMatch, "typeAnno")
  if typeAnno != nil:
    # typeAnno tokens = '(' name ')'
    let toks = collectTokens(typeAnno)
    if toks.len >= 3:
      anno = resolveName(@[toks[1]], doc)
  # The grammar enforces `value := opt(typeAnno) rawValue`, so a value
  # match always has a non-empty rawValue child. No defensive paths —
  # if the invariant ever breaks, an out-of-bounds access here is the
  # right way to surface it (loud bug, not silent null).
  let rawNode = findImmediate(valueMatch, "rawValue")
  let toks = collectTokens(rawNode)
  let v = toks[0]
  case v.kind
  of tkString:
    result = newStringValue(v.strVal, v.span)
  of tkRawString:
    result = newStringValue(v.rawVal, v.span)
  of tkIdent:
    # Bare-ident value: resolves through the doc's interner.
    let identStr = doc.interner.lookup(v.ident)
    if identStr in ReservedBarewords:
      errs.add(initError(peLexReservedKeyword, v.span,
        "reserved keyword '" & identStr & "' cannot be used as a bare value"))
      result = newNullValue(v.span)
    else:
      result = newStringValue(identStr, v.span)
  of tkNumber:
    if looksLikeFloat(v):
      let floatRes = decodeFloatFromToken(v)
      if floatRes.isErr:
        errs.add(floatRes.getErr)
        result = newNullValue(v.span)
      else:
        result = newFloatValue(floatRes.get, v.span)
    else:
      let intRes = decodeIntPromoting(v)
      if intRes.isErr:
        errs.add(intRes.getErr)
        result = newNullValue(v.span)
      else:
        let d = intRes.get
        result = if d.fits64: newIntValue(d.intVal, v.span)
                 else: newBigIntValue(d.bigHi, d.bigLo, d.negative, v.span)
  of tkKeyword:
    case v.keyword
    of kwTrue:   result = newBoolValue(true, v.span)
    of kwFalse:  result = newBoolValue(false, v.span)
    of kwNull:   result = newNullValue(v.span)
    of kwInf:    result = newFloatValue(Inf, v.span)
    of kwNegInf: result = newFloatValue(NegInf, v.span)
    of kwNan:    result = newFloatValue(NaN, v.span)
  else:
    result = newNullValue()
  result.typeAnnotation = anno

proc buildEntry(entryMatch: ParseNode, doc: var KdlDoc,
                tokens: seq[Token],
                errs: var seq[ParseError]): KdlEntry =
  ## Build an entry. Grammar:
  ##   entry := opt(slashdash) (property | value)
  ## So look for a property first; absence means it's an argument-value.
  ## `tokens` is the original token stream — used to compute real spans
  ## on the resulting entry (rather than the StartPosition placeholder
  ## the build* procs used to emit).
  let entrySpan = toSpan(entryMatch.consumed, tokens)
  let prop = findImmediate(entryMatch, "property")
  if prop != nil:
    let nameMatch = findImmediate(prop, "name")
    let key =
      if nameMatch != nil: resolveName(collectTokens(nameMatch), doc)
      else: InvalidInterned
    let valueMatch = findImmediate(prop, "value")
    let v =
      if valueMatch != nil: buildValue(valueMatch, doc, errs)
      else: newNullValue()
    return KdlEntry(kind: keProperty, propName: key, propValue: v,
                    span: entrySpan)
  let valueMatch = findImmediate(entryMatch, "value")
  if valueMatch != nil:
    return KdlEntry(kind: keArgument,
                    argValue: buildValue(valueMatch, doc, errs),
                    span: entrySpan)
  return KdlEntry(kind: keArgument, argValue: newNullValue(),
                  span: entrySpan)

proc buildNode(node: ParseNode, doc: var KdlDoc,
               tokens: seq[Token],
               errs: var seq[ParseError]): KdlNode

proc findImmediateAll(n: ParseNode, ruleName: string): seq[ParseNode]

proc buildChildrenBlock(childrenMatch: ParseNode, doc: var KdlDoc,
                        tokens: seq[Token],
                        errs: var seq[ParseError]): seq[KdlNode] =
  ## Walk the `children` rule match. Grammar (named-rule form):
  ##   children   := '{' star(newline) star(childItem) '}'
  ##   childItem  := opt(slashdashPrefix) node star(newline)
  ## Locate items via `findImmediateAll("childItem")` so a future
  ## reordering of `children`'s siblings doesn't silently mis-index.
  for item in findImmediateAll(childrenMatch, "childItem"):
    if item.children.len < 2: continue
    let slashdashOpt = item.children[0]
    if slashdashOpt.children.len > 0:
      continue  # /-prefixed node — semantically absent
    let nodeMatch = item.children[1]
    result.add(buildNode(nodeMatch, doc, tokens, errs))

proc findImmediateAll(n: ParseNode, ruleName: string): seq[ParseNode] =
  ## Like the deleted `findAll` but only walks structural (unstamped)
  ## descendants — stops at named-rule scope boundaries.
  for c in n.children:
    if c.ruleName == ruleName:
      result.add(c)
    elif c.ruleName == "":
      result.add(findImmediateAll(c, ruleName))

proc buildNode(node: ParseNode, doc: var KdlDoc,
               tokens: seq[Token],
               errs: var seq[ParseError]): KdlNode =
  ## Build a KdlNode from a `node` rule match. Grammar:
  ##   node := opt(typeAnno) name star(entry) opt(children) terminator
  var anno = InvalidInterned
  let typeAnnoMatch = findImmediate(node, "typeAnno")
  if typeAnnoMatch != nil:
    let toks = collectTokens(typeAnnoMatch)
    if toks.len >= 3:
      anno = resolveName(@[toks[1]], doc)

  let nameMatch = findImmediate(node, "name")
  let name =
    if nameMatch != nil: resolveName(collectTokens(nameMatch), doc)
    else: InvalidInterned

  result = KdlNode(name: name, typeAnnotation: anno,
                   entries: @[], children: @[],
                   span: toSpan(node.consumed, tokens))

  for entryMatch in findImmediateAll(node, "entry"):
    let etoks = collectTokens(entryMatch)
    if etoks.len > 0 and etoks[0].kind == tkSlashDash:
      continue  # slashdashed entry
    let newEntry = buildEntry(entryMatch, doc, tokens, errs)
    if newEntry.kind == keProperty:
      # KDL v2: repeated property keys → last-write-wins. Drop any
      # earlier entry with the same key before appending.
      var i = 0
      while i < result.entries.len:
        if result.entries[i].kind == keProperty and
           result.entries[i].propName == newEntry.propName:
          result.entries.delete(i)
        else:
          inc i
    result.entries.add(newEntry)

  # Walk childBlocks — each childBlock is an `altOf(slashdashChildren,
  # children)` so its immediate-child ParseNode tells us which arm. Spec
  # rule (corpus slashdash_multiple_child_blocks): at most one real block
  # contributes; extra real blocks are an error. Slashdashed blocks are
  # semantically absent but must still be structurally consumed.
  # `childBlock` is altOf(slashdashChildren, children); interpRule re-stamps
  # the resulting ParseNode with the outer rule name, clobbering whichever
  # arm matched. Detect the slashdashed arm by looking at the first token
  # of the block — a slashdashed block always starts with `/-`.
  var realChildrenSeen = false
  for childBlock in findImmediateAll(node, "childBlock"):
    let blockToks = collectTokens(childBlock)
    let skipped = blockToks.len > 0 and blockToks[0].kind == tkSlashDash
    if skipped:
      continue  # structurally consumed, semantically absent
    if realChildrenSeen:
      errs.add(initError(peParseUnexpected, result.span,
        "a node may have at most one real children block"))
      continue
    result.children = buildChildrenBlock(childBlock, doc, tokens, errs)
    realChildrenSeen = true

proc buildDoc(root: ParseNode, doc: var KdlDoc,
              tokens: seq[Token],
              errs: var seq[ParseError]) =
  ## Walk the `document` rule match. Grammar:
  ##   document := star(newline) star(seq(opt(slashdash), node, star(newline)))
  ## root.children = [leading_newlines, body_star]
  ## body_star.children = [iter_seq]+; each iter_seq.children = [opt(slashdash), node, star(newline)]
  if root.children.len < 2: return
  let bodyStar = root.children[1]
  for iter in bodyStar.children:
    if iter.children.len < 2: continue
    let slashdashOpt = iter.children[0]
    let isSkipped = slashdashOpt.children.len > 0  # opt matched ⇒ skipped
    if isSkipped: continue
    let nodeMatch = iter.children[1]
    doc.nodes.add(buildNode(nodeMatch, doc, tokens, errs))

# ---------------------------------------------------------------------------
# Semantic validation pass on the built KdlDoc
# ---------------------------------------------------------------------------
#
# Some v2 spec rules are easier to enforce on the AST than in the grammar
# (the grammar would need expressive negative-lookahead with name capture
# to reject specific bareword strings, which we don't model). Each rule
# below is a pure walk over the doc and returns `Result[void, ParseError]`
# consistent with the rest of the parse boundary.

proc checkTokenAdjacency(tokens: seq[Token]): Result[void, ParseError] =
  ## KDL v2 requires whitespace before every entry-start token (string,
  ## raw string, number, keyword, bare identifier). Exemptions: when the
  ## previous token is `=` (property value follows), `(` (type-anno
  ## name follows), `)` (annotated value follows), or `/-` (the entry is
  ## semantically absent but still a fresh phrase). The lexer stamps
  ## `precededByWs` for us; this walk enforces the rule.
  ##
  ## See corpus `zero_space_before_*_fail.kdl`.
  const entryStartKinds = {tkString, tkRawString, tkNumber, tkKeyword, tkIdent}
  const exemptPrev = {tkEquals, tkLParen, tkRParen, tkSlashDash, tkLBrace}
    ## `{` and `;` start a fresh node context where adjacency doesn't
    ## apply; `;` is already handled because the lexer sets `wsPending`
    ## after emitting a separator, so the following token's
    ## `precededByWs` is true and never enters this check.
  for i in 0 ..< tokens.len:
    let cur = tokens[i]
    if cur.kind notin entryStartKinds: continue
    if cur.precededByWs: continue
    if i == 0: continue  # start of stream
    if tokens[i-1].kind in exemptPrev: continue
    return err[void, ParseError](initError(peParseExpected, cur.span,
      "whitespace required before this entry"))
  ok(void, ParseError)

proc checkNoReservedKeywords(nodes: seq[KdlNode], doc: KdlDoc):
    Result[void, ParseError] =
  ## KDL v2 forbids the keyword-shaped barewords (`ReservedBarewords`) in
  ## node-name and property-key positions even without the `#` prefix.
  ## (Bare-ident-as-value rejection is performed inline in `buildValue`
  ## because the AST loses the bare-vs-quoted distinction once stored.)
  ## The hand parser checks these inline; the reference interpreter
  ## checks here after the build.
  for n in nodes:
    let nameStr = doc.interner.lookup(n.name)
    if nameStr in ReservedBarewords:
      return err[void, ParseError](initError(peLexReservedKeyword,
        n.span,
        "reserved keyword '" & nameStr & "' cannot be used as a bare node name"))
    for e in n.entries:
      if e.kind == keProperty:
        let k = doc.interner.lookup(e.propName)
        if k in ReservedBarewords:
          return err[void, ParseError](initError(peLexReservedKeyword,
            e.span,
            "reserved keyword '" & k & "' cannot be used as a property key"))
    let childRes = checkNoReservedKeywords(n.children, doc)
    if childRes.isErr:
      return childRes
  ok(void, ParseError)

proc referenceInterpret*(source: string, sourcePath = "<input>"):
    Result[KdlDoc, ParseError] =
  ## Independent, table-driven recognizer for KDL v2. Returns the same
  ## KdlDoc shape as `parse()` from parser.nim. Used as the differential
  ## oracle in the conformance harness.
  var doc = newDoc(sourcePath)
  let tokens = lex(source, doc.interner)
  for t in tokens:
    if t.kind == tkError:
      return err[KdlDoc, ParseError](t.error)
  let adjCheck = checkTokenAdjacency(tokens)
  if adjCheck.isErr:
    return err[KdlDoc, ParseError](adjCheck.getErr)
  var s = InterpState(tokens: tokens, pos: 0,
                      grammar: KdlV2Grammar, haveError: false)
  let res = interpRule(s, KdlV2Grammar.startRule, 0)
  if res.isErr:
    return err[KdlDoc, ParseError](res.getErr)
  # Must have consumed everything except trailing EOF
  if s.pos < s.tokens.len and s.tokens[s.pos].kind != tkEof:
    let span = s.tokens[s.pos].span
    return err[KdlDoc, ParseError](
      initError(peParseUnexpected, span, "trailing tokens after document"))
  var buildErrs: seq[ParseError] = @[]
  buildDoc(res.get, doc, tokens, buildErrs)
  if buildErrs.len > 0:
    return err[KdlDoc, ParseError](buildErrs[0])
  let semCheck = checkNoReservedKeywords(doc.nodes, doc)
  if semCheck.isErr:
    return err[KdlDoc, ParseError](semCheck.getErr)
  ok[KdlDoc, ParseError](doc)

