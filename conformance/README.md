# conformance/ — clean-room KDL 2.0 conformance corpus

An **implementation-independent** conformance corpus for KDL v2, generated from
the spec. It is *not* part of nkdl's parser — it's a standalone tool whose
output (`corpus/`) is a shareable artifact any KDL implementation can run, the
intended drop-in superset of the kdl-org corpus (GH #27). Extractable to its
own repo later.

## The one hard rule

**The generator imports nothing from `../src`.** A corpus you test nkdl against
must contain zero nkdl code, or "nkdl passes" is circular. Enforced — the only
file allowed to import nkdl is `adapters/nkdl.nim` (the system under test, not
part of producing the corpus). Check:

```
grep -rn 'import .*\.\./\.\./src\|import .*\.\./src' conformance/   # only adapters/
```

## Architecture (single model → projections; two coverage axes)

One principle: **a single spec-derived semantic model is the source of truth;
everything else is a projection of it or a check against it.**

```
        spec Data Model + Grammar  (docs/kdl-2.0-spec.md, transcribed)
                          │
                    model.nim ── neutral semantic model. NUMBERS ARE EXACT
                          │        DECIMAL (sign + digit-strings + signed exp),
                          │        never int64/float — the spec draws no
                          │        int/float distinction and `1.23E+1000`
                          │        exceeds double range yet is kept verbatim.
        ┌─────────────────┼──────────────────┐
   canonicalKdl*       toJson*          covering array (surface axis)
   (kdl-org canonical) (precise JSON)   coverage.nim + groups.nim
        │                 │                   │
        └──────── emit.nim → corpus/ ─────────┘
          input/NNN.kdl  expected/NNN.json  expected_kdl/NNN.kdl
          coverage-certificate.json   (+ SEED when free choices appear)
                          │
        ┌─────────────────┴───────────────────┐
   adapters/nkdl.nim                    gen.nim (random fuzz tier)
   parse corpus → map → assert == expected   proptest generators behind the
   cross-impl agreement = the real cert       adapter property (500 examples)
```

Two **orthogonal coverage axes** (don't conflate):

- **Semantic axis** — which data-model shapes (value kinds, annotations, args/
  props, nesting). Enumerated for model coverage.
- **Surface axis** — which textual renderings of one shape (number base, sign,
  underscores, string style, trivia, slashdash). Covered by a **constrained
  covering array**: pairwise (t=2) *within* each grammar interaction group,
  invalid cells excluded (NIST interaction rule, scoped to where the grammar
  actually couples factors). Same shape via different surfaces → equal model is
  the **metamorphic** invariant.

Why a generator, not a parser oracle: `generation < parsing`. A paired
generator builds a value *and* renders it, so each `(input, expected)` is an
oracle **by construction** — no parser, no reference interpreter, no shared
lexer to audit. (Even nkdl's `referenceInterpret` shares `lexer.nim`+`numlit.nim`,
so it's independent only structurally, not lexically — wrong oracle here.)

## Files

| File | Role | nkdl? |
|---|---|---|
| `model.nim` | neutral model + exact-decimal numbers + `toJson` / `canonicalKdl(Node/Doc)` projections | no |
| `render.nim` | clean-room surface renderers (value → text, explicit style) + `ValueSurface` | no |
| `coverage.nim` | constrained covering-array engine: `InteractionGroup` → `coverTargets` → `coveringArray` | no |
| `groups.nim` | spec-transcribed interaction groups **with** their instantiators (row → witness) | no |
| `gen.nim` | proptest random generators (the fuzz tier) + `sampleN` | no |
| `emit.nim` | drive covering arrays → `corpus/` (3 projections + certificate); deterministic | no |
| `adapters/nkdl.nim` | parse with nkdl → map to model → assert == expected | **YES (only here)** |
| `corpus/` | the emitted artifact (checked in; regenerate with `emit.nim`) | — |
| `tests/` | clean-room unit tests (model/coverage/groups/emit) | no |

## Status (2026-05-31)

Pipeline proven **end-to-end for the integer group**. `nimble test` runs the
clean-room suites; `NKDL_PROPTEST=1 nimble test` adds the adapter (500 random
examples + the covering-array corpus, all green).

- **M1/M2** exact-decimal number model (killed the float-as-double oracle bug),
  migrated render/gen/adapter onto it.
- **A1/A2** constrained covering-array engine (greedy, deterministic).
- **A3** row → witness instantiation + metamorphic invariant.
- **A4/E1** nkdl runs the covering-array corpus; `emit.nim` writes `corpus/` —
  the integer group = **15 fixtures covering all 38 pairwise targets,
  `complete: true`** in the certificate.

## How to run

```
# clean-room unit tests (no nkdl, no proptest):
nim c -r conformance/tests/test_model.nim      # (and test_coverage / test_groups / test_emit)
# regenerate the on-disk corpus:
nim c -r conformance/emit.nim                   # writes conformance/corpus/
# run the corpus against nkdl:
NKDL_PROPTEST=1 nim c -r -d:nimCallDepthLimit=20000 conformance/adapters/nkdl.nim
```
(In the nim container, per the repo convention.)

## Next (each a clean slice)

1. **Float group** — constrained CA where the *semantic shape* (fraction-only /
   exponent-only / both) is itself a factor; needs a component-based float
   renderer (no double) so witnesses stay exact.
2. **String group** — quoted / raw / multiline+dedent styles; this lands the
   string canonicalization that `canonicalKdl(string)` currently defers.
3. **Structural group** — args × props × children × multi-node, pairwise. This
   is where the interaction bugs live (slashdash × children-checkpoint); emit
   must instantiate node-shaped (not just value-wrapped) witnesses.
4. **Negative corpus** — production-tagged grammar mutations → must-reject
   fixtures; adapter asserts rejection.
5. **Other-impl adapters** (kdl-rs, …) — the real cross-impl certification.

The earlier `tests/kdlgen.nim` + `tests/test_spec_coverage.nim` (which import
`src/`) are nkdl-testing-nkdl — legitimate internal PBT, superseded by this
corpus + adapter once it's complete.
