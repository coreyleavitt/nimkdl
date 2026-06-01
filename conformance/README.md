# conformance/ — clean-room KDL 2.0 conformance corpus

An **implementation-independent** conformance corpus for KDL v2, generated from
the spec. It is *not* part of nkdl's test suite — it's a standalone tool whose
output is a shareable artifact that any KDL implementation can run (the
intended drop-in superset of the kdl-org corpus; see GH #27). Extractable to
its own repo later.

## The one hard rule

**The generator imports nothing from `../src`.** A corpus you test nkdl against
must contain zero nkdl code, or "nkdl passes" is circular. This is enforced —
the only file allowed to import nkdl is `adapters/nkdl.nim` (the system under
test, not part of producing the corpus). Check with:

```
grep -rn 'import .*\.\./\.\./src\|import .*\.\./src' conformance/   # must be empty except adapters/
```

## Why a generator, not a parser oracle

`generation < parsing` — a paired generator builds a document *and* renders it,
so each `(input_text, expected_value)` pair is an oracle **by construction**: no
parser, no reference interpreter, no shared lexer, nothing to audit. That is
why it stays independent and simple. (Even nkdl's `referenceInterpret` is the
wrong oracle here: it shares `lexer.nim` + `numlit.nim` with the parser, so
it's independent only at the *structural* level, not the lexical one.)

The corpus's *correctness* rests on the spec transcription being faithful; the
thing that **certifies** it is agreement across multiple independent
implementations (nkdl + kdl-rs + …), not any single parser.

## Layout

| File | Role | nkdl? |
|---|---|---|
| `model.nim` | neutral KDL data model + JSON `expected` (floats = shortest round-trip decimal STRING) | no |
| `render.nim` | clean-room surface renderers (value → text, explicit style) | no |
| `gen.nim` | proptest paired generators: values + identifiers + `docSurface` (whole docs); `sampleN` for standalone generation | no |
| `adapters/nkdl.nim` | parse with nkdl → map `KdlDoc` to neutral model → assert == expected | **YES (only here)** |
| `corpus/` | emitted artifact: `input/*.kdl` + `expected/*.json` + `SEED` | — (not built yet) |

## Status (2026-05-31)

Proven end-to-end: the generator emits `(input, expected)` clean-room, and
`adapters/nkdl.nim` runs the corpus against nkdl — **500 examples GREEN**. The
value layer (int all bases/signs/underscores, float, keyword, escaped string)
and the structural layer (nodes / args / distinct props / multi-node docs) are
done. Completeness target = **grammar-production coverage** of the generator
(NOT gcov-on-nkdl — that measures our branches, meaningless for a spec corpus).

## How to run

```
# generate a few samples (standalone, no nkdl):
nim c -r conformance/gen.nim
# run the corpus against nkdl:
NKDL_PROPTEST=1 nim c -r -d:nimCallDepthLimit=20000 conformance/adapters/nkdl.nim
```
(In the nim container, per the repo convention.)

## NEXT STEP — emit.nim

Turn the proven generator into the on-disk artifact:
1. Drive `docSurface()` with `sampleN` over a large pool.
2. **Set-cover minimize** to a production-complete *minimal* corpus (track which
   grammar productions each input exercises; greedy-select the smallest covering
   set).
3. Write `corpus/input/NNN.kdl` + `corpus/expected/NNN.json` + a pinned `SEED`
   for byte-stable regeneration.

## Then — surface refinements + cross-impl

- Generator widenings (adapter unchanged): raw/multiline string styles,
  children, type annotations, slashdash + duplicate-prop noise (last-wins).
- Grammar-production coverage instrumentation + assert 100%.
- Other-impl adapters (kdl-rs, …) — the real certification.
- Negative corpus: grammar-breaking mutations → must-reject fixtures.

The earlier `tests/kdlgen.nim` + `tests/test_spec_coverage.nim` (which import
`src/`) are nkdl-testing-nkdl — legitimate internal PBT, superseded by this
corpus + adapter once it's complete.
