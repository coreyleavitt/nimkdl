# Cross-implementation benchmark harnesses

Bench code for every KDL parser we compare against. Vendored here so
the numbers in [BENCHMARK.md](../../BENCHMARK.md) are reproducible by
anyone with podman or docker, and so anyone who knows one of these
libraries better than we do can audit our usage.

## What's here

| Directory     | Harness paths timed                                                | Language   |
|---------------|--------------------------------------------------------------------|------------|
| `nimkdl/`     | parse, typed decode (legacy + direct), typed encode (legacy + direct, flat + nested) | Nim |
| `ckdl/`       | event-drain parse only (no typed path exists)                      | C          |
| `knus/`       | parse_ast, typed `Vec<Service>`, typed enum                        | Rust       |
| `facet-kdl/`  | typed `from_str::<ServiceDoc>`, `to_string` encode                 | Rust       |
| `kdl-rs/`     | `KdlDocument::parse_v2`, `to_string` (preserve + canonical)        | Rust       |

The `nimkdl/bench.nim` harness is the load-bearing one for the
cross-impl comparison — it produces every measurable column in one
container run with the same line format as the Rust/C harnesses.
The older `benchmarks/bench.nim` is kept for historical continuity
(it has the section breakdown the early comparison tables used) and
runs via `run.sh nimkdl-legacy`.

## Apples-to-apples mapping

Each row in BENCHMARK.md's typed-decode or typed-encode table maps
to a single function call in one of these harnesses. The mapping is
explicit so a reader can verify the comparison is fair:

| Comparison        | nimkdl                                | competitor                              | Schema identity |
|-------------------|---------------------------------------|-----------------------------------------|-----------------|
| AST parse         | `parse(content)` (kdl.nim)            | kdl-rs `KdlDocument::parse_v2`          | bytes-in only   |
|                   |                                       | ckdl event-drain                        | bytes-in only   |
|                   |                                       | knus `parse_ast`                        | bytes-in only   |
| Typed decode      | `decode[seq[Service]]` (legacy AST)   | knus `parse::<Vec<Service>>`            | Service: name arg, port/replicas/enabled props |
|                   | `parseInto[seq[Service]]` (direct, #1)| facet-kdl `from_str::<ServiceDoc>`      | same Service schema |
| Typed encode      | `encode(seq[Service], emPretty)` (legacy) | facet-kdl `to_string(&doc)`         | same Service schema |
|                   | `encodeFrom(seq[Service])` (direct, #1)   | facet-kdl `to_string(&doc)`         | same Service schema |
| Typed encode (nested) | `encodeFrom(seq[Server])` (direct)| **n/a — no competitor has a nested-shape encode bench** | Server with Action children |

To verify the schema identity claim: open `nimkdl/bench.nim`,
`facet-kdl/main.rs`, and `knus/main.rs` side by side and look at
the `Service` definition. The Nim version uses `kdlNode`/`kdlArg`/
`kdlProp` pragmas to declare the same shape that facet-kdl declares
via `#[facet(kdl::argument)]` etc. and that knus declares via
`#[knus(argument)]` etc.

## Fixture identity

Every harness reads `/fixtures/homogeneous-services-100.kdl` as its
typed-decode fixture. The path is identical because `run.sh` stages
the same source bytes into a single tmpdir and bind-mounts that into
each container at `/fixtures/`. The byte counts each harness prints
on every row let a reader verify identity from the transcript alone.

## What is NOT being compared, and why

Each of these gaps is named explicitly to head off "you're cherry-
picking" critiques:

- **knus encode**: knus has no `to_string` path. The comparison table
  reports "n/a — knus has no encode path" rather than padding zeroes.
- **kdl-rs typed decode**: kdl-rs has no derive-based typed
  decoder; the closest comparable is `KdlDocument::parse_v2` (AST)
  followed by manual walk. We don't conflate that with a typed-decode
  bench. The kdl-rs row in the typed-decode chart reports the AST
  parse time with an explicit "no typed path" annotation.
- **ckdl typed decode**: ckdl is a SAX-event parser with no AST and
  no typed binding layer. We report event-drain time with an explicit
  "no typed path" annotation.
- **ckdl encode**: ckdl exposes only a streaming emitter, not a
  "value-in, string-out" pipe. Not directly comparable to
  `encodeFrom` or `to_string`; we omit it from the encode table
  rather than report a number that means something different.
- **facet-kdl nested encode**: facet-kdl's bench is flat-only.
  Our nested-encode row exists for completeness (to head off "you
  only measured flat encode") but stands alone — we don't claim
  speedup against an absent competitor.

## Running the comparison

```bash
benchmarks/comparisons/run.sh                # every parser
benchmarks/comparisons/run.sh nimkdl         # just the new comprehensive harness
benchmarks/comparisons/run.sh nimkdl-legacy  # parse-only historical bench
benchmarks/comparisons/run.sh ckdl knus      # multiple
```

The orchestrator pipes its transcript to stdout. Save with
`tee benchmarks/comparisons/last-run.txt` if you want a record;
the file is gitignored.

Total runtime is a few minutes on cold caches (image pulls + first
builds of ckdl/knus dominate). Re-runs are under a minute since the
container layers cache.

## Fixture provenance

- `Cargo.kdl`, `ci.kdl`, `website.kdl` come from the [kdl-org examples](https://github.com/kdl-org/kdl/tree/main/examples). Real KDL but barely exercise the language.
- `realistic-config.kdl` is ours. A dense 5.6KB service-deployment config that uses every KDL v2 feature in realistic proportions.
- `homogeneous-services-100.kdl` is ours. 100 lines of identically-shaped `service "name" port=N replicas=N enabled=#true` nodes — the canonical typed-decode and typed-encode fixture. Bytes are identical across every harness in the comparison.
- `unicode-heavy.kdl` is ours. Multi-script identifiers including combining marks and emoji ZWJ sequences. Stress test for the unicode codepoint validation path.
- `all_node_fields.kdl`, `all_escapes.kdl` (when present) come from the kdl-org conformance corpus. Small fixtures that mainly measure per-parse overhead.

## Methodology

The discipline that makes this comparison hold up to outside scrutiny.

- **Same container session for all parsers** in a single comparison
  run (eliminates host scheduler variance).
- **glibc, not musl** — musl swings kdl-rs by 3.6× due to BigInt
  allocator behavior. All comparison images are Debian-based.
- **Release-equivalent flags everywhere**:
  - Nim: `-d:release -d:nimCallDepthLimit=20000` (ORC, default for 2.2.0)
  - Rust: `--release` with workspace `Cargo.toml`s pinning
    `lto = true, codegen-units = 1`
  - C (ckdl): `-O3 -DNDEBUG`
  Mixing flag profiles across implementations is the most common
  dishonest comparison.
- **Vendored fixtures, byte-identical across harnesses**. Each
  harness prints the byte count it consumed on every row so a reader
  can verify identity from the transcript alone.
- **100-iteration warmup before timing**, then 5000 timed iterations
  on the comparison-grade rows (smaller counts on the large fixtures
  to keep runtime reasonable; explicit per-row).
- **Same iteration counts within a row across harnesses**. Different
  counts produce meaningless averages because you're measuring
  different total work.

If you find a methodology issue, please open a PR or issue. The
"this benchmark is dishonest" critique is the most damaging one,
and we'd rather correct it than ship inflated numbers.

## Notes on each harness

### nimkdl

Six measurements in one binary, listed under `=== ... ===` section
headers in the transcript:

1. AST parse on the full fixture corpus.
2. Typed decode (legacy AST + walk): `decode[seq[Service]]`.
3. Typed decode (direct, issue #1): `parseInto[seq[Service]]`.
4. Typed encode (legacy via KdlDoc): `encode(seq[Service], emPretty)`.
5. Typed encode (direct, issue #1): `encodeFrom(seq[Service])`.
6. Typed encode nested: `encodeFrom(seq[Server])` where Server has
   Action children.

The Service schema is identical to facet-kdl/main.rs and knus/main.rs.
Verify by reading those files. The nested shape uses 25 Server × 4
Action = 100 inner nodes (same total work as the flat 100-Service
shape, but exercises indent + recursion).

### ckdl

Event-driven SAX parser. The bench harness calls `kdl_parser_next_event`
in a loop and discards every event. No AST is built. This is the
theoretical floor for "parse cost in C" for this library because there's
no downstream allocation work. We still beat it on most fixtures, see
[BENCHMARK.md](../../BENCHMARK.md#why-ckdl-is-fast-and-why-we-still-beat-it).

### knus

Tests three idiomatic paths.

1. `parse_ast` — parser-only, returns a knus `Document`. Closest
   apples-to-apples with ckdl's event drain and nimkdl's `parse()`.
2. `parse::<Vec<Service>>` — typed homogeneous decode. **The
   apples-to-apples comparison for nimkdl `parseInto[seq[Service]]`.**
3. `parse::<Vec<ConfigNode>>` — typed discriminated union (enum).

knus has no encode path. Don't try to add one — they intentionally
ship a decode-only library.

Note. The knus author has [stated](https://docs.rs/knus/latest/knus/)
that knus is being superseded by `facet-kdl`, which is also in the
comparison.

### facet-kdl

Two paths timed:

1. `from_str::<ServiceDoc>` — typed homogeneous decode. The
   apples-to-apples for nimkdl `parseInto[seq[Service]]`.
2. `to_string(&doc)` — typed encode. **The apples-to-apples for
   nimkdl `encodeFrom(seq[Service])`.**

facet-kdl has no exposed AST-only path; everything goes through
typed deserialize. The crate depends on `kdl ^6.5.0` (kdl-rs), so
its parser cost is bounded by kdl-rs + facet's deserialize layer.

### kdl-rs

Standard `KdlDocument::parse_v2` call plus two encode modes
(`to_string` for trivia-preserving, `autoformat() + to_string()` for
canonical). AST-building only — no typed-binding derive layer.
