# RFC: Spec-coverage testing — generate from the grammar, not from a peer

**Status**: Proposed. Supersedes the ad-hoc, corpus-anchored testing posture
for conformance. Extends the Stage-F property catalog (P1–P12) and the
`grammar.nim` "grammar is data" design. Does **not** change any shipping code
— it adds a test layer.

## TL;DR

The kdl-org conformance corpus (338 cases) is a conformance *floor*, not a
spec *exercise*: it's a fixed, hand-curated set that under-covers the
grammar. Our property suite compounds the gap by being *encode-first* — it
only feeds the decoder bytes our own encoder emits, so the large region of
the *accepted* grammar the encoder never produces (slashdash, comments,
alternate number bases, Unicode whitespace, redundant trivia) is structurally
untested. Three real bugs this session (slashdash decode, cursor `seek`
state-loss, Unicode-ws escape) all live in that blind region; the corpus
caught none.

No implementation is ground truth — kdl-rs misses corpus cases too — so a
differential against any *parser* can't be the oracle: a disagreement is
ambiguous and an agreement can be jointly wrong. The only ground truth is the
**spec grammar**. The resolution: make a **grammar-derived generator** the
oracle. Generation is structurally simpler than parsing (no ambiguity, no
lookahead, no error recovery), so a generator built from the grammar is
*correct by audit* in a way no parser is. It emits `(source, expected_model)`
pairs minted from the spec; the property `parse(source).model ==
expected_model` is checked against the spec, and no parser bug can contaminate
it.

We already have the grammar **as data** (`KdlV2Grammar`). One grammar value,
two interpretations: the existing walk *recognizes*; a new walk *generates*.

## The ground-truth problem (why differential fails)

`decode_A(x) == decode_B(x)` cannot catch a bug both share, and when neither A
nor B is authoritative, a *disagreement* names a culprit only if you already
know who's right. kdl-rs misses ≥1 should-parse corpus file; knus misses 132.
There is no conformant reference parser to anchor against. (This is the
[[testing_differential_blind_spot]] memory, sharpened: differential needs a
trusted side, and here there isn't one.)

Ground truth lives in the **grammar**, not any implementation of it.

## The core idea: a generator is a better oracle than a parser

| | Parser (recognizer) | Generator (producer) |
|---|---|---|
| Ambiguity | must resolve | none — it *chooses* |
| Lookahead / backtracking | yes | none |
| Error recovery | yes | n/a |
| Auditing its correctness | read N procs against the grammar, reason about all inputs | read each branch against one production, for the output it makes |

A generator that walks the grammar and **records the semantic meaning of each
choice as it makes it** yields `(source_text, expected_model)` pairs that are
spec ground truth — because the only thing that ever parses is nkdl, under
test. This is the same shape as P9b ("slashdash injection invariance"), which
already found a bug the examples missed; this RFC generalizes it to the whole
grammar.

## What the existing infrastructure gives us (and the layer boundary)

`grammar.nim` holds `KdlV2Grammar: Table[string, GrammarRule]` — a PEG
combinator tree (`rkTerm/rkRef/rkSeq/rkAlt/rkOpt/rkStar/rkPlus/rkNot/
rkPeek/rkEof`) whose terminals are **`TokenKind`s**. Critically, that means
the grammar-as-data describes the **structural (parser) layer** — tokens →
tree — and is silent about the **lexical layer** — bytes → tokens (number
formats, string escapes, identifier forms, whitespace/comment surface). The
session's bugs map onto this split:

- **slashdash decode** — structural shape is *in* the grammar, but the bug was
  in a *consumer* (`deriveDecode`), not the recognizer. A generator that emits
  slashdash + a property `decode == expected` catches it.
- **Unicode-ws escape** — purely **lexical**, below the token grammar; the
  token grammar treats a string token as already-lexed.

So the generator is **two layers**, mirroring lexer + parser:

1. **Lexical surface generator** (new): produces the byte-level surface forms
   of each token *and the value it denotes* — numbers (dec/hex/oct/bin, signs,
   exponents, underscores), strings (regular / raw `#"…"#` with hash counts /
   `"""…"""` multiline with dedent; every escape incl. `\u{…}` and
   Unicode-whitespace line continuations), keywords (`#true/#false/#null/#inf/
   #-inf/#nan`), identifiers (bareword / quoted / raw, incl. deny-list edges),
   and trivia (ASCII + Unicode whitespace, line/block/nested comments, line
   continuations). KDL-specific; hand-written from the spec, one branch per
   production. **This is where Tier-1 value lands — it would have caught #8.**

2. **Structural generator** (reuses `KdlV2Grammar`): walks the grammar value to
   emit node / args / props / children / type-annotations, and injects
   slashdash at all four positions — recording in the model which spans are
   semantically present. One source of truth (the grammar) for both recognize
   and generate.

The two layers compose: the structural generator asks the lexical generator
for token surface forms; both append to the same `(source, model)` pair.

## Properties over the paired generator

Each is `forAll (source, model) <- kdlGen:` and checked against the model
(spec), never against another parser:

- **Faithful parse**: `parse(source).structural_model == model` (slashdash
  removed, repeated props last-wins, decoded escape/number values exact).
- **Lexical fidelity**: each generated value token decodes to the exact value
  the lexical generator drew (the float-roundtrip, base, escape contracts).
- **Cat 2 ↔ Cat 3 over *source***: `decode[T](source)` agrees with `parse`
  extraction — the encode-free version of P9, which is what was missing.
- **Semantic-transparency / mutation**: injecting a *transparent* feature
  (comment, extra Unicode ws, base swap `0x10`↔`16`, a `/-` junk entry) into a
  valid source must not change the model. Generalizes P9b to every transparent
  production.
- **Round-trip**: `parse(encode(parse(source))) ≅ parse(source)` structurally;
  and byte-exact preserve where applicable.

## Negative generation (the should-reject side, from the grammar)

Take a valid `(source, model)`, apply a single **grammar-breaking** mutation
(violate a production: drop a required terminal, double a unique child block,
put an entry after children, malform an escape, use a reserved bareword) and
assert `parse` rejects with a *located* error. Systematic, derived from the
grammar, vs. the corpus's hand-picked negatives.

## Coverage map (makes "untested" visible)

Instrument the generator so every production / lexical form it *can* emit is
recorded per run; assert the union over a campaign covers 100% of the declared
surface, and emit a coverage report. A production that never fires is a silent
gap — exactly how Unicode-ws-escape and slashdash-decode hid. This is the
mechanism that converts "we found a bug by luck" into "the matrix said this
cell was empty."

## Does the ABNF engine become a separate lib? — No.

We do **not** build a general ABNF engine, for three reasons:

1. **We already have grammar-as-data.** `KdlV2Grammar` is the grammar as an
   inspectable value. The generator *inverts* the same value the recognizer
   consumes. No new engine — a second interpreter over an existing structure.
2. **The lexical layer is KDL-specific and small.** Surface forms for numbers/
   strings/identifiers are simple spec-derived branches, not a general parser-
   generator. A general engine would be over-engineering for ~6 token classes.
3. **If we ever want a byte-level *recognizer* boundary check, npeg already
   exists** (zevv/npeg, in the package index). The KDL grammar transcribes to
   a PEG (~200 lines) with the context-sensitive pieces — multiline dedent,
   raw-string hash-count matching, identifier deny-lists — as npeg captures/
   code. That's an off-the-shelf lib, not a bespoke engine.

The genuinely-reusable kernel — "grammar-as-data that can both recognize and
generate" — *could* be extracted as a sibling lib later (the way `proptest`
is), but `rkTerm` carries a `TokenKind`, so today it's KDL-token-specific.
Extraction is a **possible future RFC**, never a prerequisite here. **The
test-suite value does not depend on writing any engine.**

## Tiers and honest effort

Value is front-loaded: Tiers 1–3 (≈ the first week) would have caught all
three of this session's bugs.

| Tier | Scope | New LOC (est.) | Effort | Catches |
|---|---|---|---|---|
| 0 | Vendor the spec ABNF as `docs/kdl-2.0.abnf`; production→generator/recognizer cross-ref | ~0 (transcribe) | ~0.5 d | — (provenance) |
| 1 | **Lexical surface generator** (paired source+model): numbers, strings+all escapes, keywords, identifiers, trivia | 500–800 | 2–3 d | #8 + the escape/number class |
| 2 | **Structural generator** by inverting `KdlV2Grammar` (nodes/args/props/children/anno + slashdash×4), paired | 400–600 | 2–3 d | slashdash-class, ordering |
| 3 | **Semantic + round-trip property catalog** over the paired generator | 300–500 | 1–2 d | the decode bugs |
| 4 | **Negative generation** (break one production → assert reject) | 200–400 | 1–2 d | over-acceptance |
| 5 | **Coverage map** + report (every production must fire) | ~150 | ~1 d | silent gaps |
| 6 | *(optional, later)* byte-level **boundary recognizer** via npeg-transcribed grammar | 300–600 | 3–5 d | the generator's own blind spots |

**Core (Tiers 0–5): ~1.5–2 focused weeks**, additive, no shipping-code change.
Tier 6 is deferred until 0–5 prove out; it's the only tier that touches an
external lib (npeg), and even then no new engine.

## Relationship to what exists

- **Extends, doesn't replace**, the 338-case corpus (kept as a fixed
  conformance anchor) and P1–P12 (kept; P7/P9 stay but stop being the *only*
  decode coverage).
- **Reuses** `KdlV2Grammar` (structural generator), the `proptest` lib
  (forAll/shrink), and the shrink→fix→pin discipline (counterexamples become
  pinned regressions, then corpus fixtures).
- **`referenceInterpret` stays** as a second *recognizer* — but it's no longer
  asked to be ground truth; the grammar-derived generator is.
- **kdl-rs is demoted** from oracle to *tiebreaker / upstream-contribution
  channel*: when nkdl and the generator agree but kdl-rs disagrees, file it
  upstream. Good citizenship; never load-bearing.

## Risks

| Risk | Mitigation |
|---|---|
| Generator and parser share a spec misreading (self-oracle blind spot) | Vendored ABNF as the written reference each branch cites; Tier-6 npeg recognizer as an independent boundary; negative generation stresses the edges from the other side |
| Generator correctness becomes load-bearing | Keep it dumb: it *only* produces and records; no parsing logic. Audit each branch against one ABNF production. Coverage map proves nothing is silently omitted |
| Context-sensitive productions (dedent, raw-string hashes, deny-lists) resist a clean grammar walk | These already live as hooks in `grammar.nim`; the generator gets matching hooks. They're the 20% hand-coded escape hatches, not a reason to abandon the data-driven 80% |
| Scope creep into a general ABNF engine | Explicitly out of scope (see above). Engine extraction is a separate future RFC |

## Open questions

1. **Shrinking semantics for paired values** — shrinking `source` must keep
   `model` consistent. Likely shrink the *model* (drop a node/arg, simplify a
   value) and re-render `source` from it, rather than shrinking bytes. Confirm
   the proptest integration point.
2. **Where the generator lives** — `tests/kdlgen/` (test-only) vs a `src/`
   module reusable by downstream users who want to fuzz their own `kdl:`
   schemas. Leaning test-only first; promote if a user surface emerges.
3. **Tier 6 trigger** — adopt the npeg boundary recognizer only if Tiers 1–5
   stop finding bugs yet we still lack confidence in the accept/reject
   boundary specifically.
