# Benchmarks

On a 5.6KB realistic KDL config that exercises every language feature, nkdl parses about **1.54× faster than [ckdl](https://github.com/tjol/ckdl)** (a hand-written C parser), **~7× faster than [knus](https://crates.io/crates/knus)**, and **~16× faster than [kdl-rs](https://github.com/kdl-org/kdl-rs)**. On typed encode `encode[seq[Service]]` is **2.34× faster than [facet-kdl](https://crates.io/crates/facet-kdl)**'s `to_string` (56.1K vs 24.0K ops/s). On typed decode knus's serde-derive edges us 1.22× (20.5K vs 16.8K ops/s). Of the 338 files in the kdl-org reference corpus we accept **243** — the highest of any parser tested. Same container, same input bytes, same iteration counts.

![Headline comparison](docs/charts/headline.svg)

ckdl is the real competition. It's a hand-written C parser with a SAX-style event API and no AST construction overhead in the bench harness. We beat it 1.28-1.62× on realistic + small fixtures, tie in the mid-range, and lose 1.18-1.46× on deep + large synthetic stressors. Everything else trails by an order of magnitude.

## The fixture

`benchmarks/fixtures/realistic-config.kdl` is a 5,629-byte service-deployment config. It uses every KDL v2 keyword (`#true`, `#false`, `#null`, `#inf`, `#-inf`, `#nan`), type annotations on both args and props, multi-line strings, raw strings, all four number bases, line comments, block comments, slashdash, repeated property keys with last-write-wins, and multi-script identifiers in node names. About 7 top-level nodes with 120-ish inner nodes. This is the closest single file we have to "what configs people actually write."

The other kdl-org samples (`Cargo.kdl`, `ci.kdl`, `website.kdl`) are real KDL but barely use the language. Cargo.kdl is 13 lines of strings with no annotations, no keywords, no comments. They stay in the bench as comparison points but the headline number comes from the realistic fixture.

`deep-chain-100.kdl` and `tree-d8-b3.kdl` are synthetic stressors. The former is 100 levels of nested-children depth in a 2.7KB file (worst-case recursion). The latter is a 795KB workspace-monorepo shape with ~9,800 nodes. They're regression guards for specific architectural failure modes — not "realistic" workloads.

## Per-fixture parse comparison

Every fixture, every parser, same container, same iteration counts. Lower μs is better; higher ops/s is better.

facet-kdl is absent from the parse rows because it wraps kdl-rs's parser — its parse number is kdl-rs's.

Honest caveat. This is **apples-to-apples-ish**. Each library is called with its idiomatic "give me my default parse output" API. The output shapes differ:

- ckdl drains SAX events with no AST construction (theoretical floor)
- knus `parse_ast` builds a `Document` with spans
- kdl-rs `KdlDocument::parse_v2` builds the full AST with per-token whitespace storage (the heaviest of the bunch)
- nkdl `parse()` builds a `KdlDoc` with per-node span (no per-token trivia by default)

So they're apples-to-apples on **input cost and flag profile** but doing different amounts of representation work. ckdl in particular is doing strictly less because its harness throws events on the floor.

| Fixture                       | nkdl μs | ckdl μs | knus μs  | kdl-rs μs | Winner            |
|-------------------------------|--------:|--------:|---------:|----------:|-------------------|
| realistic-config.kdl (5.6KB)  |    61.7 |    94.8 |    421.2 |     998.2 | **nkdl 1.54×**    |
| Cargo.kdl (238B)              |     4.3 |     5.5 |     74.9 |      51.2 | **nkdl 1.28×**    |
| ci.kdl (1.2KB)                |    15.7 |    24.4 |    371.2 |     224.9 | **nkdl 1.55×**    |
| website.kdl (2KB)             |    21.6 |    35.0 |    423.5 |     324.7 | **nkdl 1.62×**    |
| flat-deps-100.kdl (4KB)       |   102.2 |   100.9 |   1483.7 |     942.6 | tie               |
| unicode-heavy.kdl (1.2KB)     |    22.7 |    21.8 |    352.9 |     222.2 | tie               |
| homogeneous-services-100      |   130.4 |   131.9 |      n/a |    1206.2 | tie               |
| deep-chain-100.kdl (2.7KB)    |    86.2 |    59.1 |   1778.4 |     931.7 | **ckdl 1.46×**    |
| tree-d8-b3.kdl (795KB)        |   16131 |   13678 |   277001 |    142269 | **ckdl 1.18×**    |

nkdl leads ckdl on realistic + small fixtures (1.28-1.62×), ties in the mid-range, loses on deep + large synthetic stressors (ckdl 1.18-1.46×). knus and kdl-rs trail both by 5-20× on every row.

## Typed decode

The headline bench measures parse-to-AST. Most consumers actually want parse-then-decode-into-typed-structures in one shot. This is what `nkdl decode[T]`, `knus parse::<Vec<T>>`, `facet-kdl from_str::<T>`, and `serde_json::from_str::<T>` all promise.

A homogeneous fixture of 100 service nodes (~5KB, `benchmarks/fixtures/homogeneous-services-100.kdl`).

| Parser           | Path                                | ops/s     | vs knus            |
|------------------|-------------------------------------|----------:|-------------------:|
| **knus**         | `parse::<Vec<Service>>` (serde-derive) | **20,500** | 1.00×              |
| nkdl             | `decode[seq[Service]]`              |    16,800 | knus 1.22× faster  |
| kdl-rs           | (no typed decode path)              |     1,000 | 20× slower         |
| facet-kdl        | `from_str::<ServiceDoc>`            |       700 | 29× slower         |

The Service schema (name arg + 3 typed props) is identical across all three derive-based harnesses — verify by reading `nkdl/bench.nim`, `facet-kdl/main.rs`, and `knus/main.rs` side by side. Source: [`benchmarks/comparisons/last-run.txt`](benchmarks/comparisons/last-run.txt) (regenerate with `benchmarks/comparisons/run.sh`).

knus has a tighter typed-decode pipeline. facet-kdl is 29× slower despite being advertised as knus's successor. Structural reason: facet-kdl depends on `kdl ^6.5.0` (kdl-rs), so its typed-decode perf is bounded by kdl-rs's parser plus the facet deserialize layer. The "successor" framing is about the typed-decode interface improvements (a more general derive system), not the parser.

## Typed encode

Two shapes. Flat: 100 identically-shaped `service` nodes. Nested: 25 Server × 4 Action children = 100 inner nodes (same total work but exercises indent + recursion).

Flat shape (`benchmarks/fixtures/homogeneous-services-100.kdl`):

| Path                                          | ops/s      | vs facet-kdl |
|-----------------------------------------------|-----------:|-------------:|
| **nkdl `encode(seq[Service])`**               | **56,100** | **2.34× faster** |
| facet-kdl `to_string(&doc)`                   |  24,000    | 1.00×        |
| knus                                          | n/a — no encode path | — |
| kdl-rs                                        | n/a — no typed encode path (AST `to_string` is the closest, different work) | — |
| ckdl                                          | n/a — streaming emitter only | — |

Nested shape:

| Path                                          | ops/s       |
|-----------------------------------------------|------------:|
| **nkdl `encode(seq[Server])`**                | **111,200** |

facet-kdl's harness times flat-only — no nested-shape encode is comparable. The nested ops/s is higher than flat because the output is denser per byte (2.6KB vs 5.2KB) — per-call fixed cost amortizes over more inner nodes inside the same byte budget. It's a per-byte normalization quirk, not a separate "encoding is faster on nested shapes" claim.

Source: [`benchmarks/comparisons/last-run.txt`](benchmarks/comparisons/last-run.txt).

## Why ckdl is fast (and how we beat it on realistic configs)

ckdl is a SAX-style parser. It emits events (start-node, argument, property, end-node, etc.) as it walks the input, never constructing an AST. The bench harness drains events into nothing. This is the absolute floor for "parse cost in C" because nothing is allocated downstream.

We build an AST. Every node, every entry, every value gets stored in a `KdlDoc`. We're slower than the theoretical C floor on the deep + large synthetic stressors where ckdl's tight per-byte state machine dominates. We're faster on realistic + small inputs because ckdl pays full per-event dispatch + callback indirection on every token while nkdl's recursive descent goes directly into AST construction with sink semantics — no per-event callback indirection, no malloc churn per event.

The crossover is real: on workloads that look like config files people actually write, AST-building Nim beats event-stream C. On workloads that stress raw throughput on multi-KB-deep nesting or near-megabyte single docs, event-stream C wins.

## Memory footprint

Peak resident memory (Linux `VmPeak`) after parsing each fixture N times with one final result held in scope. Captures both held-doc cost and transient allocator high-water — the number that matters for "will my container OOM."

Same container per parser, same fixtures, glibc. `VmPeak` is monotonic per process, so each `(parser, fixture)` pair runs in a fresh process — otherwise an earlier fixture's peak contaminates later measurements.

### `tree-d8-b3.kdl` (795 KB input, ~9,841 AST nodes)

The peak-driven regime: a single huge document dominates allocator high-water.

| Parser    | Baseline | Peak       | Delta       |
|-----------|---------:|-----------:|------------:|
| ckdl      |  4.2 MB  |  20.6 MB   | **16.4 MB** |
| nkdl      |  4.3 MB  |  34.3 MB   | 30.0 MB     |
| knus      |  4.4 MB  |  92.3 MB   | 87.9 MB     |
| kdl-rs    |  4.0 MB  | 102.4 MB   | 98.3 MB     |
| facet-kdl | — | — | _skipped, no untyped path_ |

ckdl's footprint advantage here is structural — it's SAX-style, no AST built. Among the four AST-building parsers, nkdl is decisively lightest (3-3.5× lighter than knus/kdl-rs).

### `realistic-config.kdl` (6 KB, mixed top-level nodes)

The held-doc regime on a small input: most parsers' deltas are dominated by allocator slack rather than the doc itself.

| Parser    | Baseline | Peak     | Delta     |
|-----------|---------:|---------:|----------:|
| nkdl      |  3.5 MB  |  3.5 MB  | **0 KB**  |
| ckdl      |  3.4 MB  |  3.7 MB  | 260 KB    |
| knus      |  3.6 MB  |  4.0 MB  | 340 KB    |
| kdl-rs    |  3.3 MB  |  3.8 MB  | 528 KB    |
| facet-kdl | — | — | _skipped, no untyped path_ |

The 0 KB nkdl number is real but a measurement artifact: Nim's preallocated heap absorbs the post-baseline allocations entirely before `VmPeak` ticks up. The held doc still exists — it's just under the runtime's already-resident page budget.

### `homogeneous-services-100.kdl` (6 KB, typed Vec<Service>)

Apples-to-apples typed decode — every parser holds a typed value of the same logical shape.

| Parser    | Baseline | Peak     | Delta     |
|-----------|---------:|---------:|----------:|
| nkdl      |  3.5 MB  |  3.5 MB  | **0 KB**  |
| knus      |  3.6 MB  |  4.0 MB  | 336 KB    |
| kdl-rs    |  3.3 MB  |  3.8 MB  | 528 KB    |
| facet-kdl |  4.3 MB  |  4.8 MB  | 572 KB    |
| ckdl      |  3.4 MB  |  5.2 MB  | 1,848 KB  |

ckdl's footprint here is high because the same parse-event drain runs 200× on a small input — each parser instantiation is a fresh allocation cycle that the same-process measurement folds into the peak. The other parsers reuse allocator pages more aggressively across iterations.

### Caveats

`VmPeak` includes runtime baseline + allocator fragmentation + held doc + transient peaks during parse. It's an upper-bound "OOM risk" number, not a pure "doc structural cost in bytes." For per-byte structural cost, a heap profiler (Massif, dhat, custom allocator hooks) would give cleaner numbers — but those don't compare uniformly across language runtimes the way `VmPeak` does.

**ckdl asymmetry.** ckdl is SAX-style — there is no AST built, so there is nothing structural to "hold" between iterations. ckdl's delta therefore captures only transient parse-state high-water, not held-doc cost. The other four parsers' deltas include both. This asymmetry is real and reflects an actual API difference, not a methodology bug: streaming parsers fundamentally have a smaller memory footprint than AST builders for the same input.

**facet-kdl asymmetry.** facet-kdl exposes only a typed `from_str::<T>` entry point — no untyped path. We measure it on the one fixture with a defined typed shape (`homogeneous-services-100.kdl`) and skip the others rather than route them through facet-kdl's transitive kdl-rs dependency (which would just duplicate kdl-rs's numbers under a different label).

## Real-trace replay (kdl-org conformance corpus)

Throughput on the [kdl-org reference test corpus](https://github.com/kdl-org/kdl/tree/main/tests/test_cases) — 338 community-curated KDL files (~7 KB total) that every spec-compliant parser is held against. We didn't pick these fixtures; the kdl-org maintainers did.

Average file is ~21 bytes — most are single-line edge cases. Per-call fixed overhead dominates over byte throughput, so the headline metric is microseconds per parse call (lower is better).

| Parser    | μs / file  | files / sec | accepted / 338 |
|-----------|-----------:|------------:|---------------:|
| ckdl      | **0.47**   | 2,143K      | 240            |
| nkdl      | 1.14       | 878K        | **243**        |
| kdl-rs    | 7.14       | 140K        | 242            |
| knus      | 13.54      | 74K         | 111            |

(facet-kdl skipped — typed-decode-only, no usable untyped path for arbitrary-shape corpus.)

ckdl is fastest per-file (no AST construction); nkdl follows at 2.43× ckdl's per-call time but with the highest spec coverage in the table — 243 of 338 fixtures accepted, matching the kdl-org corpus's own "should parse" count exactly. knus's 111-accepted gap (~130 spec-valid files rejected) is a real correctness signal, not a perf artifact: knus does not implement some KDL v2 features the conformance suite exercises.

Source: `benchmarks/comparisons/last-corpus.txt` (regenerate with `benchmarks/comparisons/run.sh corpus`).

## Edit-then-encode

The editor/formatter workflow: open file → mutate one node → save. Both nkdl and kdl-rs explicitly designed for this (byte-lossless preservation of unmutated regions). Other parsers don't have a mutable AST + encode path, so this is a 2-way comparison.

> **Section pending refresh.** The edit-cycle harness binary failed to rebuild in the last bench run. Regenerate with `benchmarks/comparisons/run.sh edit` after fixing the harness wiring.

The architectural claim that drives the result: nkdl carries a per-node `parseHash`, so on encode the mutated subtree emits canonical text while every unmutated subtree splices source bytes verbatim — the encode cost is bounded by the size of the *change*, not the size of the document. kdl-rs stores per-token whitespace on every node and walks all of it on `to_string`, paying the full tree's emit cost whether or not anything changed.

Source: `benchmarks/comparisons/run.sh edit`.

## Methodology

Cross-implementation benchmarks lie easily. The discipline that makes this comparison hold up to outside scrutiny.

**Same container.** Hardware and scheduler variance swamps most software differences. All parsers run in the same set of containers, back-to-back in the same session.

**Same input bytes, vendored.** "We both used Cargo.kdl" is not the same as "we used the same bytes." Verify byte-for-byte.

**Same iteration counts.** Different counts produce meaningless averages because you're measuring different total work.

**Same flag profile.** All at release+LTO equivalent. Nim is `-d:release -d:lto` with ORC. Rust is `--release` with `lto = true, codegen-units = 1`. C is `-O3 -DNDEBUG`. **No PGO on any parser.** Mixing flag profiles across implementations is the most common dishonest comparison.

**glibc, not musl.** kdl-rs allocates heavily through the `num` BigInt crate and musl's `malloc` punishes that — same kdl-rs build on glibc Debian is 3.6× faster than on musl Alpine. We see only a 5% swing. Use glibc for cross-language Rust benchmarks unless musl is your actual production target.

**Idiomatic API per library.** ckdl is event-driven, so its harness drains events to /dev/null. knus does typed decode in one shot. kdl-rs builds an AST. Different libraries have different output shapes, and that asymmetry is real and worth acknowledging.

## What we don't measure

Error rendering (we have rustc-style diagnostics; kdl-rs has miette's colored carets which do more work per error) and mutation API throughput. Both asymmetric across libraries.

## How to reproduce

All five bench harnesses (nkdl, ckdl, knus, facet-kdl, kdl-rs) are vendored into this repo at `benchmarks/comparisons/`. One script runs them all back-to-back in matched containers.

```bash
benchmarks/comparisons/run.sh           # all five + memory matrix + corpus + edit
benchmarks/comparisons/run.sh nkdl      # one specific
benchmarks/comparisons/run.sh ckdl knus # multiple
benchmarks/comparisons/run.sh memory    # memory footprint matrix only
benchmarks/comparisons/run.sh corpus    # 338-fixture conformance replay
```

Requires `podman` (or set `CONTAINER_RUNTIME=docker`).

See [benchmarks/comparisons/README.md](benchmarks/comparisons/README.md) for per-harness details, fixture provenance, and notes on each library's idiomatic API. If you find an issue with how we're calling one of the other libraries, please open a PR.
