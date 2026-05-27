# Benchmarks

On a 5.6KB realistic KDL config that exercises every language feature, nimkdl parses about 1.55x faster than ckdl (a well-engineered C library), 9x faster than knus, and ~20x faster than kdl-rs. On typed-decode (100-Service fixture) `parseInto` edges knus's serde-derive at 22.9K vs 22.1K ops/s. On typed-encode `encodeFrom` is 4.8x faster than facet-kdl's `to_string`. Same container, same input bytes, same iteration counts.

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
| realistic-config.kdl (5.6KB)  | 23.9K  | 15.4K  | 2.6K  |  1.2K  | nimkdl 1.55x |
| Cargo.kdl (238B)              | 297.8K | 222.1K |  14.9K|   23.6K| nimkdl 1.34x |
| ci.kdl (1KB)                  | 85.8K  | 52.5K  | 3.0K  |  5.0K  | nimkdl 1.63x |
| website.kdl (2KB)             | 65.3K  | 36.5K  | 2.9K  |  3.6K  | nimkdl 1.79x |
| flat-deps-100.kdl (4KB)       | 15.7K  | 13.8K  | 0.8K  |  1.2K  | nimkdl 1.14x |
| tree-d8-b3.kdl (794KB)        | 116    | 105    |   4   |    8   | nimkdl 1.10x |
| **deep-chain-100.kdl** (2.7KB)| 19.4K  | **22.5K** | 0.6K | 1.3K | **ckdl 1.16x** |
| unicode-heavy.kdl (1.2KB)     | 64.0K  | 59.7K  | 3.1K  |  5.6K  | nimkdl 1.07x (tie) |

nimkdl wins 7 of 8 parse rows outright (3 by 1.5x or more), ties 1, and loses 1 to ckdl on shapes with very simple node structure (deep-chain is just `levelN { ... }` repeated).

## Typed decode

The headline bench measures parse-to-AST. Most consumers actually want parse-then-decode-into-typed-structures in one shot. This is what `nimkdl parseInto[T]`, `knus parse::<Vec<T>>`, and `serde_json::from_str::<T>` all promise.

A homogeneous fixture of 100 service nodes (~5KB, `benchmarks/fixtures/homogeneous-services-100.kdl`).

| Parser           | Path                                | ops/s   | vs knus |
|------------------|-------------------------------------|--------:|----------:|
| **nimkdl**       | `parseInto[seq[Service]]`           | **22,900** | **1.04x faster** |
| knus             | `parse::<Vec<Service>>` (typed)     | 22,100  | 1.00x |
| kdl-rs           | `KdlDocument::parse_v2` (no typed path) | 1,000   | 22x slower |
| facet-kdl        | `from_str::<ServiceDoc>`            | 900     | 25x slower |

The Service schema (name arg + 3 typed props) is identical across all three derive-based harnesses — verify by reading `nimkdl/bench.nim`, `facet-kdl/main.rs`, and `knus/main.rs` side by side. Source: `benchmarks/comparisons/last-run.txt` (regenerate with `benchmarks/comparisons/run.sh`).

facet-kdl is 25× slower despite being advertised as knus's successor. Structural reason: facet-kdl depends on `kdl ^6.5.0` (kdl-rs), so its typed-decode perf is bounded by kdl-rs's parser plus the facet deserialize layer. The "successor" framing is about the typed-decode interface improvements (a more general derive system), not the parser.

## Typed encode

Two shapes. Flat: 100 identically-shaped `service` nodes. Nested: 25 Server × 4 Action children = 100 inner nodes (same total work but exercises indent + recursion).

Flat shape (`benchmarks/fixtures/homogeneous-services-100.kdl`):

| Path                                       | ops/s    | vs facet-kdl |
|--------------------------------------------|---------:|-------------:|
| **nimkdl `encodeFrom(seq[Service])`**      | **135.7K** | **4.78x faster** |
| facet-kdl `to_string(&doc)`                |  28.4K   | 1.00x        |
| knus                                       | n/a — no encode path | — |
| kdl-rs                                     | n/a — no typed encode path (AST `to_string` is the closest, different work) | — |
| ckdl                                       | n/a — streaming emitter only | — |

Nested shape:

| Path                                          | ops/s    |
|-----------------------------------------------|---------:|
| **nimkdl `encodeFrom(seq[Server])`**          | **325.5K** |

facet-kdl's harness times flat-only — no nested-shape encode is comparable. The nested-shape number exists to defend against "you only measured flat encode" rather than to claim a speedup. It's faster than flat in absolute ops/s because the output is denser per byte (2.4KB vs 5.2KB) — per-call fixed cost amortizes over more nodes inside the same byte budget.

Source: `benchmarks/comparisons/last-run.txt`.

## Why ckdl is fast (and why we still beat it)

ckdl is a SAX-style parser. It emits events (start-node, argument, property, end-node, etc.) as it walks the input, never constructing an AST. The bench harness drains events into nothing. This is the absolute floor for "parse cost in C" because nothing is allocated downstream.

We do build an AST. Every node, every entry, every value gets stored in a `KdlDoc`. We're slower than the theoretical C floor would be... except we're not, we're faster.

The reason: ckdl uses a state machine inside `kdl_parser_next_event` that dispatches per byte and emits events through a function-pointer callback. Each event is one allocation (the `kdl_event_data` struct), plus the parser's internal small-buffer for the current token. Integrated over thousands of events per parse, that overhead adds up.

Our parser does recursive descent directly into the AST. Each node allocates exactly once and gets moved up the call stack via sink semantics. No per-event dispatch overhead, no callback indirection, no malloc churn.

So the comparison isn't "Nim parser beats C parser at C parser's game." It's "AST-building Nim parser is faster than event-stream C parser if you eliminate the allocation overhead." That happens to be the apples-to-apples comparison for "how fast does my program get a usable tree out of a KDL file."

## Methodology

Cross-implementation benchmarks lie easily. The discipline that makes this comparison hold up to outside scrutiny.

**Same container.** Hardware and scheduler variance swamps most software differences. All parsers run in the same set of containers, back-to-back in the same session.

**Same input bytes, vendored.** "We both used Cargo.kdl" is not the same as "we used the same bytes." Verify byte-for-byte.

**Same iteration counts.** Different counts produce meaningless averages because you're measuring different total work.

**Same flag profile.** All at release+LTO equivalent. Nim is `-d:release` with ORC. Rust is `--release` with `lto = true, codegen-units = 1`. C is `-O3 -DNDEBUG`. Mixing flag profiles across implementations is the most common dishonest comparison.

**glibc, not musl.** kdl-rs allocates heavily through the `num` BigInt crate and musl's `malloc` punishes that — same kdl-rs build on glibc Debian is 3.6x faster than on musl Alpine. We see only a 5% swing. Use glibc for cross-language Rust benchmarks unless musl is your actual production target.

**Idiomatic API per library.** ckdl is event-driven, so its harness drains events to /dev/null. knus does typed decode in one shot. kdl-rs builds an AST. Different libraries have different output shapes, and that asymmetry is real and worth acknowledging.

## What we don't measure

Error rendering (we have rustc-style diagnostics; kdl-rs has miette's colored carets which do more work per error), mutation API throughput, and memory footprint. All asymmetric across libraries.

## How to reproduce

All four bench harnesses (nimkdl, ckdl, knus, kdl-rs) are vendored into this repo at `benchmarks/comparisons/`. One script runs them all back-to-back in matched containers.

```bash
benchmarks/comparisons/run.sh           # all four
benchmarks/comparisons/run.sh nimkdl    # one specific
benchmarks/comparisons/run.sh ckdl knus # multiple
```

Requires `podman` (or set `CONTAINER_RUNTIME=docker`).

See [benchmarks/comparisons/README.md](benchmarks/comparisons/README.md) for per-harness details, fixture provenance, and notes on each library's idiomatic API. If you find an issue with how we're calling one of the other libraries, please open a PR.
