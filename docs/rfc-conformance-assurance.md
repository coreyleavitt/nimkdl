# RFC: Conformance Assurance Hierarchy

**Status:** north-star design record (tiers vary: covering-array LANDED;
random/​k-path/​Lean are research tracks). See `conformance/README.md` for the
built artifact.

## Thesis

KDL conformance assurance is a **layered stack**, not one technique. Each tier
attacks a *different trust gap*; none subsumes the others. The corpus we ship
(GH #27) is the portable middle of the stack; formal proof sits above it, per-
impl fuzzing below. The unifying invariant: **everything derives from one
spec-faithful model, and the oracle is generation-by-construction** (the
generator builds a value and renders it, so `(input, expected)` is an oracle
with no parser in the loop — which is exactly what makes every tier portable).

## The stack (strongest → weakest trust)

```
Lean: formal spec + proven reference recognizer   ── true ∀-proof
   ↓ corpus DERIVED from the same formal spec        (provably spec-faithful)
z3 / k-path grammar coverage (SMT)                 ── systematic, portable, depth k
random sampleN (seeded)                            ── statistical breadth
fuzz / symex on a specific parser                  ── per-impl over-acceptance → pins
```

### Tier 0 — Lean formal proof (STARTED — `proofs/lean/`)

Formalize KDL's grammar + data model in Lean4 as **ground truth**, then prove a
reference recognizer/parser **sound** (`parse s = Ok t → t` derives `s`),
**complete** (`s ∈ L → parse s` succeeds), and **denotation-correct** (decoded
value = spec denotation). This is `∀`-proof, not statistics — it *replaces* the
corpus argument *for the proven artifact*.

**Foundation proven (4 fragments, all axiom-clean — `propext`/`Quot.sound`, no
`sorryAx`; `proofs/lean/run.sh`):**
- `Value.lean` — keyword values: soundness + completeness.
- `Number.lean` — decimal numbers: digit faithfulness (`ofDigits_toDigits`, by
  induction) + char round-trip + full surface round-trip `parse (render n) = some n` ∀ n.
- `Str.lean` — quoted strings with escapes: `parse (render s) = some s` ∀ s.
- `Doc.lean` — **recursion**: brace-nested trees, `parse (renderForest f) = some f`
  ∀ f — a verified recursive-descent parser (fuel-based for structural
  termination; mutual induction; `size ≤ render-length` supplies fuel).

So the toolchain, the render/parse/round-trip shape, induction, finite-type
`decide`, and *genuine recursion* are all demonstrated. **Remaining (research-
grade):** combine the fragments into the full node grammar (name + args +
children together), then the hard spec machinery — multiline **dedent**,
matched-hash raw strings, **Unicode** property tables, the ident-vs-number
disambiguation. Those are the sinks; the skeleton is in place.

Precedent (it's expressible): CompCert's verified LR(1) parser, EverParse/3D
(F*, shipping binary parsers), Narcissus, Verbatim/Verbatim++ (verified lexer).
Lean4 is well-suited (dependent types for derivation indices + decidability).

KDL-specific hard parts: Unicode (UTF-8 decode + property/disallowed-codepoint/
bidi tables — finite, transcribable), and the **non-CFG bits** — multiline
**dedent**, matched-hash raw strings, slashdash, the ident-vs-number
disambiguation. Cost is research-paper scale; Unicode + dedent are the sinks.

**Crucial:** a proof proves the *proven artifact* against the *formal spec*. It
does NOT prove the shipped `nkdl` (Nim) unless nkdl is that artifact. It
relocates trust to (i) the formalization being faithful, and (ii) the model→impl
gap. **Those two residues are exactly what the corpus + cross-impl validate** —
so proof and corpus compose. The high-leverage tractable target is *not* "prove
nkdl" (you'd lose the optimized impl) but "**formalize the spec + prove a
reference recognizer**," with nkdl validated against that authority by the corpus.

### Tier 1 — z3 / k-path grammar coverage (SMT)

Encode the grammar + validity constraints as SMT; ask z3 for satisfying
derivations, *adding* coverage demands to force hard-to-reach combinations
(e.g. an uppercase-hex negative integer as a property value inside a child
block N levels deep). Completeness metric: **k-path grammar coverage** (Havrikov
& Zeller, "Systematically Covering Input Structure") — a tunable depth knob.

This is the **generalization of the covering array** (which is the flat, k=2,
hand-rolled special case): flat t-way → deep k-path over the *recursive*
grammar, with *automatic* witness-finding. Same `(input, expected)` output, same
portable artifact — only the driver changes. Portable because it is
grammar-derived, not parser-derived. **This is the tier where proptest's
symex/SMT backend is the right tool** (unlike per-impl fuzzing, which isn't).

### Tier 2 — covering array (LANDED)

Constrained pairwise (t=2) coverage within each grammar interaction group,
invalid cells excluded. Deterministic, minimal, explainable; provable t-way
completeness over modeled axes. The certification *floor* + regression smoke
test. See `conformance/coverage.nim`, `groups.nim`.

### Tier 3 — random `sampleN` (seeded)

The same by-construction generators (`gen.nim`) sampled at scale with a pinned
master seed → arbitrarily large `(input, expected)` stream, portable by value or
by seed. **Statistical** breadth beyond the covering array's structure and
beyond k-path's depth bound. Probabilistic, never proof.

### Tier 4 — fuzz / symex on a specific parser

Point coverage-guided fuzzing or symbolic execution at *one parser's code* to
find crashes and **over-acceptances** (inputs it wrongly accepts — the negative
unknown-unknowns no constructive method reaches). Inherently **per-impl**: it
finds *nkdl's* bugs, so it is NOT the portable corpus. Its shrunk counterexamples
get **pinned** into the corpus as new fixtures — it *feeds* the artifact.

## Why no single tier is "complete"

- A grammar is enumerable → positive structured coverage is achievable (Tier 2)
  and deepenable (Tier 1, to depth k).
- The **complement** of a CFG is not a nice enumerable structure → the negative
  side can be complete only over *modeled* violation classes; unknown-unknown
  over-acceptances need Tier 4 (run the parser).
- The input space is infinite → only Tier 0 closes the `∀` gap, and only
  relative to the *formal* spec, whose faithfulness the corpus validates.

The strongest practical story is the **whole stack**, with one spec-faithful
model feeding all tiers.

## Relationship to what's built

`conformance/` realizes Tier 2 (covering arrays, 11 groups, cross-certified
against kdl-rs) + the by-construction generators that power Tier 3 (`emit_random`).
`model.nim` is the hand-rolled stand-in for what Tier 0's Lean formal spec would
make rigorous. **Tier 0 is STARTED** — `proofs/lean/` has four axiom-clean
verified fragments (values + recursion); the remaining grammar-combination +
Unicode/dedent is research-grade but the skeleton is proven. Tier 1 (z3/k-path)
remains a research track. Negative corpus (the must-reject floor) is the Tier-2
analogue on the complement side; its systematic upgrade (grammar-aware mutation)
and Tier-4 feeding are tracked separately.
