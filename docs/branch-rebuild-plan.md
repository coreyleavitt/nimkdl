# Branch-rebuild plan: clean-core for symmetric IN/OUT

**Status**: Operational sequencing for the three-categories v1 milestone, replacing the incremental Phase 3-5 plan.
**Scope**: Build emitter + docEmit + deriveDecode + deriveEncode on a clean branch, sharing the existing cursor + buildDoc foundation.
**Design doc**: `docs/rfc-three-categories-architecture.md` (read it first if you haven't).
**Validation gate**: Full nimble + `NKDL_PROPTEST=1` + 338-fixture conformance pass against the new substrate.

## Where to resume

Read this section first each session. Update the "current state" line at the end of every commit on the branch.

**Current state**: Stage A complete (A1-A11; 48 emitter tests passing; full suite GREEN). BufferEmitter primitive lives in `src/emitter.nim`. KdlEmitter concept + validateKdlEmitter template established. P12 round-trip property exercised via 11 table-driven cases — cursor accepts everything BufferEmitter emits.

**Next action**: Start Stage B (docEmit). First cycle B1: walk a single-bare-node KdlDoc, push events into BufferEmitter, expect canonical `"foo\n"` bytes. The emitter API is ready (typed primitives + KdlValue dispatcher); docEmit just orchestrates the walk.

## Delete order

Delete in this order. Each deletion is its own commit. The repo will go RED after the first deletion and stay RED until the rebuild reaches the validation gate. That's expected.

1. `tests/test_typed_parser.nim`, `tests/test_typed_parser_vm.nim`, `tests/test_multi_error.nim` — tests of the visitor protocol entry points
2. `tests/test_doc_builder.nim`, `tests/test_doc_builder_conformance.nim` — tests of the visitor-based DocBuilder
3. `tests/test_visitor_*.nim`, `tests/test_parametric_builders.nim`, `tests/test_kdl_pragma.nim` (if visitor-specific) — visitor surface tests
4. `tests/test_preserve_properties.nim`, `tests/test_typed_decode_properties.nim` — old PBT suites (replaced by new property catalog)
5. `tests/test_codegen.nim`, `tests/test_decode_regressions.nim`, `tests/test_decode_all.nim`, `tests/test_h2_compiletime.nim`, `tests/test_embed.nim`, `tests/test_bareword_enum.nim`, `tests/test_option_and_node_tags.nim`, `tests/test_kdl_reserved_pragma.nim`, `tests/test_variant.nim`, `tests/test_accessors.nim`, `tests/test_encode_typed.nim`, `tests/test_derive_encode.nim`, `tests/test_encode.nim`, `tests/test_preserve_format_optin.nim`, `tests/test_preserve.nim` — touch the decode/encode user surface; rebuilt as the new substrate becomes available
6. `tests/test_readme_examples.nim`, `tests/test_public_api.nim` — user-facing entry-point smoke
7. `tests/test_builder.nim`, `tests/test_grammar.nim` — likely re-derivable; revisit
8. `src/codegen.nim` — entire file (keep `bytesEq`, `kdlNode`/`kdlArg`/`kdlProp`/`kdlChild`/`kdlReserved`/`kdlRename` pragma declarations elsewhere if they live in this file, but the codegen procs go)
9. `src/typed_parser.nim` — entire file
10. `src/doc_builder.nim` — entire file (buildDoc in cursor.nim replaces it)
11. `src/encode.nim` direct-byte writer machinery — keep only the value-formatting helpers; everything else goes

Run `nimble test` after step 8 — expect massive RED. From here forward, every cycle's GREEN incrementally restores test files (re-creating them on the new substrate, not undoing deletions).

## Build order

Sequence of TDD cycles. Each cycle: RED test → minimal impl → GREEN → next cycle. The cycle granularity is the same as Phase 1+2 — one test, one behavior, one commit-able piece.

### Stage A: KdlEmitter primitive (cycles A1-A11)

Build the emitter against P1's foundation invariant. Perf-first from A1: setLen-based writes, depth-indexed indent cache, inline accessors, overloaded value-typed pushes.

**Push API shape** (overloaded for zero-overhead at each producer):
- `pushNodeBegin(e, name: openArray[byte], anno: openArray[byte])` — synthesized path
- `pushNodeBeginTok(e, name: Token, anno: Token, c: KdlCursor)` — round-trip path (zero copy)
- Per-type `pushArgInt / pushArgFloat / pushArgString / pushArgBool / pushArgNull` (codegen path — no KdlValue box)
- `pushArg(e, v: KdlValue)` (docEmit convenience — internal dispatch to typed variant)
- Same overload pattern for `pushProp*`
- `pushChildrenBegin / pushChildrenEnd / pushNodeEnd / pushSlashdashBegin / pushSlashdashEnd`

**Cycles:**

- **A1**: BufferEmitter — `newBufferEmitter()` + `finish()` returns empty string for no events
- **A2**: `pushNodeBegin("foo") + pushNodeEnd()` → `"foo\n"` (synthesized path)
- **A3**: Typed value pushes — `pushArgInt(42)` between Begin/End → `"foo 42\n"`; verify no KdlValue allocation
- **A4**: `pushPropInt("x", 1)` → `"foo x=1\n"`
- **A5**: ChildrenBegin/End nesting with depth-indexed indent cache (`const Indents = ["", "    ", ...]` to depth 16; reallocate beyond)
- **A6**: Annotations on node + arg + prop (openArray[byte] variant)
- **A7**: SlashdashBegin/End brackets (skip-mode emit)
- **A8**: Round-trip token-variant pushes — `pushNodeBeginTok(tok, c)` writes the source bytes directly via cursor's `bytes(tok)` accessor
- **A9**: KdlValue convenience overload — `pushArg(v: KdlValue)` dispatches to typed variant; benchmark vs. typed direct (must be ≤ 1.05× slower to satisfy "AST consumers pay the AST cost, codegen path is free")
- **A10**: KdlEmitter concept definition + `validateKdlEmitter[E]` static check
- **A11** (property): P12 — emitter never produces unparseable bytes (cursor accepts everything emitter emits)

### Stage B: docEmit (cycles B1-B6)

Walk a KdlDoc, push events into emitter. Restores Cat 3 OUT.

- **B1**: Single bare node — `doc{nodes=[foo]} → "foo\n"`
- **B2**: Args, props on a node
- **B3**: Children blocks
- **B4**: Type annotations
- **B5**: Preserve mode integration with parseHash matching (the new emitter does the splicing)
- **B6** (property): P4 — doc structural round-trip; P5 — preserve byte-exact

After B6: `tests/test_cat3_properties.nim` is filled in with P4/P5/P6. The
existing 338-fixture conformance corpus passes (preserve-mode byte-exact). The
encode side of the architecture is done.

### Stage C: deriveEncode (cycles C1-C10)

Codegen for Cat 2 OUT. Macro emits `kdlEncode[E: KdlEmitter]` per type.

**Perf-first framing**: each cycle emits *specialized code for the type's shape*, not boilerplate. The macro is justified because it lays out cursor + destination writes adjacent for the optimizer, encodes field-slot indices as consts, and inlines kdlReserved tag literals — things a generic `when`/`fieldPairs` chain cannot guarantee.

- **C1**: Plain object with kdlArg, kdlProp — emit typed-value pushes directly (`pushArgInt(e, v.field)`), never via KdlValue
- **C2**: Multiple positional args — emit in field declaration order, one push per field
- **C3**: kdlChild single (nested type) — direct `kdlEncode(child, e)` call (compiler monomorphizes)
- **C4**: kdlChild seq[T] — emit `for c in v.children: kdlEncode(c, e)` loop
- **C5**: Option[T] arg/prop/child — emit `if v.field.isSome: ... ` (no allocation on None)
- **C6**: Enum — emit `case v.field` with per-variant literal string push
- **C7**: Variant (case object) — discriminator-driven `case` branch emit; per-branch body inlined
- **C8**: Field-level kdlReserved — emit literal anno bytes (`pushArgIntAnno(e, v.field, "u8")`), not runtime pragma lookup
- **C9**: kdlRename — substitute renamed bytes as literal at macro expansion time
- **C10** (property): P8 encode determinism + bench gate (C1 Service must hit ≥ current 1.07× facet-kdl perf)

### Stage D: deriveDecode (cycles D1-D15)

Codegen for Cat 2 IN. Macro emits `kdlDecode[C: KdlCursor]` per type.

**Perf-first framing**: each cycle emits shape-specialized dispatch. kdlProp lookup uses if-elif (≤8 fields) or perfect-hash jump (>8). Required-field tracking uses pre-assigned slot indices as consts. Variant dispatch is case-on-discriminator-hash with inlined per-branch bodies. Self-recursive `seq[Self]` is trivial because `kdlDecode[seq[Self]]` directly recurses into `kdlDecode[Self]` — closes #11/#7 by construction at D4, not D6.

- **D1**: Plain object with kdlArg + kdlProp — pull cursor events, direct slot writes (no intermediate buffer); set required-field bits
- **D2**: Multiple kdlArgs — positional index dispatched via `case argIdx of 0: ... 1: ... else: peExtraArg`
- **D3**: kdlProp dispatch — if-elif of `bytesEq(propName, "x")` for ≤8 fields
- **D4**: kdlChild single + kdlChild seq[T] + self-recursive Tree — direct `kdlDecode[Self]` call recursion (closes #11/#7 user-visible)
- **D5**: kdlProp perfect-hash dispatch — for types with >8 kdlProp fields, emit hash jump table at macro time
- **D6**: Option[T] arg/prop/child — slot writes set `isSome = true` inline, no allocator paths
- **D7**: Enum — bareword token compared via `bytesEq` to inlined literal per variant; missing case → peTypeEnumInvalid
- **D8**: Variant types — case-on-discriminator-bytes; per-branch object decoder body inlined
- **D9**: kdlReserved field/type-level tag validation — `bytesEq(anno, "<literal>")` against macro-inlined expected bytes
- **D10**: Required-field bitmap — uint64 slot bits for ≤64 fields, array[N, uint64] for more; final mask compare; peMissingRequired emits the first missing slot's name (precomputed at macro time)
- **D11**: Type-mismatch error semantics matching peTypeMismatch / peTypeEnumInvalid / peTypeDiscriminatorBad / peTypeReservedMismatch
- **D12**: kdlRename — macro substitutes renamed bytes as literal
- **D13**: embed[T] (VM-compatible compile-time decode) — noSideEffect chain; verify macro output runs in NimVM
- **D14**: bench gate — typed-decode Service round-trip must hit ≥ current 1.07× knus parity
- **D15** (property): P7 typed-T encode-decode identity, with re-activated L1/L2/L3 + Tree properties

### Stage E: kdl: macro orchestration (cycles E1-E2)

- **E1**: kdl: macro now emits `deriveDecode(T)` + `deriveEncode(T)` for each kdlNode-tagged type. Equivalent ergonomic surface as before.
- **E2**: decode[T] / encode[T] / decodeAll[T] entry points rewired to use new procs

### Stage F: cross-category + safety properties (cycles F1-F4)

- **F1**: tests/test_crosscat_properties.nim — P9, P10
- **F2**: tests/test_safety_properties.nim — P11, P12
- **F3**: Grammar-aware event-sequence generator in tests/proptest_helpers.nim
- **F4**: tests/test_substrate_properties.nim — P1, P2 against the new generator

### Stage G: validation gate

- **G1**: Full `nimble test` clean
- **G2**: Full `NKDL_PROPTEST=1 nimble test` clean
- **G3**: 338-fixture conformance corpus pass
- **G4**: Bench gate (Phase 6 / #19): ±10% of pre-rebuild ~46.9μs/100-Service baseline

After G4: merge branch to main (or rename branch → main if cleaner).

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Emitter design surfaces requirements that need cursor changes | Cursor changes are cheap; the cursor is the smallest piece. Cycle back if needed. |
| preserveFormat byte-exact correctness regresses | 338-fixture corpus gates it precisely; emPreserve byte-equivalence is a hard test. |
| Variant types' codegen is harder than expected (existing emitVariantVisitor is ~870 LOC) | Variant adds a discriminator-decode dispatcher; the per-branch body is otherwise the same as flat objects. Reuse the variant-shape collector from old codegen. |
| Grammar-aware event-sequence generator (F3) is harder than estimated | Time-box: if F3 takes >2 sessions, fall back to "generate via arbitrary parseable KDL strings then walk cursor" — less rigorous but unblocks F4. File issue for the proper generator. |
| Long branch lifetime diverges from main | Branch should land in 2-4 focused sessions. If it stretches >4 sessions, audit for scope creep. |

## What we get at the end

- One macro file (`src/codegen.nim`) ~500-700 LOC instead of ~3060
- One encode file (`src/encode.nim`) ~300-400 LOC instead of ~955
- KdlEmitter primitive ~300-400 LOC (new)
- All three categories ride symmetric cursor + emitter substrates
- Cat 1 OUT is now possible (user push events into emitter)
- New property catalog catches structural invariants the user-API tests couldn't
- L1/L2/L3 + Tree properties re-activated; #11 + #7 closed by construction
- Phase 5 just doesn't exist — there's no legacy to delete because the branch never had it

## Open questions to flag during execution

1. Does the emitter need a `pushNewline()` for canonical-mode line breaks, or is line breaking implicit (e.g., always after NodeEnd)?
2. How does preserve-mode handle a node whose parseHash matches but whose children were mutated? (Splice the head, recurse children?)
3. Should the emitter support a "compact" mode (no indentation, semicolons) in addition to canonical? Probably yes; integrate from C5.
4. Does deriveEncode need an `emit-as-arg-only` mode for embedded use (no node wrapper)? Probably not for v1; defer.
5. What's the right error-handling story when the emitter encounters an invalid value (e.g., negative number with `(u8)` annotation that should reject)? Either the emitter validates and errors, or it trusts the caller — pick one.

## Resume-here pointer

Update this line at the end of every session.

**Last session ended after**: Stage A complete. Branch has 8 commits since main; 48 emitter tests + the surviving cursor/buildDoc/parser/grammar substrate all GREEN.

**Next concrete action**: Stage B1 — docEmit tracer. Create `src/doc_emit.nim` (single proc `emitDoc(doc: KdlDoc, e: var BufferEmitter)`) and a test that emits a one-bare-node doc through it and verifies the output equals `"foo\n"`. After B6 the 338-fixture conformance corpus comes back.
