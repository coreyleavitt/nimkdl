# Benchmarks

> **TL;DR** — On a 5.6KB realistic KDL config exercising every language
> feature, `nimkdl` is **~16× faster than `kdl-rs`** and **~15× faster
> than `greenm01/nimkdl`** at standard release+LTO. Same container,
> same input bytes, same iteration counts.

## Headline: `realistic-config.kdl`

A dense KDL v2 config that uses every language feature in realistic
proportions: all 6 keywords (`#true`/`#false`/`#null`/`#inf`/`#-inf`/`#nan`),
type annotations on args + props, multi-line + raw strings, all number
bases (decimal/hex/octal/binary), line + block + slashdash comments,
repeated property keys, multi-script identifiers. 5,629 bytes,
~7 top-level nodes with ~120 inner nodes. This is the closest single
file we have to "what configs people actually write."

```
                        parses/second   μs/parse   relative
nimkdl  ████████████████████████████████  19,300       52     1.00×
kdl-rs  ██                                 1,186      843     16.3× slower
greenm  ██                                 1,250      800     15.4× slower
```

All three run in the same Alpine glibc container, all at release+LTO
equivalent (Nim `-d:release` + ORC; Rust `--release` + `lto = true,
codegen-units = 1`). Iteration counts identical (5,000). Bench source
in `benchmarks/bench.nim` (ours) and `/tmp/kdlrs-bench/src/main.rs`
(kdl-rs harness).

## Methodology

Cross-implementation benchmarks lie easily. The discipline that makes
this comparison defensible:

| Discipline | Why |
|---|---|
| Same container | Hardware/scheduler variance dwarfs most software differences |
| Same input bytes (vendored) | "We both used Cargo.kdl" — verify byte-for-byte |
| Same iteration counts | Different counts produce meaningless averages |
| Same flag profile | All at release+LTO. Mixing flag profiles is the most common dishonest comparison |
| **glibc, not musl** | musl's allocator hammered kdl-rs's BigInt crate ~4× extra — see "musl trap" below |
| Real workloads, not micro-fixtures | 24-byte conformance fixtures measure per-parse overhead, not parser throughput |

### The musl trap

Earlier rounds of this comparison ran in `nimlang/nim:2.2.0-alpine`
(musl). Result: kdl-rs at ~5.6K ops/s on `Cargo.kdl`. The same kdl-rs
build on glibc Debian: **20.3K ops/s** — a 3.6× swing from allocator
alone. kdl-rs allocates heavily through the `num` BigInt crate; musl's
slow `malloc` punishes this. We (no BigInt in the hot path) saw only
a ~5% swing.

**Always use glibc for cross-language Rust comparisons unless musl
is specifically the production target.**

### What we don't measure

- **Encode performance** — only parse is benchmarked
- **Error rendering** — we have rustc-style diagnostics; kdl-rs has
  miette's colored carets which do more work per error
- **Mutation API** — kdl-rs's per-token whitespace storage is heavier;
  our per-node `parseHash` is lighter. The asymmetry shows up in
  edit + encode patterns we don't currently measure.
- **Decode** — `parse(src)` then `deriveDecode[T]` (the actual
  consumer pattern). The headline numbers are parse-only.

## Three sections, three honest averages

`benchmarks/bench.nim` reports three sections separately so the
average reflects what it's actually measuring:

### Real-world (headline: ~101 MB/s avg)

```
benchmark                       size    iters     avg time    throughput
realistic-config.kdl            5KB     5000      52μs       19.3K ops/s
Cargo.kdl                       238B    10000     3.7μs      270K   ops/s
ci.kdl                          1KB     5000      13.6μs     73.7K  ops/s
website.kdl                     2KB     5000      18.6μs     53.9K  ops/s
```

`realistic-config.kdl` is THE representative fixture — it actually
exercises the language. The kdl-org samples (Cargo / ci / website)
are real KDL but barely use it: Cargo.kdl is 13 lines of strings,
no annotations, no keywords, no comments.

### Large workloads (~79 MB/s avg)

```
flat-deps (~100 nodes)          4KB     2000      44μs       22.8K  ops/s
tree d=8 b=3 (~9.8k nodes)      794KB   200       10ms       99.9   ops/s
```

The tree shape mirrors a monorepo workspace config or a Kubernetes
manifest with nested resources. ~9.8k AST nodes in 794KB.

### Regression guards (~52 MB/s — NOT representative)

```
deep-chain (100)                2KB     1000      58μs       17.3K  ops/s
unicode-heavy.kdl               1KB     2000      18μs       55.3K  ops/s
```

These are **pathological** shapes. Each corresponds to a real bug
we've fixed and exists to catch regression:

- **deep-chain (100)**: 100-level linear nesting. Guards against the
  O(N²) `Result.get` deep-copy fixed in `660fe7a`. Real configs
  don't go this deep; it's a torture test for the parse recursion path.
- **unicode-heavy**: multi-script identifiers with combining marks +
  emoji ZWJ. Guards the `lexBareIdent` Unicode codepoint path.
  `greenm01/nimkdl` outright fails this fixture (rejects valid v2
  multi-script idents despite claiming "100% v2 compliance").

## Per-fixture comparison

```
realistic-config.kdl (5.6KB, dense language use):
  nimkdl   ████████████████████████████████  19,300 ops/s
  kdl-rs   ██                                 1,186 ops/s   (16.3× slower)
  greenm   ██                                 1,250 ops/s   (15.4× slower)

Cargo.kdl (238B, strings-only):
  nimkdl   ████████████████████████████████  269,700 ops/s
  kdl-rs   ███                                23,700 ops/s   (11.4× slower)
  greenm   ███                                22,300 ops/s   (12.1× slower)

ci.kdl (1KB, mixed):
  nimkdl   ████████████████████████████████   73,700 ops/s
  kdl-rs   ██                                  4,950 ops/s   (14.9× slower)
  greenm   ██                                  3,750 ops/s   (19.7× slower)

website.kdl (2KB, HTML-ish):
  nimkdl   ████████████████████████████████   53,900 ops/s
  kdl-rs   ██                                  3,500 ops/s   (15.4× slower)
  greenm   ██                                  3,200 ops/s   (16.8× slower)

unicode-heavy.kdl (1KB, multi-script):
  nimkdl   ████████████████████████████████   55,300 ops/s
  kdl-rs   ███                                 5,580 ops/s   (9.9× slower)
  greenm   ░░░ FAIL — rejects valid v2 multi-script identifiers
```

## How we got here

These numbers aren't from clever individual optimizations — they're
from a single sustained perf hunt that eliminated several O(N²)
patterns and one large opt-in win. Each step was driven by `perf
record` + Nim's `=copy` probe (see `nimble perfGuard`):

```
Stage                                    real-world avg    speedup
─────────────────────────────────────────────────────────────────────
Starting point (post-token-compaction)         12.7 MB/s    1.0×
+ hash recursion fix (parser O(N·d) → O(N))    ~38  MB/s    3.0×
+ sink-Result + for-loop value-copy fix         49.4 MB/s    3.9×
+ opt-in parseHash (default skip)               70.7 MB/s    5.6×
+ numlit string allocs                          73.1 MB/s    5.8×
+ openArray-based intern                        83.5 MB/s    6.6×
+ reserved-bareword alloc avoidance             83.5 MB/s    6.6×
+ SWAR bare-ident scanner                      101.0 MB/s    8.0×

Final / headline                               101.0 MB/s    8.0× total
```

Each diff is in git history. The biggest single win (`hash recursion`,
~3.0× alone) was a one-line fix to use a stored value instead of
recomputing it. The biggest "everything else" win (`sink-Result`)
was caught by `perf record` showing 19% of CPU in
`eqcopy_(seq<KdlNode>)` recursing 10+ levels deep.

## Where the speed comes from

Honest decomposition of "why are we faster":

1. **Lighter data model.** Per-node 16-byte `parseHash` + span-range
   into source bytes vs `kdl-rs`'s per-token leading/trailing
   whitespace storage. Both achieve byte-lossless round-trip; ours
   is structurally lighter.

2. **Hand-written recursive descent.** `kdl-rs` uses `winnow`
   combinators which allocate per-attempt state. Hand-written
   recursive descent — once value-copies are eliminated — is hard
   to beat for raw throughput.

3. **`int64` fast-path for numbers.** kdl-rs always routes through
   `num::BigInt`. We lazy-promote to a 128-bit type only when an
   `int64` overflow happens.

4. **`seq[KdlEntry]` for properties.** kdl-rs uses `IndexMap` (heap
   allocation per node). For the 2-3 properties on a typical node,
   linear scan beats a hash map — cache-friendly, no allocation.

5. **`embed[T]` discipline.** The compile-time-eval requirement
   forced `{.noSideEffect.}` everywhere, which forced `Result[T, E]`
   instead of exceptions, which forced span-tokens + payload
   side-tables + interning. None of this was *for* perf — perf came
   as a side effect of the compile-time-eval constraint.

6. **Opt-in `parseHash`.** ~95% of consumers (typed decode,
   validate-and-discard, codegen) don't preserve format. They skip
   the FNV-128 work by default — ~18% on its own.

## How to reproduce

```bash
# nimkdl (this repo)
podman run --rm -v "$PWD:/work:Z" -w /work docker.io/nimlang/nim:2.2.0 \
  nim c -r -d:release -p:src benchmarks/bench.nim

# kdl-rs comparison (vendor the fixtures first)
cargo new --bin kdlrs-bench && cd kdlrs-bench
# Cargo.toml: kdl = "6", [profile.release] lto = true, codegen-units = 1
# main.rs: bench harness — see /tmp/kdlrs-bench/src/main.rs in milpa repo
cargo run --release

# greenm01/nimkdl comparison
git clone https://github.com/greenm01/nimkdl /tmp/greenm-nimkdl
# Adapt benchmarks/bench.nim's loops to use their parseKdl()
```

All three should run **back-to-back in the same container/session**
to eliminate host variance.

## Regression protection

`nimble perfGuard` compiles the perf-critical path with
`-d:probeKdlNodeCopy`. The `=copy` hook on `KdlNode` is bound to
`{.error.}` under that flag, so any introduced copy site fails the
build with a clear pointer:

```
Error: '=copy' is not available for type <KdlNode>;
       requires a copy because it's not the last read of '...'
```

Catches `for i, c in seq[KdlNode]` (binds c by value), non-sink
`Result.get`, value-binding mid-function — all the patterns that
caused the 14× regression we fixed. Wired into `.github/workflows/ci.yaml`
to run on every PR.
