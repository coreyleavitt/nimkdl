# RFC: PDA as single substrate (Phase 4)

**Status**: **SUPERSEDED** by `docs/rfc-lean-batch-cursor.md`. The PDA was
built end-to-end (Sprints 1–5, 338/338 conformance, embed[T], property
catalog) but failed its perf predictions (general macro 39.6μs vs
predicted 12.34μs — the spike omitted the per-node capture-replay tax)
and cost the cursor's single-source node grammar, event narrow-waist,
and precise diagnostics. A lex-cost decomposition then showed the eager
lex pass is 46–56% unavoidable byte-scanning, 34–37% batch-trimmable
(payload allocs + interning, removable with no architectural change),
and only ~16% the seq materialization a fused iterator would recover.
Conclusion: revert to the clean Phase-3 cursor and lean the batch lexer
(payloads → spans, no-intern decode mode) — recovers ~2× what fusion
would for none of the cleanliness cost. Goal kept (cut the lex pass),
means corrected (trim wasted allocation, keep the batch abstraction).
Kept below for the historical decision record.

**Original status**: Active. Phase 4 north star. Replaces Phase 3's
three-categories substrate design after spike data demonstrated
structural perf advantages of compile-time-specialized PDA over
lex+cursor+events.

**Predecessor**: `docs/rfc-three-categories-architecture.md` (Phase 3).
Phase 4 keeps its public-API surface and category model; replaces the
substrate.

## Motivation

Phase 3 delivered composable Cat 1/2/3 consumer surfaces sitting on top of
a lex → cursor → events substrate. Phase 3 also delivered:

- `embed[T]` compile-time decode that survives NimVM
- `#11` closure by construction (no depth-2 children corruption)
- Full P1-P12 property catalog (caught 2 real bugs during the rebuild)
- 338/338 spec conformance
- 3-3.5× memory advantage over the Rust parsers

The Phase 3 substrate has one architectural cost. Cat 2 typed decode runs
~50 μs/Service-100 while knus runs ~48 μs. We're 1.05× slower on the
headline typed-decode benchmark. Profiling reveals the cost is the *eager
lex pass*: ~32 μs of every typed-decode call goes to building a full
TokenStream with payloads (unescaped strings, parsed numbers, interned
names) before the typed consumer sees its first event.

Spike data (`benchmarks/profile_pda_handwritten.nim`,
`benchmarks/profile_pda_macro.nim`):

| Approach | μs / decode-services-100 | Notes |
|---|---|---|
| Current `decode[seq[Service]]` (cursor) | 50.0 | Phase 3 substrate |
| knus `parse::<Vec<Service>>` (chumsky) | 47.7 | Industry reference |
| Hand-written PDA (fixture-specialized) | **5.92** | Architectural ceiling |
| Macro-generated PDA (general) | **12.34** | Phase 4 target shape |

The architecture confirmed by spike: a single-pass byte-level state
machine with consumer handlers fused at compile time eliminates the lex
pass entirely. Estimated full-grammar PDA macro post-Phase-4: **15-20 μs**
for Cat 2, **30-40 μs** for Cat 3, **10-15 μs** for Cat 1 streaming.

## Design decisions (Q1-Q5)

### Q1: Co-existence policy → **replace cleanly**

PDA path lives alongside cursor path during Phase 4 build-out, with a
differential equivalence property `pda_decode[T](src) == cursor_decode[T](src)`
running on arbitrary parseable input. Once all properties + conformance
corpus pass under PDA, the cursor-based path is *deleted*.

End state: one substrate for typed decode. Zero parallel parsers in the
repository.

### Q2: API surface → **silent swap; existing public API unchanged**

`decode[T] / encode[T] / decodeAll[T] / embed[T] / parse() / parseAll() /
kdl:` block macro stay exactly as documented today. The PDA substrate is
an implementation detail.

Power-user escape hatch: `kdlPDA(T)` macro exposed as public for callers
who want explicit per-T specialization. Rare; not the headline.

### Q3: NimVM compat (`embed[T]`) → **hard constraint**

PDA-emitted code must run in NimVM. This rules out:

- FFI (no `equalMem`, no `memcmp`, no libc calls)
- `unsafePtr` arithmetic
- SIMD intrinsics
- Anything `{.compiletime: false.}`

Mitigations:

- Per-key dispatch uses `bytesEqLit`-style inline compares (we have the
  pattern; survives VM)
- Number decode uses pure-Nim arithmetic
- String unescape uses pure-Nim byte ops
- Emitted procs marked `{.noSideEffect.}`

Sprint 1 gate: tracer test `const cfg = decode[Service](staticSrc).get`
must pass at compile time. If it doesn't, abort and revisit before
expanding.

### Q4: Property test coverage

Three layers:

1. **Differential equivalence** (transition-only, deletable):
   `pdaDecode[T](src)` and `cursorDecode[T](src)` produce identical T for
   every input. Runs in `NKDL_PROPTEST=1` suite. Deleted at end of Phase 4.
2. **Preserved**: P7 (typed-T encode-decode identity), P11 (decode never
   crashes), P9 (Cat 2 ↔ Cat 3 agreement — Cat 3 buildDoc-via-PDA is the
   new oracle). All re-pass under the new substrate before Phase 4 ships.
3. **New**: PDA's slot-write order must match user field-declaration order
   (deterministic side-effect ordering for kdlReserved validation, errors).

The `grammar.referenceInterpret` stays as the conformance corpus oracle
unchanged.

### Q5: Substrate count → **single substrate**

PDA replaces cursor entirely. Cat 1/2/3 all sit on PDA:

- **Cat 2 typed decode**: `decode[T]` → PDA with schema-derived handlers
- **Cat 3 untyped DOM**: `parse()` → PDA with KdlDoc-building handlers
  (predefined: allocate `KdlNode`, append entries, push children stack)
- **Cat 1 streaming, fast path**: `kdlParse src:` template — user-provided
  per-event handler blocks; macro specializes the byte-level state
  machine. Maximum throughput.
- **Cat 1 streaming, resumable**: `kdlIterator(src)` closure iterator
  yielding event-equivalent chunks. Lower throughput but supports
  `pos()` / `seek()` semantics for LSP / network streaming.

The cursor module + cursor events go away at the end of Phase 4. The
emitter + docEmit + deriveEncode (OUT side) stay unchanged — they're
already lex-free and write bytes directly.

### Cat 1 streaming surface preview

The two Cat 1 APIs differ in resumability tradeoff:

```nim
# Fast path: template-handler, no allocation, max throughput
kdlParse src:
  onNodeBegin(nameSpan, annoSpan):
    discard
  onArgString(value, annoSpan):
    discard
  onArgInt(value, annoSpan):
    discard
  onProp(key, value, annoSpan):
    discard
  onError(err):
    return err
  onEof:
    break

# Resumable: closure iterator, ~3× slower but pausable
var it = kdlIterator(src)
while not it.atEnd:
  let chunk = it.next()
  case chunk.kind
  of ckNodeBegin: ...
  ...
  # can stop and resume later via:
  let cp = it.checkpoint()
  ... later ...
  var it2 = kdlIterator(src)
  it2.seek(cp)
```

## Predicted end-state perf

| Path | Current (Phase 3) | After Phase 4 | vs knus | vs ckdl |
|---|---|---|---|---|
| Cat 1 drain (template) | 39 μs | **10-15 μs** | — | — |
| Cat 1 iterator (resumable) | 39 μs | **~30 μs** | — | — |
| Cat 2 decode[seq[Service]] | 50 μs | **15-20 μs** | **2.5-3× faster** | n/a |
| Cat 3 parse realistic-config | 62 μs | **30-40 μs** | 10× faster | **2-3× faster** |

If predictions hold: nkdl becomes the fastest KDL parser by a substantial
margin AND keeps 338/338 conformance, embed[T], the property catalog, and
all Phase 3 architectural wins.

## Risk register

| Risk | Mitigation |
|---|---|
| KDL grammar edge cases (multi-line strings with indent stripping, raw strings with hash count, Unicode bareword normalization) prove PDA-awkward | Sprint 1 spike covers a small subset; expand grammar coverage one Sprint at a time. Differential equivalence catches regressions immediately. |
| NimVM-compat lost on a specific feature | Phase 4 abort criterion. Resolve before expanding. |
| Macro compile time gets large for big schemas | Acceptable if it stays under ~5s per schema (we have data on current `kdl:` macro compile time as baseline). Optimize if it grows past that. |
| Macro debugging is hard | Build `dumpKdlGen` define from day 1; differential equivalence catches semantic bugs structurally; reference grammar interpreter catches grammar bugs. |
| Cat 1 resumable closure iterator allocates per yield | Acceptable for the resumable-only path. Document the throughput tradeoff. Fast-path consumers use the template. |
| Property catalog churn | Differential equivalence keeps the Phase 3 properties valid during transition. Port each property to PDA-substrate semantics one at a time. |
| Public API breakage | `decode[T]`, `parse()`, `kdl:` block, `embed[T]` are unchanged. Internal types (`CursorEvent`, `StringCursor`) become private/deleted. |

## Sprint plan

| Sprint | Scope | Gate |
|---|---|---|
| 1 | Minimal `kdlPDA(T)` covering Service-class shape (bareword node + 1 string arg + 3 typed props). VM-compat verified. Differential equivalence vs cursor decode on simple fixtures. | Tracer `embed[Service]` works at compile time. Bench within 2× of hand-written ceiling (~12-15 μs target). |
| 2 | Number/string grammar completeness: escapes, bases, separators, negatives, floats, raw strings, multi-line strings, indent stripping. Reserved keywords, Unicode bareword normalization. | Conformance corpus pass on these features. Differential equivalence holds. |
| 3 | Structural features: type annotations, children blocks (recursive `kdlChild seq[Self]` — #11 closure preserved), enum variants, kdlReserved bounds, kdlRename, Option[T]. | All D-stage cycle tests from Phase 3 pass under PDA. |
| 4 | Slashdash at all three positions; error recovery; `cmAccumulating` mode (multi-error). `parse()` and `parseAll()` rewired to PDA. | Conformance 338/338 holds. `decodeAll` multi-error tests pass. |
| 5 | Property tests P1-P12 ported. PDA-based `buildDoc` for Cat 3. Bench gate vs all competitors. Cursor module deletion. | All P1-P12 pass. Cat 2 ≤ 20μs, Cat 3 ≤ 40μs, Cat 1 ≤ 15μs (template path) — verified in interleaved bench. Cross-impl bench refresh shows nkdl leading typed decode + maintaining other wins. |

Estimated 5-7 focused sessions. May fold sprints together if the macro
proves tractable.

## What gets deleted at end of Phase 4

- `src/cursor.nim` — entire substrate (~700 LOC)
- `src/doc_build.nim` — cursor-events-to-KdlDoc consumer (~330 LOC), replaced by PDA-based parse
- `src/derive_decode.nim` — old macro (~700 LOC), replaced by PDA-based decode
- `tests/test_substrate_properties.nim` — P1, P2 at cursor-event level (replaced by PDA-substrate-level equivalents)
- Cursor-event-related property helpers in `tests/proptest_helpers.nim`

What stays:

- `src/lexer.nim` — wait, this stays? **No.** The PDA macro embeds lex as
  part of its emitted state machine; standalone `lexer.nim` is no longer
  used at runtime. We may keep it as the grammar reference for Sprint 2
  feature porting, then delete.
- `src/emitter.nim` + `src/doc_emit.nim` + `src/derive_encode.nim` — OUT
  side unchanged
- `src/grammar.nim` — `referenceInterpret` stays as the conformance
  differential oracle (it builds its own table-driven recognizer and
  doesn't depend on the cursor or lex)
- `src/ast.nim` — KdlDoc / KdlNode types unchanged
- All public APIs (`decode[T]`, `parse()`, `embed[T]`, `kdl:` block)

## Resume-here pointer

Phase 4 hasn't started. Spike code lives at `benchmarks/profile_pda_handwritten.nim`
and `benchmarks/profile_pda_macro.nim` — not yet merged into the macro
codegen surface.

**Next concrete action**: Sprint 1.
