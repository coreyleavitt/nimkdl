# Benchmarks

On a 5.6KB realistic KDL config that exercises every language feature, nimkdl parses about 1.4x faster than ckdl (a well-engineered C library), 8-9x faster than knus, and ~18x faster than kdl-rs. Same container, same input bytes, same iteration counts.

![Headline comparison](docs/charts/headline.svg)

ckdl is the real competition here. It's a hand-written C parser with a SAX-style event API, no AST construction overhead in the bench harness. We're beating it by 25-40% on most fixtures and trading blows with it on the smallest ones. Everything else trails by an order of magnitude or more.

## The fixture

`benchmarks/fixtures/realistic-config.kdl` is a 5,629-byte service-deployment config. It uses every KDL v2 keyword (`#true`, `#false`, `#null`, `#inf`, `#-inf`, `#nan`), type annotations on both args and props, multi-line strings, raw strings, all four number bases, line comments, block comments, slashdash, repeated property keys with last-write-wins, and multi-script identifiers in node names. About 7 top-level nodes with 120-ish inner nodes. This is the closest single file we have to "what configs people actually write."

The other kdl-org samples (`Cargo.kdl`, `ci.kdl`, `website.kdl`) are real KDL but barely use the language. Cargo.kdl is 13 lines of strings with no annotations, no keywords, no comments. They stay in the bench as comparison points but the headline number comes from the realistic fixture.

## Per-fixture comparison

![Per-fixture comparison](docs/charts/per-fixture.svg)

Every fixture, every parser, same container, same iteration counts. Bars show throughput as a percentage of nimkdl (which is always 100%).

ckdl is consistently the closest competitor. On `unicode-heavy.kdl` it actually edges us by 4%, effectively a dead heat. The fact that we're matching a hand-written C parser is the result worth pointing at.

knus and kdl-rs are both 10-20x behind ckdl and nimkdl across the board. Both prioritize features we deferred (knus is serde-style typed decode in one shot; kdl-rs carries per-token whitespace storage and BigInt-by-default), so this isn't a clean comparison of "parser quality." It's a comparison of "how fast does parse-to-AST run in this library, with the defaults that ship."

## Typed decode

The headline bench measures parse-to-AST. Most consumers actually want parse-then-decode-into-typed-structures in one shot. This is what `nimkdl decode[T]`, `knus parse::<Vec<T>>`, and `serde_json::from_str::<T>` all promise.

A small fixture of 100 homogeneous service nodes (~3.8KB).

| Parser           | Path                                | ops/s   | vs nimkdl |
|------------------|-------------------------------------|--------:|----------:|
| **nimkdl**       | `decode[seq[Service]]`              | 12,800  | 1.0x      |
| knus             | `parse::<Vec<GenericNode>>` (catch-all) | 2,600 | 4.9x slower |
| knus             | `parse::<Vec<Service>>` (typed)     | 720     | 17.9x slower |

Surprising finding. knus typed decode is **slower than knus generic decode**. That inverts the serde-style pitch. serde-json's typed path is faster than `Value` because the schema lets the parser skip intermediate allocations. knus appears to parse to an internal representation first and then validate against the schema, which adds work instead of removing it.

nimkdl's typed decode is faster than its own untyped parse for the same reason serde-json's typed path is fast. Knowing the schema at compile time means `deriveDecode` generates a decoder that writes directly into the target fields. No `KdlDoc` allocation, no entry/property indirection. The compile-time-eval discipline gets to amortize across the typed code path too.

## Why ckdl is fast (and why we still beat it)

ckdl is a SAX-style parser. It emits events (start-node, argument, property, end-node, etc.) as it walks the input, never constructing an AST. The bench harness drains events into nothing. This is the absolute floor for "parse cost in C" because nothing is allocated downstream.

We do build an AST. Every node, every entry, every value gets stored in a `KdlDoc`. We're slower than the theoretical C floor would be... except we're not, we're faster.

The reason is roughly. ckdl uses a state machine inside `kdl_parser_next_event` that dispatches per byte and emits events through a function-pointer callback. Each event is one allocation (the `kdl_event_data` struct). Plus the parser's internal small-buffer for the current token. That cumulative per-event overhead, integrated over thousands of events per parse, adds up.

Our parser does recursive descent directly into the AST. Once the value-copy bugs were eliminated (see the blog post about the perf hunt), each node allocates exactly once and gets moved up the call stack via sink semantics. No per-event dispatch overhead, no callback indirection, no malloc churn.

So the comparison isn't "Nim parser beats C parser at C parser's game." It's "AST-building Nim parser is faster than event-stream C parser if you eliminate the allocation overhead." That happens to be the apples-to-apples comparison for "how fast does my program get a usable tree out of a KDL file."

## Methodology

Cross-implementation benchmarks lie easily. The discipline that makes this comparison hold up to outside scrutiny.

Same container. Hardware and scheduler variance swamps most software differences. All four parsers run in the same set of containers, back-to-back in the same session.

Same input bytes, vendored. "We both used Cargo.kdl" is not the same as "we used the same bytes." Verify byte-for-byte.

Same iteration counts. Different counts produce meaningless averages because you're measuring different total work.

Same flag profile. All at release+LTO equivalent. Nim is `-d:release` with ORC. Rust is `--release` with `lto = true, codegen-units = 1`. C is `-O3 -DNDEBUG`. Mixing flag profiles across implementations is the most common dishonest comparison.

glibc, not musl. Earlier rounds ran in `nimlang/nim:2.2.0-alpine`. Result was kdl-rs at 5.6K ops/s on Cargo.kdl. Same kdl-rs build on glibc Debian gave 20.3K ops/s, a 3.6x swing from allocator alone. kdl-rs allocates heavily through the `num` BigInt crate and musl's slow `malloc` punishes that. We saw only a 5% swing. Always use glibc for cross-language Rust benchmarks unless musl is your actual production target.

Real workloads, not micro-fixtures. The previous bench inherited 24-byte conformance fixtures that produce inflated K-ops/s headlines measuring per-parse fixed overhead, not parser throughput. Dropped.

Apples to apples within reason. ckdl is event-driven, so its bench harness drains events to /dev/null. knus does typed decode in one shot, so it gets a generic catch-all type. kdl-rs builds an AST. Ours builds an AST. The closest comparable measurement across all four is "how long does it take to consume the input bytes into whatever each library's idiomatic output is." Different libraries have different output shapes, and that asymmetry is real and worth acknowledging.

## What we don't measure

Encode performance. The bench only times parse-or-decode.

Error rendering. We have rustc-style diagnostics. kdl-rs has miette's colored carets which do more work per error.

Mutation API. kdl-rs's per-token whitespace storage is heavier; our per-node `parseHash` is lighter. The asymmetry shows up in edit-then-encode patterns we don't currently measure.

Memory footprint. Same situation, asymmetric across libraries.

## Three sections in the bench output

`benchmarks/bench.nim` reports three sections separately so the average reflects what it's measuring.

### Real-world (about 104 MB/s average)

```
benchmark                  size    iters     avg time    throughput
realistic-config.kdl       5KB     5000      47us        21.4K ops/s
Cargo.kdl                  238B    10000     3.5us       282K  ops/s
ci.kdl                     1KB     5000      14us        71.9K ops/s
website.kdl                2KB     5000      18us        55.5K ops/s
```

### Large workloads (about 81 MB/s average)

```
flat-deps (~100 nodes)     4KB     2000      44us        22.8K ops/s
tree d=8 b=3 (~9.8k nodes) 794KB   200       10ms        99.9  ops/s
```

The tree shape mirrors a monorepo workspace or a Kubernetes manifest with nested resources. 9,841 AST nodes in 794KB.

### Regression guards (about 52 MB/s, not representative)

```
deep-chain (100)           2KB     1000      58us        17.3K ops/s
unicode-heavy.kdl          1KB     2000      18us        55.3K ops/s
```

These are pathological shapes. Each corresponds to a real bug we've fixed and stays in the bench to catch regression. `deep-chain (100)` guards the O(N²) `Result.get` deep-copy fixed in commit `660fe7a`. `unicode-heavy` guards the `lexBareIdent` Unicode codepoint path.

## How to reproduce

```bash
# nimkdl (this repo)
podman run --rm -v "$PWD:/work:Z" -w /work docker.io/nimlang/nim:2.2.0 \
  nim c -r -d:release -p:src benchmarks/bench.nim

# ckdl comparison (clone, build, write bench.c)
git clone https://github.com/tjol/ckdl /tmp/ckdl-bench/ckdl
cd /tmp/ckdl-bench/ckdl && cmake -B build -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_KDL_SHARED_LIBRARY=OFF -DBUILD_KDLPP=OFF \
  -DBUILD_TESTS=OFF -DBUILD_EXAMPLES=OFF && cmake --build build
# bench.c uses kdl_create_string_parser + kdl_parser_next_event loop
gcc -O3 -DNDEBUG -I ckdl/include -o bench bench.c \
    ckdl/build/libkdl.a -lm

# kdl-rs comparison
cargo new --bin kdlrs-bench
# Cargo.toml: kdl = "6", [profile.release] lto = true, codegen-units = 1
# main.rs uses kdl::KdlDocument::parse_v2
cargo run --release

# knus comparison (needs Rust >= 1.85 for edition2024)
cargo new --bin knus-bench
# Cargo.toml: knus = "3", miette = "5"
# main.rs uses knus::parse::<Vec<GenericNode>>
cargo run --release
```

Run all four back-to-back in the same set of containers to eliminate host variance.

## Regression protection

`nimble perfGuard` compiles the perf-critical path with `-d:probeKdlNodeCopy`. The `=copy` hook on `KdlNode` is bound to `{.error.}` under that flag. Any new copy site fails the build with a clear pointer.

```
Error: '=copy' is not available for type <KdlNode>;
       requires a copy because it's not the last read of '...'
```

Catches `for i, c in seq[KdlNode]` (binds c by value), non-sink `Result.get`, and value-bindings mid-function. All the patterns that caused the 14x regression we fixed. Wired into `.github/workflows/ci.yaml` so it runs on every PR.
