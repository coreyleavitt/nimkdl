# lib/kdl

In-tree Nim library implementing **KDL v2** (https://kdl.dev/spec/) with type-driven parsing and a compile-time-validated typed-path DSL. Used by amoxtli for all user-facing config (rules, workspace config, scorecards, manifests).

> **Status: v0 — work in progress.** Tracked under epic [coreyleavitt/amoxtli#517](https://github.com/coreyleavitt/amoxtli/issues/517).

## Design philosophy

PhD-level use of Nim's macro system. Document languages are exactly where Nim's compile-time-eval combination outshines other systems languages:

1. **Type IS the schema.** `parse[T]` reflects on a Nim type at compile time via `getTypeImpl` and generates the KDL-node-to-field parser+validator directly. No separate schema file format.
2. **Compile-time embedding.** `embed[T]("path/*.kdl")` parses + validates + freezes builtin documents as binary constants. Impossible to ship malformed builtins.
3. **Grammar-as-executable-spec.** A `kdlGrammar:` macro block expresses the KDL v2 grammar declaratively and generates a reference interpreter; conformance tests prove the hand-tuned parser stays equivalent.
4. **Typed schema-path DSL.** `doc.path{rule[enabled].action[kind == akInject].template}` validates every field reference at compile time against the pragma-annotated Nim type. Typos produce "did you mean" diagnostics.
5. **Zero-alloc fast path** via SBO string interner.
6. **`Result[T, ParseError]`** — no exceptions across parser boundary.
7. **`{.noSideEffect.}` parser** — runs at compile time.

## What we explicitly DON'T implement

- **KSL (KDL Schema Language).** Spec targets KDL v1 only, never updated for v2, no reference implementation in `kdl-rs`, transitively depends on KQL. Replaced by Nim-type-is-schema.
- **KQL (KDL Query Language).** Spec is explicitly unreleased ("describes KQL `next`. It is unreleased"). Reference Rust impl has KQL tests under `tests/disabled_tests/`. Replaced by typed-path DSL.
- **KDL v1 compatibility.** No v1 → v2 shim. We don't ingest external KDL v1 documents.

## Spec coverage

| Feature | Status |
|---|---|
| KDL v2 lexer + parser | planned (#521, #523) |
| AST + canonical encoder | planned (#522, #524) |
| Grammar DSL + reference interpreter | planned (#525) |
| kdl-org conformance corpus | planned (#526) |
| `parse[T]` macro | planned (#528) |
| `embed[T]` macro | planned (#529) |
| Typed-path DSL (`path{}` macro + iterator helpers + pattern-match examples) | planned (#534) |

## Extraction path

If KDL parsing ever earns its own ecosystem story, `git subtree split --prefix=lib/kdl main` produces a clean standalone repo with full history. No surgery needed inside amoxtli.

## License

MIT.
