# RFC: Lean-batch cursor (Phase 4, corrected)

**Status**: Active. Phase 4 north star. **Supersedes**
`docs/rfc-pda-substrate.md`. Also retires the intermediate
fused-lex-cursor proposal (considered and rejected — see "Why not
fusion" below).

**Predecessor**: `docs/rfc-three-categories-architecture.md` (Phase 3)
for the public-API surface and Cat 1/2/3 model — both unchanged, and
the Phase-3 lex→cursor→events substrate is the base we keep and tune.

## TL;DR

Phase 4 built a per-T PDA macro to kill the eager lex pass. It failed
its perf predictions (39.6μs vs 12.34μs Cat 2) and cost the cursor's
single-source grammar, event narrow-waist, and precise diagnostics. We
then considered a *fused-lex cursor* (lazy tokenization, event protocol
retained). A spike read 11.97μs — but a cost decomposition proved that
number was an artifact of shape-specialized scanning, and that fusion is
the **wrong lever**: it recovers the least and costs the most
cleanliness.

The decomposition showed the real opportunity is **batch-trimmable** and
needs no architectural change: revert to the clean Phase-3 cursor and
make the existing batch lexer leaner (payloads → spans, skip interning
in decode mode). This recovers ~2× what fusion would, while keeping the
cleanest of all the substrate options.

## The decomposition (decisive evidence)

`lex()` measured in isolation: 35.4μs on services-100, 22.2μs on
realistic-config (~36% of full parse). Decomposed by component, with
each allocation replayed from the real token spans
(`benchmarks/spike_lexdecomp.nim`):

**services-100 (full lex 35.4μs):**

| Component | μs | % | Recoverable by |
|---|---|---|---|
| Byte scanning (residual) | 16.4 | 46% | **nothing — unavoidable** |
| Interning (400 barewords) | 7.7 | 22% | batch trim (no-intern decode mode) |
| Number-text payloads | 3.6 | 10% | batch trim (payload → span) |
| seq[Token] materialization | 5.8 | 16% | **streaming only** |
| String payloads | 1.9 | 5% | batch trim (payload → span) |

- **Batch-trimmable: 13.2μs (37%)** — keeps the eager-batch lexer.
- **Streaming-only: 5.8μs (16%)** — the *only* thing a fused iterator buys.

realistic-config is the same shape: 56% scan, 34% batch-trimmable, 11%
streaming-only.

### Two facts that reframe everything

1. **Byte scanning is the largest component (46–56%) and is unavoidable
   in every model** — batch, streaming, or PDA. The general lexer scan
   does full KDL v2 classification per byte: Unicode whitespace/newline
   tables, comment nesting, esclines, slashdash, number-vs-ident
   disambiguation, UTF-8 decode, SWAR ident scan. ~16μs on services-100.

2. **The 11.97μs fused spike cheated on exactly this.** Its tokenizer was
   shape-specialized — it did hand-spike-style scanning (~5μs), not
   general classification (~16μs). A *general* fused-lex cursor would
   carry the same ~16μs floor. The spike was structurally optimistic in
   the same way the PDA spike was (12.34 → 39.6). There is no cheap path
   to 12μs on general grammar; that number was specialized-scan fiction.

## Why not fusion

A fused-lex cursor (own a `Lexer`, pull one token at a time, no
`seq[Token]`, events carry spans inline) recovers only the **16%**
streaming-only slice — and pays for it in cleanliness, measured against
the Phase-3 batch cursor we'd otherwise keep:

- **Lexer: pure batch transform → stateful resumable iterator.**
  Exposed `pos`/`wsPending`/interner-threading state, lifecycle-managed
  by the cursor. The class of stateful-iterator bugs (double-advance,
  off-by-one) appears where there were none.
- **Events: uniform 24-byte index structs → heterogeneous, heap-bearing.**
  Escaped/multiline strings aren't source substrings, so string-valued
  events must carry an owned `string` (or point into a scratch buffer
  with a copy-before-next lifetime hazard). The "16-byte event"
  elegance is gone.
- **Lookahead: `tokens[i+1]` → manual pushback ring** holding
  owned-payload tokens with hand-managed lifetimes.
- **Test fidelity splits:** production runs the streaming drain; the
  lexer suite tests the eager drain; closing the gap needs a permanent
  "both drains agree" invariant.
- **Error resync:** index math over an array → driving the lexer forward
  in pull mode while keeping the lookahead ring consistent.

Spending all of that to recover 16% — when a no-architecture-change
batch trim recovers 37% — is a bad trade. Fusion is rejected.

## The design: revert to Phase-3 cursor, lean the batch lexer

Keep everything clean about Phase 3 — pure batch `lex()`, immutable
`TokenStream`, cursor as a pure walk, `tokens[i+1]` lookahead,
inspectable intermediate, uniform events. Change only what the
decomposition flagged as wasted allocation:

1. **Payloads → spans.** `tkString` / `tkNumber` carry `(lo, hi)` into
   source instead of an owned payload string. Numbers are never parsed
   at lex time anyway (the consumer parses), so number-text allocation
   is pure waste — delete it. Strings allocate **only when they actually
   contain escapes** (no-escape single-line strings — the common case —
   become a span, zero-alloc). The `TokenStream` keeps its side tables
   *only* for the escaped-string minority.
2. **Skip interning in decode mode.** Add a lex mode (`intern = false`)
   that emits `tkIdent` with just the span. Cat 2 typed decode reads
   bareword bytes via span + `bytesEqLit` and never needs a handle. Cat
   3 DOM keeps interning iff it stores interned node names (verify;
   it may also move to spans).

Both changes are local to the lexer's emit path and a payload-resolution
helper on `TokenStream`. No consumer-protocol change. No new state. The
cursor and both consumers (DOM, typed decode) are the Phase-3 code,
re-pointed at span-based payload resolution.

**Projected lean-batch lex: ~22μs services / ~15μs realistic** (from
35 / 22), all of it inside the clean batch architecture.

### Optional follow-on (not required): fast-ASCII scan path

The ~16μs general-scan floor is the same in every model, but it is
itself partly improvable *within the batch lexer* — a fast-ASCII path
that classifies the common byte range before falling to the Unicode
tables could trim part of it. This is a separate, later optimization
with no architectural cost; out of scope for the core plan but noted as
the next perf lever if we want it.

## Honest perf ceiling

The ~16μs general-scan floor means general typed decode realistically
lands ~25–30μs (lean lex + fold), not 12μs. That still:

- beats knus (~48μs) by ~1.5–2×,
- beats the shipped PDA (39.6μs),
- and is the **cleanest** of every option considered.

"Absolute best on perf" for general grammar was never actually
available — it required specializing the scanner per shape, which is
what made both the hand-spike (5.92μs) and the fused spike (11.97μs)
look fast. Lean-batch captures essentially all of the *clean* upside.

| Option | Cat 2 typed decode | Cleanliness |
|---|---|---|
| Phase-3 eager cursor | ~50μs | cleanest |
| **Lean-batch cursor (this RFC)** | **~25–30μs** | **cleanest (Phase-3 + leaner payloads)** |
| Fused-lex cursor (rejected) | ~25–30μs | stateful iterator, heterogeneous events |
| PDA (reverted) | 39.6μs | worst (dup grammar, lost spans, 1.1k-LOC macro) |

Note lean-batch and fused-lex land in the same perf band — because both
are gated by the same scan floor — but lean-batch gets there with zero
architectural cost. That equivalence is the whole argument.

## Implementation plan

| Step | Scope | Gate |
|---|---|---|
| 0 | ✅ **DONE.** Revert the PDA; archived to `archive/phase4-pda`. Surfaced + fixed the `formatFloat` round-trip bug (see Phase 0 finding). | Full Phase-3 suite green (338/338 + property baseline). ✅ |
| 1 | ✅ **DONE (cleanliness, perf flat).** Number payloads → spans: removed `NumberPayload` type + `numberPayloads` side-table + the `negative` field; `tkNumber` carries `numBase` inline; `numlit` decoders are pure `openArray[char]` views (`numberText`). | Conformance + decode + property suites green ✅. **But `lex()` perf flat within noise** — the decomp's `comp_numpay` proxy over-counted (char-by-char vs the lexer's bulk slice). Kept as a cleanliness/SSOT win, not a perf win. |
| — | **Corrected perf model.** The decomp's *allocating* proxies (`comp_numpay`, `comp_strpay`) over-counted (synthetic `newStringOfCap`+per-char vs real bulk `source[a..<b]`). The measurable batch-trim prize is **interning (22% / 7.7μs)** — real hash-table work, not an over-counted alloc. So Step 3 is reprioritized ahead of Step 2. | — |
| 2 | **DEFERRED** (string payloads → spans). Same alloc shape as Step 1 → expected flat perf; primarily cleanliness. Revisit after Step 3 proves the perf model on intern. | — |
| 3 | ✅ **DONE — and it disproved the perf thesis (also flat).** Removed lex-time interning **entirely** (not a flag): dropped the `interner` param from `lex()`, the `tkIdent.ident` handle field, the dead `isReservedBareword(interner,handle)` overload, and `parse()`'s redundant double-intern. Big cleanliness win — the lexer no longer depends on `Interner` at all. | All green (default 582 + property baseline) ✅. **But `lex()` only dropped ~1–2μs (37.8→36.7 services, 25.8→23.6 realistic), within the ~3μs cross-run variance** — not the decomp's predicted 7.7μs. The "faithful" `comp_intern` over-predicted too (isolated cold-cache vs in-context with repetitive barewords). |
| — | **⛔ Lean-batch PERF thesis DISPROVEN by real measurement.** Both batch-trim components (numbers, interning) gave flat lex() perf when actually removed. Root causes: (a) decomp components measured in isolation over-predict in-context marginal cost; (b) cross-run variance (~3μs) swamps the ~1–2μs real effects; (c) **lex is only ~35% of decode/parse** — the bulk is the consumer fold/build, which lean-batch never touched; (d) the one genuinely large component is the **~16μs general-scan floor (46–56%)**, which is not batch-trimmable. Steps 1+3 stand as **cleanliness/SSOT wins**, not perf wins. |
| 2 | **DROPPED.** Same alloc shape as Step 1 → would also be flat. Not worth the churn for zero measurable perf; the cleanliness gain (string payload→span) is marginal and adds escape-handling complexity. Justified deferral → drop. |
| 4 | **Bench gate** (if perf still pursued). Only meaningful target left is the scan floor (fast-ASCII path) or the consumer fold — NOT lex batch-trim. | — |
| 5 | **Cleanup.** Remove throwaway `spike_*` benches; dead `var interner` in test helpers; stale `typed_parser` comments. | `nimble test` clean. |

**Verdict:** the lean-batch arc delivered real **cleanliness** (Phase 0's float-bug fix; Step 1's number-payload removal; Step 3's full interner-from-lexer removal) and confirmed the Phase-3 substrate is **already near its perf floor** for the lex stage. Per-component lex trimming is not the lever. If perf is still wanted, the only real targets are the general-scan floor or the consumer fold/build — a different investigation.

## What the bench must prove

Each of steps 1–3 should show its predicted slice disappear from a
re-run of `benchmarks/spike_lexdecomp.nim`: number-text (~10%),
string-payload (~5%), interning (~22%). If the measured drop is much
smaller than the decomposition predicted, the synthetic component
overstated the cost — investigate before claiming the win. (Same
discipline that the PDA spike's 12.34→39.6 gap, and the fused spike's
specialized-scan artifact, both violated.)

## Risk register

| Risk | Mitigation |
|---|---|
| Span-based string payloads break escape/multiline round-trip | The resolution helper returns the *decoded* string for escaped tokens (still stored); only no-escape strings switch to spans. Preserve byte-exact suite is the gate. |
| Cat 3 DOM needs interned node names | Step 3 decides this explicitly per measurement — keep interning for DOM if it pays; only decode mode skips it. |
| Decomposition over/under-counts (synthetic vs real interleaved allocs) | Steps re-run the decomp after each change; the gate is the *measured* drop, not the projection. |
| "We burned a multi-sprint PDA build for nothing" | Not nothing: conformance corpus, the four proptest-found parity fixtures, and the lex-cost decomposition all carry forward. The PDA is deleted; its test corpus and bug fixes are not. |

## Phase 0 finding (resolved): float emit was not round-trip-safe

Reverting to Phase-3 and running the opt-in property baseline surfaced a
real, pre-existing bug the always-on tests were structurally blind to:
`numlit.formatFloat` emitted via Nim's legacy `$float` (`c_sprintf`,
16 significant digits). ~45% of full-mantissa doubles need 17 digits and
silently re-parsed to a **neighbouring** double — an encode→decode
identity (P7) violation. Invisible to conformance/example tests (short
decimals: 0% failure) and to the PDA's differential (`cursor == pda`
both consumed the same lossy bytes and agreed). Only a round-trip
property over machine-generated doubles exposed it.

Fixed by calling `std/formatfloat.addFloatRoundtrip` directly — the
stdlib Schubfach shortest-correctly-rounded formatter — **not** the
global `-d:nimPreviewFloatRoundtrip` flag. The direct call is the
correct choice: a global define only fixes nkdl's own builds, leaving a
library *consumer* who compiles without it with lossy float emit. The
direct call makes round-trip safety a property of the code, not the
build. Bonus: Schubfach is ~6.3× faster than the legacy formatter on the
encode path. Guarded by an always-on regression test
(`test_roundtrip.nim`: pinned counterexample + full-mantissa sweep).

**Spec obligation** (for the v1.5 spec extraction + any non-Nim impl):
float values MUST be emitted as the shortest decimal string that
round-trips to the exact IEEE-754 double, retaining a `.0` or exponent
so the value re-lexes as a float, not an int.

## What carries forward from the PDA work

- The four parity bugs the proptest differential found (int64.low
  negate, float strtod-rounding, quoted-enum value match, variant
  kdlArg discriminator) — re-pin as regression tests on the cursor path.
- `tests/test_pda_conformance.nim` corpus assertions → retarget at
  `parse()` (the `grammar.referenceInterpret` oracle is
  substrate-independent).
- The decomposition method itself: any future perf claim on this
  substrate gets decomposed before it gets built.

## Resume-here pointer

Spike evidence (throwaway, delete at Step 5):
- `benchmarks/spike_lexcost.nim` — lex-pass isolation (36% of parse).
- `benchmarks/spike_lexdecomp.nim` — the component decomposition.
- `benchmarks/spike_fusedlex.nim` — the 11.97μs fused spike (kept as the
  cautionary specialized-scan artifact).

**Next concrete action**: Step 0 — revert the PDA, get the Phase-3 suite
green, then Step 1 (number payloads → spans).
