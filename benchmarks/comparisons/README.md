# Cross-implementation benchmark harnesses

Bench code for the three KDL parsers we compare against. Vendored
here so the numbers in [BENCHMARK.md](../../BENCHMARK.md) are
reproducible by anyone with podman or docker, and so anyone who
knows one of these libraries better than we do can audit our usage.

## What's here

| Directory | Harness                                | Notes |
|-----------|----------------------------------------|-------|
| `ckdl/`   | C, SAX-style event-drain               | Hand-written, generally the floor for parse cost. |
| `knus/`   | Rust, three paths (parse_ast, typed Vec<T>, typed enum) | Serde-style decode framework. Author has flagged it as superseded by `facet-kdl`. |
| `kdl-rs/` | Rust, `KdlDocument::parse_v2`          | The canonical Rust implementation. |

The nimkdl harness lives one level up at `benchmarks/bench.nim`
(it's our own code, no need to vendor a copy).

## Running the comparison

```bash
benchmarks/comparisons/run.sh           # all four parsers
benchmarks/comparisons/run.sh nimkdl    # one specific
benchmarks/comparisons/run.sh ckdl knus # multiple
```

Each parser runs in its own glibc-based container. Fixtures are
staged into a single tmpdir and mounted at `/fixtures/` so all four
harnesses see byte-identical inputs.

Total runtime is a few minutes on cold caches (image pulls + first
builds of ckdl/knus dominate). Re-runs are under a minute since
the container layers cache.

## Fixture provenance

- `Cargo.kdl`, `ci.kdl`, `website.kdl` come from the [kdl-org examples](https://github.com/kdl-org/kdl/tree/main/examples). Real KDL but barely exercise the language.
- `realistic-config.kdl` is ours. A dense 5.6KB service-deployment config that uses every KDL v2 feature in realistic proportions.
- `unicode-heavy.kdl` is ours. Multi-script identifiers including combining marks and emoji ZWJ sequences. Stress test for the unicode codepoint validation path.
- `all_node_fields.kdl`, `all_escapes.kdl` (when present) come from the kdl-org conformance corpus. Small fixtures that mainly measure per-parse overhead.

## Notes on each harness

### ckdl

Event-driven SAX parser. The bench harness calls `kdl_parser_next_event`
in a loop and discards every event. No AST is built. This is the
theoretical floor for "parse cost in C" for this library because there's
no downstream allocation work.

We still beat it on most fixtures, see [BENCHMARK.md](../../BENCHMARK.md#why-ckdl-is-fast-and-why-we-still-beat-it).

### knus

Tests three idiomatic paths.

1. `parse_ast` — parser-only, returns a knus `Document`. The closest
   apples-to-apples with ckdl's event drain and nimkdl's `parse()`.
2. `parse::<Vec<Service>>` — typed homogeneous decode. The serde-
   style sweet spot.
3. `parse::<Vec<ConfigNode>>` — typed discriminated union (enum)
   over heterogeneous top-level nodes. The pattern knus's own docs
   recommend for parsing real configs.

All three produce within ~10% of each other on realistic-config,
except the homogeneous typed path which is actually slower than
parse_ast. See BENCHMARK.md's typed-decode section.

Note. The knus author has [stated](https://docs.rs/knus/latest/knus/)
that knus is being superseded by `facet-kdl`. When that ships, we
should add it to the comparison.

### kdl-rs

Standard `KdlDocument::parse_v2` call. AST-building.

## Methodology

See [BENCHMARK.md](../../BENCHMARK.md#methodology) for the full
discipline notes. The short version.

- Same container session for all parsers in a single comparison
  run (eliminates host scheduler variance)
- glibc, not musl (musl swings kdl-rs by 3.6x due to BigInt allocator behavior)
- Release+LTO equivalent everywhere (`-d:release`, `--release` with
  `lto = true, codegen-units = 1`, `-O3 -DNDEBUG`)
- Vendored fixtures, byte-identical across harnesses
- 5000 iterations on the larger fixtures, 10000 on the smaller ones
- 100-iter warmup per fixture per harness

If you find a methodology issue, please open a PR or issue. The
"this benchmark is dishonest" critique is the most damaging one,
and we'd rather correct it than ship inflated numbers.
