# Substrate perf investigation log

**Status**: Closed record. This is the single source of truth for every
substrate-level performance lever we have pulled, what it cost, and why.
Read it before opening another optimization round so you do not re-walk a
dead end.

It consolidates and replaces two earlier RFCs — `rfc-pda-substrate.md`
(the failed approach) and `rfc-lean-batch-cursor.md` (the successful one,
whose first-draft conclusion was *wrong* because it trusted wall-clock;
see §4). Both are recoverable in git history; their durable content is
captured here. The architecture itself is documented in
`rfc-three-categories-architecture.md` (still canonical — unchanged).

The one-line lesson, if you read nothing else: **on WSL2 the only honest
gate for a sub-10% substrate change is callgrind instruction count, not
wall-clock.** Wall-clock noise (±13%) made the winning approach look like
a failure and nearly got it abandoned.

---

## 1. The question

The Phase-3 substrate (lex → cursor → events → consumers) is clean and
delivers everything we care about: 338/338 conformance, `embed[T]`
compile-time decode, the P1–P12 property catalog, #11 closed by
construction, a 3–3.5× memory advantage over the Rust parsers. Its one
soft spot was headline typed decode: `decode[seq[Service]]` ran ~50 µs
against knus's ~48 µs — 1.05× slower. Profiling pinned the cost on the
**eager lex pass**: ~32 µs of every typed-decode call went to building a
full `TokenStream` (unescaped strings, parsed numbers, interned names)
before the typed consumer saw its first event.

The investigation asked: can we cut that without losing the architecture's
wins? Three approaches were tried. Two were rejected; the third worked.

---

## 2. Approach A — PDA substrate (Phase 4). BUILT, then REVERTED.

**Idea.** Replace lex→cursor→events with a per-`T` compile-time
push-down automaton: a single byte-level state machine with the consumer's
handlers fused in at macro time, eliminating the lex pass entirely. Spike
data was seductive:

| Approach | µs / decode-services-100 |
|---|---|
| Phase-3 cursor decode | 50.0 |
| knus `parse::<Vec<Service>>` | 47.7 |
| Hand-written PDA (fixture-specialized) | **5.92** |
| Macro-generated PDA (general, spiked) | **12.34** |

**What we did.** Built it end-to-end — Sprints 1–5: 338/338 conformance,
`embed[T]` at compile time, the full property catalog, slashdash + error
recovery, `parse()`/`parseAll()` rewired. It *worked*, functionally.

**Why it was reverted.** The bench gate failed, and the cleanliness cost
was worse than predicted:

- **Perf prediction collapsed.** The general macro-PDA measured **39.6 µs**
  Cat 2 (vs the 12.34 µs spike) and Cat 3 realistic **regressed to
  68.7 µs**. The spike had omitted the per-node capture-replay `PropSpan`
  tax that a *general* (non-shape-specialized) automaton must pay. Same
  failure mode the spike numbers always have — see §5.
- **Duplicated the node grammar.** `pda_build` (DOM) and `pda_decode`
  (typed) each re-expressed the node-structure rules. The cursor had had
  exactly one.
- **Lost the event narrow-waist.** Cat 1/2/3 no longer met at a single
  typed event boundary.
- **Regressed diagnostics.** 52 sites collapsed to `pointSpan(0)` — the
  precise spans the cursor carried were gone.
- **Grew LOC.** 2443 added vs 1756 deleted.

**Root cause (the important part).** The cursor's cost was the eager
full-document `TokenStream` *materialization* (~32 of 38 µs of the lex
pass) — **not** the cursor/event abstraction. The PDA removed the
abstraction along with the materialization. Overreach: it paid for the
materialization win by demolishing the part that was already good.

**Disposition.** Reverted. Recoverable on branch `archive/phase4-pda`.
What carried forward: the 338-fixture conformance corpus, four
proptest-found parity fixtures (see §6), and the lex-cost decomposition
method (§5).

---

## 3. Approach B — Fused-lex cursor. CONSIDERED, REJECTED (never built).

**Idea.** Keep the event protocol but make the lexer lazy: the cursor owns
a `Lexer`, pulls one token at a time, no `seq[Token]`, events carry spans
inline. This kills the materialization (the real cost from §2) without
killing the abstraction.

**Why it looked good, and why that was fiction.** A spike read **11.97 µs**
(`spike_fusedlex.nim`). But a lex-cost decomposition (`spike_lexdecomp.nim`)
proved that number was a *shape-specialized-scan artifact*. Decomposing the
35.4 µs lex pass on services-100:

| Component | µs | % | Recoverable by |
|---|---|---|---|
| Byte scanning (residual) | 16.4 | 46% | **nothing — unavoidable in every model** |
| Interning (400 barewords) | 7.7 | 22% | batch trim (no-intern decode mode) |
| Number-text payloads | 3.6 | 10% | batch trim (payload → span) |
| `seq[Token]` materialization | 5.8 | 16% | **streaming only** |
| String payloads | 1.9 | 5% | batch trim (payload → span) |

Two facts reframed the whole investigation:

1. **Byte scanning (46–56%) is the largest component and is unavoidable in
   every model** — batch, streaming, or PDA. General KDL v2 classification
   per byte (Unicode whitespace/newline tables, comment nesting, esclines,
   slashdash, number-vs-ident disambiguation, UTF-8 decode, SWAR ident
   scan) is ~16 µs and no substrate shape removes it.
2. **The 11.97 µs fused spike cheated on exactly this** — its tokenizer was
   shape-specialized (~5 µs hand-scan), not general (~16 µs). A *general*
   fused-lex cursor carries the same ~16 µs floor. Same structural
   optimism as the PDA spike (12.34 → 39.6).

**Why rejected.** Fusion recovers only the **16%** streaming-only slice —
and pays heavily in cleanliness, measured against the Phase-3 batch cursor
we'd otherwise keep:

- Lexer: pure batch transform → **stateful resumable iterator** (exposed
  `pos`/`wsPending`/interner state; a whole class of double-advance /
  off-by-one bugs where there were none).
- Events: uniform 24-byte index structs → **heterogeneous, heap-bearing**
  (escaped/multiline strings aren't source substrings, so string events
  must own a `string` or point into a copy-before-next scratch buffer).
- Lookahead: `tokens[i+1]` → **manual pushback ring** of owned-payload
  tokens with hand-managed lifetimes.
- Test fidelity splits (production drains streaming; the lexer suite drains
  eager — needs a permanent "both agree" invariant).
- Error resync: array index math → driving the lexer forward in pull mode
  while keeping the ring consistent.

Spending all that to recover 16%, when a no-architecture-change batch trim
(§4) recovers far more, is a bad trade.

---

## 4. Approach C — Lean-batch. THE WINNER (−27.9% instructions).

**Idea.** Revert to the clean Phase-3 cursor and trim only the *wasted
allocation* the decomposition flagged — keeping the eager-batch lexer, the
immutable `TokenStream`, the pure-walk cursor, `tokens[i+1]` lookahead, and
uniform events. No consumer-protocol change, no new state.

### 4a. The methodology twist (read this before trusting any perf result here)

Lean-batch was first measured with **wall-clock** and looked **flat** —
each batch-trim step dropped lex() by ~1–2 µs, inside the ~3 µs cross-run
variance. The first-draft conclusion (in the old `rfc-lean-batch-cursor.md`)
was literally "**lean-batch perf thesis DISPROVEN**; the substrate is
already at its perf floor; per-component trimming is not the lever," and
the strings→span step was marked **DROPPED**.

**That conclusion was wrong — an artifact of the measurement tool.** WSL2
exposes no hardware PMU (`perf stat` instructions = "not supported"), and
wall-clock carries ±13% noise even over 120k iterations. Both are useless
for gating a sub-10% change.

Switching to **callgrind** (a CPU *simulator* — instruction count is exact
and frequency-independent) inverted the verdict. Every lean-batch step was
a real, measurable win that wall-clock simply could not see:

| Commit | Change | callgrind I refs (N=800) | Δ |
|---|---|---|---|
| — | clean Phase-3 baseline | 1,462,759,900 | — |
| `f76bffc` | remove lex-time interning entirely | 1,246,623,087 | **−14.8%** |
| `51a3d5a` | no-escape single-line strings → span | 1,147,816,843 | **−7.9%** |
| `9d6b4ba` | unified token-content vocabulary | 1,054,947,168 | **−8.1%** |
| | **cumulative** | | **−27.9%** |

All behavior-preserving (583 unit + 338/338 conformance + 243 byte-exact
preserve + property baseline green throughout). Public API unchanged.

### 4b. What actually shipped

- **Remove lex-time interning entirely** (not behind a flag): dropped the
  `interner` param from `lex()`, the `tkIdent.ident` handle, the dead
  `isReservedBareword(interner, handle)` overload, and `parse()`'s
  redundant double-intern. The lexer no longer depends on `Interner` at
  all. This was the single biggest lever (−14.8%).
- **Payloads → spans.** Numbers carry `numBase` inline and resolve text
  as `source[span]` (no `NumberPayload` table); no-escape single-line
  strings and idents are zero-alloc spans. Only the escaped-string
  minority still allocates a payload.
- **Unified token-content vocabulary** (the elegant endpoint). Every text
  token — ident / string / number — resolves content through one set:
  `contentSpan(tok)` / `hasPayload(tok)` / `tokenText(stream, tok)` (the
  SSOT) / `internToken(interner, stream, tok)` (zero-copy). No consumer
  touches payload tables or span arithmetic. One shared
  `classifyStringByte` classifier feeds both the lexer fast-scan and
  `decodeRegularString`, killing a duplication. The −8.1% came mostly from
  `internToken` interning node names / prop keys *zero-copy* from source
  rather than alloc-then-intern. The refactor that was done for
  *cleanliness* paid for itself in *perf* too.

### 4c. Honest perf ceiling

The ~16 µs general-scan floor (§3) is real and unavoidable, so general
typed decode lands in the ~25–30 µs band, not 12 µs. "Absolute best on
perf" for general grammar was never actually on the table — it required
specializing the scanner per shape, which is precisely what made the
hand-spike (5.92 µs) and the fused spike (11.97 µs) look fast. Lean-batch
captures essentially all of the *clean* upside, and still beats knus
~1.5–2× and the reverted PDA (39.6 µs).

---

## 5. The discipline this investigation bought

**Decompose any perf claim before building it.** Both rejected approaches
died of the same disease: a spike specialized its scanner to one input
shape, posted a number that omitted the general-case tax, and that number
drove a design. The PDA spike's 12.34 → 39.6 µs and the fused spike's
11.97 µs (vs ~16 µs general floor) are the same bug. Before committing to
a substrate change, decompose where the cost actually is and confirm the
predicted slice is general, not shape-specialized.

**Gate sub-10% changes on callgrind, never wall-clock — at least on this
machine.** The gate is `benchmarks/perf_gate.nim` (run under
`localhost/nim-perf-vg:2.2.0` = `nim-perf:2.2.0` + valgrind; the file
header documents the exact invocation and the reference baseline). Lean-
batch is the proof: wall-clock called a −27.9% win "flat."

---

## 6. Side finding (resolved): float emit was not round-trip-safe

Reverting to Phase-3 and running the opt-in property baseline surfaced a
real, pre-existing bug the always-on tests were structurally blind to:
`numlit.formatFloat` emitted via Nim's legacy `$float` (`c_sprintf`, 16
significant digits). ~45% of full-mantissa doubles need 17 digits and
silently re-parsed to a **neighbouring** double — an encode→decode identity
(P7) violation. Invisible to conformance/example tests (short decimals: 0%
failure) and even to the PDA's differential (`cursor == pda` both consumed
the same lossy bytes and agreed — see [[testing_differential_blind_spot]]).
Only a round-trip property over machine-generated doubles exposed it.

Fixed by calling `std/formatfloat.addFloatRoundtrip` directly — the stdlib
Schubfach shortest-correctly-rounded formatter — **not** the global
`-d:nimPreviewFloatRoundtrip` flag (a global define only fixes nkdl's own
builds, leaving a library *consumer* compiling without it with lossy float
emit; the direct call makes round-trip safety a property of the code, not
the build). Bonus: Schubfach is ~6.3× faster on the encode path. Guarded
by an always-on regression test (`test_roundtrip.nim`: pinned counter-
example + full-mantissa sweep).

**Spec obligation** (for the v1.5 spec extraction + any non-Nim impl):
float values MUST be emitted as the shortest decimal string that round-
trips to the exact IEEE-754 double, retaining a `.0` or exponent so the
value re-lexes as a float, not an int.

---

## 7. If you open another round: the map

**Do NOT revisit (settled, recoverable in git if you must look):**

- **PDA substrate** — built, reverted; removes the abstraction to chase a
  materialization win that batch-trim got cleanly. `archive/phase4-pda`.
- **Fused-lex cursor** — recovers only 16% (the materialization slice) for
  a large cleanliness cost; the rest of its apparent win was specialized-
  scan fiction.
- **Per-component wall-clock measurement** of lex trims — it cannot see
  sub-10% effects on this machine. Use callgrind.
- **The "~12 µs general typed decode" target** — specialized-scan fiction;
  the real floor is ~16 µs of unavoidable byte classification.

**Declined, with reason (cheap but not worth it):**

- **`isWellFormedUtf8` fusion (~2%).** The pre-pass at `lexer.nim` is a
  *security boundary*, not a redundant scan: it rejects over-long UTF-8 so
  the `containsBidiControl` denylist is sound (an attacker encoding U+202E
  as the over-long `F0 82 80 AE` would otherwise bypass a denylist that
  only checks the canonical 3-byte form). Fusing it into the span-based lex
  fast paths trades a clean normalization gate for 2%. Declined.

**Genuinely open (untried — where the real cost now lives):**

- **The consumer fold/build, not lex.** Post-lean-batch, `perf record` on
  a decode+parse workload shows **allocation ~22% is the #1 cost** (string
  payloads, DOM `KdlNode`/`KdlValue`, doc interning), lex-scan ~27%, and
  fold/build ~12%. Lex is only ~35% of decode/parse; the bulk the perf
  pass never touched is downstream. An allocation-focused pass on the
  consumer (arena/sink semantics for the DOM, fewer transient strings) is
  the most promising untried lever. See [[nkdl_perf_profile]].
- **The ~16 µs general-scan floor** — a fast-ASCII classification path that
  handles the common byte range before falling to the Unicode tables could
  trim *part* of the floor, within the batch lexer, at no architectural
  cost. Bounded upside; unmeasured.
- **Cat 3 `mutState` ref overhead** in `KdlNode` copy/move (the Cat 3 hot
  path), noted as a follow-on in the rebuild plan.

**What carries forward regardless:** the conformance corpus, the four
proptest parity fixtures (int64.low negate, float strtod-rounding,
quoted-enum value match, variant kdlArg discriminator), the decomposition
discipline (§5), and the callgrind gate (`benchmarks/perf_gate.nim`).
