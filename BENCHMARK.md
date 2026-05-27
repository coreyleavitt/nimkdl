# Benchmarks

On a 5.6KB realistic KDL config that exercises every language feature, nimkdl parses about 1.58x faster than ckdl (a well-engineered C library), 9x faster than knus, and ~20x faster than kdl-rs. On typed-decode (100-Service fixture) `parseInto` edges knus's serde-derive at 23.3K vs 21.8K ops/s. On typed-encode `encodeFrom` is 4.87x faster than facet-kdl's `to_string`. Same container, same input bytes, same iteration counts.

![Headline comparison](docs/charts/headline.svg)

ckdl is the real competition here. It's a hand-written C parser with a SAX-style event API, no AST construction overhead in the bench harness. We're beating it by 25-40% on most fixtures and trading blows with it on the smallest ones. Everything else trails by an order of magnitude or more.

## The fixture

`benchmarks/fixtures/realistic-config.kdl` is a 5,629-byte service-deployment config. It uses every KDL v2 keyword (`#true`, `#false`, `#null`, `#inf`, `#-inf`, `#nan`), type annotations on both args and props, multi-line strings, raw strings, all four number bases, line comments, block comments, slashdash, repeated property keys with last-write-wins, and multi-script identifiers in node names. About 7 top-level nodes with 120-ish inner nodes. This is the closest single file we have to "what configs people actually write."

The other kdl-org samples (`Cargo.kdl`, `ci.kdl`, `website.kdl`) are real KDL but barely use the language. Cargo.kdl is 13 lines of strings with no annotations, no keywords, no comments. They stay in the bench as comparison points but the headline number comes from the realistic fixture.

## Per-fixture comparison

Every fixture, every parser, same container, same iteration counts.

facet-kdl is absent from these rows because it wraps kdl-rs's parser — its parse number is kdl-rs's.

Honest caveat. This is **apples-to-apples-ish**. Each library is called with its idiomatic "give me my default parse output" API. The output shapes differ:

- ckdl drains SAX events with no AST construction (theoretical floor)
- knus `parse_ast` builds a `Document` with spans
- kdl-rs `KdlDocument::parse_v2` builds the full AST with per-token whitespace storage (the heaviest of the bunch)
- nimkdl `parse()` builds a `KdlDoc` with per-node span (no per-token trivia by default)

So they're apples-to-apples on **input cost and flag profile** but doing different amounts of representation work. ckdl in particular is doing strictly less because its harness throws events on the floor.

| Fixture                       | nimkdl | ckdl   | knus  | kdl-rs | Winner |
|-------------------------------|-------:|-------:|------:|-------:|--------|
| realistic-config.kdl (5.6KB)  | 24.8K  | 15.7K  | 2.6K  |  1.2K  | nimkdl 1.58x |
| Cargo.kdl (238B)              | 350.4K | 225.3K | 14.2K |  23.8K | nimkdl 1.56x |
| ci.kdl (1KB)                  | 96.4K  | 53.1K  | 2.9K  |  5.0K  | nimkdl 1.82x |
| website.kdl (2KB)             | 66.1K  | 38.6K  | 2.8K  |  3.6K  | nimkdl 1.71x |
| flat-deps-100.kdl (4KB)       | 16.9K  | 14.4K  | 0.7K  |  1.3K  | nimkdl 1.17x |
| tree-d8-b3.kdl (794KB)        | 123    | 102    |   4   |    8   | nimkdl 1.21x |
| deep-chain-100.kdl (2.7KB)    | 22.4K  | 22.2K  | 0.6K  |  1.3K  | nimkdl 1.01x (tie) |
| unicode-heavy.kdl (1.2KB)     | 80.8K  | 60.0K  | 3.0K  |  5.5K  | nimkdl 1.35x |

nimkdl leads every parse row — by 1.5× or more on five of them, by 1.17-1.21× on flat-deps and tree-d8, and tied with ckdl on deep-chain.

## Typed decode

The headline bench measures parse-to-AST. Most consumers actually want parse-then-decode-into-typed-structures in one shot. This is what `nimkdl parseInto[T]`, `knus parse::<Vec<T>>`, and `serde_json::from_str::<T>` all promise.

A homogeneous fixture of 100 service nodes (~5KB, `benchmarks/fixtures/homogeneous-services-100.kdl`).

| Parser           | Path                                | ops/s   | vs knus |
|------------------|-------------------------------------|--------:|----------:|
| **nimkdl**       | `parseInto[seq[Service]]`           | **23,300** | **1.07x faster** |
| knus             | `parse::<Vec<Service>>` (typed)     | 21,800  | 1.00x |
| kdl-rs           | `KdlDocument::parse_v2` (no typed path) | 1,000   | 22x slower |
| facet-kdl        | `from_str::<ServiceDoc>`            | 900     | 24x slower |

The Service schema (name arg + 3 typed props) is identical across all three derive-based harnesses — verify by reading `nimkdl/bench.nim`, `facet-kdl/main.rs`, and `knus/main.rs` side by side. Source: `benchmarks/comparisons/last-run.txt` (regenerate with `benchmarks/comparisons/run.sh`).

facet-kdl is 25× slower despite being advertised as knus's successor. Structural reason: facet-kdl depends on `kdl ^6.5.0` (kdl-rs), so its typed-decode perf is bounded by kdl-rs's parser plus the facet deserialize layer. The "successor" framing is about the typed-decode interface improvements (a more general derive system), not the parser.

## Typed encode

Two shapes. Flat: 100 identically-shaped `service` nodes. Nested: 25 Server × 4 Action children = 100 inner nodes (same total work but exercises indent + recursion).

Flat shape (`benchmarks/fixtures/homogeneous-services-100.kdl`):

| Path                                       | ops/s    | vs facet-kdl |
|--------------------------------------------|---------:|-------------:|
| **nimkdl `encodeFrom(seq[Service])`**      | **139.6K** | **4.87x faster** |
| facet-kdl `to_string(&doc)`                |  28.7K   | 1.00x        |
| knus                                       | n/a — no encode path | — |
| kdl-rs                                     | n/a — no typed encode path (AST `to_string` is the closest, different work) | — |
| ckdl                                       | n/a — streaming emitter only | — |

Nested shape:

| Path                                          | ops/s    |
|-----------------------------------------------|---------:|
| **nimkdl `encodeFrom(seq[Server])`**          | **374.3K** |

facet-kdl's harness times flat-only — no nested-shape encode is comparable. The nested-shape number exists to defend against "you only measured flat encode" rather than to claim a speedup. It's faster than flat in absolute ops/s because the output is denser per byte (2.4KB vs 5.2KB) — per-call fixed cost amortizes over more nodes inside the same byte budget.

Source: `benchmarks/comparisons/last-run.txt`.

## Why ckdl is fast (and why we still beat it)

ckdl is a SAX-style parser. It emits events (start-node, argument, property, end-node, etc.) as it walks the input, never constructing an AST. The bench harness drains events into nothing. This is the absolute floor for "parse cost in C" because nothing is allocated downstream.

We do build an AST. Every node, every entry, every value gets stored in a `KdlDoc`. We're slower than the theoretical C floor would be... except we're not, we're faster.

The reason: ckdl uses a state machine inside `kdl_parser_next_event` that dispatches per byte and emits events through a function-pointer callback. Each event is one allocation (the `kdl_event_data` struct), plus the parser's internal small-buffer for the current token. Integrated over thousands of events per parse, that overhead adds up.

Our parser does recursive descent directly into the AST. Each node allocates exactly once and gets moved up the call stack via sink semantics. No per-event dispatch overhead, no callback indirection, no malloc churn.

So the comparison isn't "Nim parser beats C parser at C parser's game." It's "AST-building Nim parser is faster than event-stream C parser if you eliminate the allocation overhead." That happens to be the apples-to-apples comparison for "how fast does my program get a usable tree out of a KDL file."

## Memory footprint

Peak resident memory (Linux `VmPeak`) after parsing each fixture N
times with one final result held in scope. Captures both held-doc
cost and transient allocator high-water — the number that matters
for "will my container OOM."

Same container per parser, same fixtures, glibc. `VmPeak` is
monotonic per process, so each `(parser, fixture)` pair runs in a
fresh process — otherwise an earlier fixture's peak contaminates
later measurements.

### `tree-d8-b3.kdl` (795 KB input, ~9,841 AST nodes)

The peak-driven regime: a single huge document dominates allocator
high-water.

| Parser    | Baseline | Peak       | Delta      |
|-----------|---------:|-----------:|-----------:|
| ckdl      |  4.2 MB  |  20.6 MB   | **16.0 MB** |
| nimkdl    |  4.1 MB  |  29.5 MB   | **24.7 MB** |
| knus      |  4.3 MB  |  92.3 MB   | 85.8 MB    |
| kdl-rs    |  4.0 MB  | 102.4 MB   | 96.0 MB    |
| facet-kdl | — | — | _skipped, no untyped path_ |

### `realistic-config.kdl` (6 KB, mixed top-level nodes)

The held-doc regime on a small input: most parsers' deltas are
dominated by allocator slack rather than the doc itself.

| Parser    | Baseline | Peak     | Delta     |
|-----------|---------:|---------:|----------:|
| nimkdl    |  3.4 MB  |  3.4 MB  | **0 KB**  |
| ckdl      |  3.4 MB  |  3.7 MB  | 260 KB    |
| knus      |  3.6 MB  |  4.0 MB  | 340 KB    |
| kdl-rs    |  3.3 MB  |  3.8 MB  | 528 KB    |
| facet-kdl | — | — | _skipped, no untyped path_ |

The 0 KB nimkdl number is real but a measurement artifact: Nim's
preallocated heap absorbs the post-baseline allocations entirely
before `VmPeak` ticks up. The held doc still exists — it's just
under the runtime's already-resident page budget.

### `homogeneous-services-100.kdl` (6 KB, typed Vec<Service>)

Apples-to-apples typed decode — every parser holds a typed value of
the same logical shape.

| Parser    | Baseline | Peak     | Delta     |
|-----------|---------:|---------:|----------:|
| nimkdl    |  3.4 MB  |  3.4 MB  | **0 KB**  |
| knus      |  3.6 MB  |  4.0 MB  | 336 KB    |
| kdl-rs    |  3.3 MB  |  3.8 MB  | 528 KB    |
| facet-kdl |  4.3 MB  |  4.8 MB  | 572 KB    |
| ckdl      |  3.4 MB  |  5.2 MB  | 1,848 KB  |

ckdl's footprint here is high because the same parse-event drain
runs 200× on a small input — each parser instantiation is a fresh
allocation cycle that the same-process measurement folds into the
peak. The other parsers reuse allocator pages more aggressively
across iterations.

### Caveats

`VmPeak` includes runtime baseline + allocator fragmentation + held
doc + transient peaks during parse. It's an upper-bound "OOM risk"
number, not a pure "doc structural cost in bytes." For per-byte
structural cost, a heap profiler (Massif, dhat, custom allocator
hooks) would give cleaner numbers — but those don't compare uniformly
across language runtimes the way `VmPeak` does.

**ckdl asymmetry.** ckdl is SAX-style — there is no AST built, so
there is nothing structural to "hold" between iterations. ckdl's
delta therefore captures only transient parse-state high-water, not
held-doc cost. The other four parsers' deltas include both. This
asymmetry is real and reflects an actual API difference, not a
methodology bug: streaming parsers fundamentally have a smaller
memory footprint than AST builders for the same input.

**facet-kdl asymmetry.** facet-kdl exposes only a typed `from_str::<T>`
entry point — no untyped path. We measure it on the one fixture
with a defined typed shape (`homogeneous-services-100.kdl`) and
skip the others rather than route them through facet-kdl's
transitive kdl-rs dependency (which would just duplicate kdl-rs's
numbers under a different label).

## Real-trace replay (kdl-org conformance corpus)

Throughput on the [kdl-org reference test corpus](https://github.com/kdl-org/kdl/tree/main/tests/test_cases) —
338 community-curated KDL files (~7 KB total) that every spec-compliant
parser is held against. We didn't pick these fixtures; the kdl-org
maintainers did.

Average file is ~21 bytes — most are single-line edge cases. Per-call
fixed overhead dominates over byte throughput, so the headline metric
is microseconds per parse call (lower is better).

| Parser    | μs / file | files / sec | accepted / 338 |
|-----------|----------:|------------:|---------------:|
| ckdl      | **0.42**  | 2,397K      | 240            |
| nimkdl    | 0.67      | 1,498K      | **243**        |
| kdl-rs    | 6.15      | 163K        | 242            |
| knus      | 11.59     | 86K         | 111            |

(facet-kdl skipped — typed-decode-only, no usable untyped path for
arbitrary-shape corpus.)

ckdl is fastest per-file (no AST construction); nimkdl follows at
1.6× ckdl's per-call time but with the highest spec coverage in the
table — 243 of 338 fixtures accepted, matching the kdl-org corpus's
own "should parse" count exactly. knus's 111-accepted gap (~130 spec-
valid files rejected) is a real correctness signal, not a perf
artifact: knus does not implement some KDL v2 features the conformance
suite exercises.

Source: `benchmarks/comparisons/last-corpus.txt` (regenerate with
`benchmarks/comparisons/run.sh corpus`).

## Edit-then-encode

The editor/formatter workflow: open file → mutate one node → save.
Both nimkdl and kdl-rs explicitly designed for this (byte-lossless
preservation of unmutated regions). Other parsers don't have a
mutable AST + encode path, so this is a 2-way comparison.

Full cycle per iteration (parse + mutate one prop on the first node +
encode) on `realistic-config.kdl`:

| Parser  | μs / cycle | cycles / sec | vs kdl-rs |
|---------|-----------:|-------------:|----------:|
| **nimkdl** (`parse(preserveFormat=true)` + `setProp` + `encode(emPreserve)`) | **98** | **10.2K** | **8.5× faster** |
| kdl-rs (`parse_v2` + `KdlNode::push` + `to_string`) | 860 | 1.2K | 1.0× |

The architectural difference: nimkdl carries a per-node `parseHash`,
so on encode the mutated subtree emits canonical text while every
unmutated subtree splices source bytes verbatim — the encode cost is
bounded by the size of the *change*, not the size of the document.
kdl-rs stores per-token whitespace on every node and walks all of it
on `to_string`, paying the full tree's emit cost whether or not
anything changed.

Source: `benchmarks/comparisons/run.sh edit`.

## Methodology

Cross-implementation benchmarks lie easily. The discipline that makes this comparison hold up to outside scrutiny.

**Same container.** Hardware and scheduler variance swamps most software differences. All parsers run in the same set of containers, back-to-back in the same session.

**Same input bytes, vendored.** "We both used Cargo.kdl" is not the same as "we used the same bytes." Verify byte-for-byte.

**Same iteration counts.** Different counts produce meaningless averages because you're measuring different total work.

**Same flag profile.** All at release+LTO equivalent. Nim is `-d:release -d:lto` with ORC. Rust is `--release` with `lto = true, codegen-units = 1`. C is `-O3 -DNDEBUG`. Mixing flag profiles across implementations is the most common dishonest comparison.

**glibc, not musl.** kdl-rs allocates heavily through the `num` BigInt crate and musl's `malloc` punishes that — same kdl-rs build on glibc Debian is 3.6x faster than on musl Alpine. We see only a 5% swing. Use glibc for cross-language Rust benchmarks unless musl is your actual production target.

**Idiomatic API per library.** ckdl is event-driven, so its harness drains events to /dev/null. knus does typed decode in one shot. kdl-rs builds an AST. Different libraries have different output shapes, and that asymmetry is real and worth acknowledging.

## What we don't measure

Error rendering (we have rustc-style diagnostics; kdl-rs has miette's colored carets which do more work per error) and mutation API throughput. Both asymmetric across libraries.

## How to reproduce

All four bench harnesses (nimkdl, ckdl, knus, kdl-rs) are vendored into this repo at `benchmarks/comparisons/`. One script runs them all back-to-back in matched containers.

```bash
benchmarks/comparisons/run.sh           # all five + memory matrix
benchmarks/comparisons/run.sh nimkdl    # one specific
benchmarks/comparisons/run.sh ckdl knus # multiple
benchmarks/comparisons/run.sh memory    # memory footprint matrix only
```

Requires `podman` (or set `CONTAINER_RUNTIME=docker`).

See [benchmarks/comparisons/README.md](benchmarks/comparisons/README.md) for per-harness details, fixture provenance, and notes on each library's idiomatic API. If you find an issue with how we're calling one of the other libraries, please open a PR.
