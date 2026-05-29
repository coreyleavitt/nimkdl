# Branch-rebuild plan: clean-core for symmetric IN/OUT

**Status**: Operational sequencing for the three-categories v1 milestone, replacing the incremental Phase 3-5 plan.
**Scope**: Build emitter + docEmit + deriveDecode + deriveEncode on a clean branch, sharing the existing cursor + buildDoc foundation.
**Design doc**: `docs/rfc-three-categories-architecture.md` (read it first if you haven't).
**Validation gate**: Full nimble + `NKDL_PROPTEST=1` + 338-fixture conformance pass against the new substrate.

## Where to resume

Read this section first each session. Update the "current state" line at the end of every commit on the branch.

**Current state**: Plan doc filed; RFC updated. Branch not yet created. Existing main is stable post-Phase 2.

**Next action**: Create branch `phase3-clean-core` from main. Stage the deletions (see "Delete order" below). First TDD cycle starts after the deletions land.

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

### Stage A: KdlEmitter primitive (cycles A1-A8)

Build the emitter against P1's foundation invariant.

- **A1**: BufferEmitter — `newBufferEmitter()` + `finish()` returns empty string for no events
- **A2**: `pushNodeBegin("foo") + pushNodeEnd()` → `"foo\n"`
- **A3**: `pushArg(newIntValue(42))` between Begin/End → `"foo 42\n"`
- **A4**: `pushProp("x", newIntValue(1))` → `"foo x=1\n"`
- **A5**: ChildrenBegin/End nesting with indentation
- **A6**: Annotations on node + arg + prop
- **A7**: SlashdashBegin/End brackets (skip-mode emit)
- **A8**: KdlEmitter concept definition + `validateKdlEmitter[E]` static check
- **A9** (property): P12 — emitter never produces unparseable bytes (cursor accepts everything emitter emits)

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

- **C1**: Plain object with kdlArg, kdlProp — `kdlEncode(v, e)` pushes nodeBegin/arg/prop/nodeEnd
- **C2**: Multiple positional args (kdlArg order)
- **C3**: kdlChild single (nested type)
- **C4**: kdlChild seq[T]
- **C5**: Option[T] arg/prop/child (omit if none)
- **C6**: Enum (kdlReserved or string-mapped)
- **C7**: Variant (case object) — discriminator-driven branch emit
- **C8**: Field-level kdlReserved (tag emission)
- **C9**: kdlRename
- **C10** (property): P8 encode determinism

### Stage D: deriveDecode (cycles D1-D15)

Codegen for Cat 2 IN. Macro emits `kdlDecode[C: KdlCursor]` per type.

- **D1**: Plain object with kdlArg + kdlProp — pull events from cursor, place into fields
- **D2**: Multiple kdlArgs (positional index)
- **D3**: kdlProp bytesEq dispatch
- **D4**: kdlChild single
- **D5**: kdlChild seq[T] (with bytesEq dispatch on child node name)
- **D6**: Self-recursive Tree — direct call recursion (closes #11/#7 user-visible)
- **D7**: Option[T] arg/prop/child
- **D8**: Enum (bareword + string mapping)
- **D9**: Variant types
- **D10**: kdlReserved field/type-level tag validation
- **D11**: Required-field bitmap + missing-required error
- **D12**: Type-mismatch error semantics matching existing peTypeMismatch / peTypeEnumInvalid / peTypeDiscriminatorBad / peTypeReservedMismatch
- **D13**: kdlRename
- **D14**: embed[T] (VM-compatible compile-time decode) — noSideEffect chain
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

**Last session ended after**: RFC update + plan doc filed. Branch not yet created.

**Next concrete action**: `git checkout -b phase3-clean-core`, then commit 1: delete `src/typed_parser.nim` + `src/doc_builder.nim` + most of `src/codegen.nim` per the delete order above. Expect massive RED after this commit.
