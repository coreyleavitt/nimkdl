# Benchmarks

On a 5.6KB realistic KDL config that exercises every language feature, nkdl parses about **1.54× faster than [ckdl](https://github.com/tjol/ckdl)** (a hand-written C parser), **~7× faster than [knus](https://crates.io/crates/knus)**, and **~16× faster than [kdl-rs](https://github.com/kdl-org/kdl-rs)**. On typed encode `encode[seq[Service]]` is **2.34× faster than [facet-kdl](https://crates.io/crates/facet-kdl)**'s `to_string` (56.1K vs 24.0K ops/s). On typed decode knus's serde-derive edges us (20.5K vs 16.8K ops/s — knus 1.22× faster). Of the 338 files in the kdl-org reference corpus we accept **243** — the highest of any parser tested (ckdl 240, kdl-rs 242, knus 111).

Same container, same input bytes, same iteration counts. Source: [`benchmarks/comparisons/last-run.txt`](benchmarks/comparisons/last-run.txt) (regenerate with `benchmarks/comparisons/run.sh`).

## What changed from earlier numbers

The repo went through a substantial architectural rewrite (three-categories layering — see [docs/rfc-three-categories-architecture.md](docs/rfc-three-categories-architecture.md)). The headline numbers shifted:

| Path | Old (pre-rewrite) | New (post-rewrite) | Delta |
|------|-------------------|---------------------|-------|
| Parse realistic-config vs ckdl | nkdl 1.58× | nkdl 1.54× | tightened slightly |
| Parse deep-chain-100 vs ckdl | nkdl 1.01× (tie) | **ckdl 1.46×** | nkdl regressed |
| Parse tree-d8-b3 vs ckdl | nkdl 1.21× | **ckdl 1.18×** | nkdl regressed |
| Typed decode vs knus | nkdl 1.07× | **knus 1.22×** | nkdl regressed |
| Typed encode vs facet-kdl | nkdl 4.87× | **nkdl 2.34×** | nkdl still leads but narrower |
| Memory (tree-d8-b3 delta) | 24.7 MB | 30.0 MB | +22% |
| Spec coverage (corpus accept) | 243/338 | **243/338** | unchanged |

What the rewrite bought is structural correctness and composability:

- **#11 closed by construction** (depth-2+ children corruption in typed-decode is gone — the new substrate can't express it)
- **`embed[T]` works at compile time** — `const cfg = embed[Service](...)` evaluates the entire parse in NimVM. Was broken pre-rewrite (visitor codegen used FFI in dispatch).
- **Three categories** — streaming events (Cat 1), typed-derive (Cat 2), untyped DOM (Cat 3) are independent. `decode[T]` skips the KdlDoc entirely; `parse()` skips typed decoding.
- **Full property-test catalog (P1–P12)** — caught two real bugs during the rebuild itself (`lexer.isBareword` accepting `.<digit>`, `emitDocPreserve` missing inter-node separator on appended dirty nodes).
- **Pure-Nim end-to-end** — substrate has no FFI in the codegen path.

Per-category cost of the architectural split, vs the old monolithic lex-and-visit-in-one-tight-loop:

- Cat 3 parse picks up ~10-30 μs of event-emission overhead the old code didn't have (cursor materializes `CursorEvent` values; the old visitor protocol called visitor callbacks directly inside the lex loop)
- Cat 2 typed-decode pays the same event-layer cost plus per-T derive-emitted dispatch overhead
- Cat 1 streaming consumers are new — no old equivalent

PGO (build-time `-fprofile-generate` → train → `-fprofile-use`) recovers ~25-35% on the parse + decode regressions in our local testing, but it's a deployment-time decision and not benched here against the other parsers' default builds. The numbers in this doc are default-build apples-to-apples.

## The fixture

`benchmarks/fixtures/realistic-config.kdl` is a 5,629-byte service-deployment config. It uses every KDL v2 keyword (`#true`, `#false`, `#null`, `#inf`, `#-inf`, `#nan`), type annotations on both args and props, multi-line strings, raw strings, all four number bases, line comments, block comments, slashdash, repeated property keys with last-write-wins, and multi-script identifiers in node names. About 7 top-level nodes with 120-ish inner nodes. This is the closest single file we have to "what configs people actually write."

The other kdl-org samples (`Cargo.kdl`, `ci.kdl`, `website.kdl`) are real KDL but barely use the language. Cargo.kdl is 13 lines of strings with no annotations, no keywords, no comments. They stay in the bench as comparison points but the headline number comes from the realistic fixture.

`deep-chain-100.kdl` and `tree-d8-b3.kdl` are synthetic stressors. The former is 100 levels of nested-children depth in a 2.7KB file (worst-case recursion). The latter is a 795KB workspace-monorepo shape with ~9,800 nodes. They're regression guards for specific architectural failure modes — not "realistic" workloads.

## Per-fixture parse comparison

| Fixture                       | nkdl μs | ckdl μs | knus μs | kdl-rs μs | Winner            |
|-------------------------------|--------:|--------:|--------:|----------:|-------------------|
| realistic-config.kdl (5.6KB)  |    61.7 |    94.8 |   421.2 |     998.2 | **nkdl 1.54×**    |
| Cargo.kdl (238B)              |     4.3 |     5.5 |    74.9 |      51.2 | **nkdl 1.28×**    |
| ci.kdl (1.2KB)                |    15.7 |    24.4 |   371.2 |     224.9 | **nkdl 1.55×**    |
| website.kdl (2KB)             |    21.6 |    35.0 |   423.5 |     324.7 | **nkdl 1.62×**    |
| flat-deps-100.kdl (4KB)       |   102.2 |   100.9 |  1483.7 |     942.6 | tie               |
| unicode-heavy.kdl (1.2KB)     |    22.7 |    21.8 |   352.9 |     222.2 | tie               |
| homogeneous-services-100      |   130.4 |   131.9 |     n/a |    1206.2 | tie               |
| deep-chain-100.kdl (2.7KB)    |    86.2 |    59.1 |  1778.4 |     931.7 | **ckdl 1.46×**    |
| tree-d8-b3.kdl (795KB)        |   16131 |   13678 |  277001 |    142269 | **ckdl 1.18×**    |

facet-kdl is absent from the parse rows because it wraps kdl-rs's parser — its parse number is kdl-rs's.

nkdl leads on the realistic + small fixtures, ties in the mid-range, and loses to ckdl on the deep + large synthetic stressors. The crossover is real and worth understanding: ckdl is SAX-style with a tight per-byte state machine and no AST construction (the bench drains events to nothing). On small inputs ckdl pays full per-event dispatch + callback indirection; nkdl's recursive-descent direct-into-AST wins. On large inputs nkdl pays full AST construction whose absolute cost grows with node count; ckdl pays only its tight state machine.

Honest caveat. This is **apples-to-apples-ish**. Each library is called with its idiomatic "give me my default parse output" API. The output shapes differ:

- ckdl drains SAX events with no AST construction (theoretical floor)
- knus `parse_ast` builds a `Document` with spans
- kdl-rs `KdlDocument::parse_v2` builds the full AST with per-token whitespace storage
- nkdl `parse()` builds a `KdlDoc` with per-node span (no per-token trivia by default)

Apples-to-apples on **input cost and flag profile**, but doing different amounts of representation work.

## Typed decode

A homogeneous fixture of 100 service nodes (~5KB, `benchmarks/fixtures/homogeneous-services-100.kdl`). The headline bench measures parse-to-AST. Most consumers actually want parse-then-decode-into-typed-structures in one shot.

| Parser           | Path                                | ops/s     | vs knus            |
|------------------|-------------------------------------|----------:|-------------------:|
| **knus**         | `parse::<Vec<Service>>` (serde-derive) | **20,500** | 1.00×              |
| nkdl             | `decode[seq[Service]]`              |    16,800 | **0.82× — knus 1.22× faster** |
| kdl-rs           | (no typed decode path)              |     1,000 | 20× slower         |
| facet-kdl        | `from_str::<ServiceDoc>`            |       700 | 29× slower         |

The Service schema (name arg + 3 typed props) is identical across all three derive-based harnesses — verify by reading `nkdl/bench.nim`, `facet-kdl/main.rs`, and `knus/main.rs` side by side.

knus pulled ahead in this round. Why: knus does typed decode via one tight serde pass where the AST construction and the typed pull happen in the same loop iteration; nkdl's three-categories architecture separates lex → cursor-events → derive-emitted typed dispatch, paying a small per-event materialization cost the monolithic visitor protocol used to skip. PGO closes most of this gap; without PGO knus wins.

facet-kdl is 29× slower despite being advertised as knus's successor. Structural reason: facet-kdl depends on `kdl ^6.5.0` (kdl-rs), so its typed-decode perf is bounded by kdl-rs's parser plus the facet deserialize layer. The "successor" framing is about the typed-decode interface improvements (a more general derive system), not the parser.

## Typed encode

Two shapes. Flat: 100 identically-shaped `service` nodes. Nested: 25 Server × 4 Action children = 100 inner nodes (same total work, exercises indent + recursion).

Flat shape (`benchmarks/fixtures/homogeneous-services-100.kdl`):

| Path                                          | ops/s    | vs facet-kdl |
|-----------------------------------------------|---------:|-------------:|
| **nkdl `encode(seq[Service])`**               | **56,100** | **2.34× faster** |
| facet-kdl `to_string(&doc)`                   |  24,000  | 1.00×        |
| knus                                          | n/a — no encode path | — |
| kdl-rs                                        | n/a — no typed encode path | — |
| ckdl                                          | n/a — streaming emitter only | — |

Nested shape:

| Path                                          | ops/s    |
|-----------------------------------------------|---------:|
| **nkdl `encode(seq[Server])`**                | **111,200** |

facet-kdl's harness times flat-only — no nested-shape encode is comparable.

The nested ops/s is higher than flat because the output is denser per byte (2.6KB vs 5.2KB) — per-call fixed cost amortizes over more inner nodes inside the same byte budget. It's not a separate "encoding is faster on nested shapes" claim; it's a per-byte normalization quirk.

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

nkdl's delta went up from 24.7 MB pre-rewrite to 30.0 MB — about 22% more. The increase tracks the `MutationState` ref sidecar field on `KdlNode` (allocated lazily but pointer-tracked per node), the slightly larger `CursorEvent` machinery, and the pre-sized seq overheads. Still inside the "won't OOM your container" envelope.

### `realistic-config.kdl` (6 KB, mixed top-level nodes)

| Parser    | Baseline | Peak     | Delta     |
|-----------|---------:|---------:|----------:|
| nkdl      |  3.5 MB  |  3.5 MB  | **0 KB**  |
| ckdl      |  3.4 MB  |  3.7 MB  | 260 KB    |
| knus      |  3.6 MB  |  4.0 MB  | 340 KB    |
| kdl-rs    |  3.3 MB  |  3.8 MB  | 528 KB    |

The 0 KB nkdl number is real but a measurement artifact: Nim's preallocated heap absorbs the post-baseline allocations entirely before `VmPeak` ticks up. The held doc still exists — it's just under the runtime's already-resident page budget.

### `homogeneous-services-100.kdl` (6 KB, typed Vec<Service>)

| Parser    | Baseline | Peak     | Delta     |
|-----------|---------:|---------:|----------:|
| nkdl      |  3.5 MB  |  3.5 MB  | **0 KB**  |
| knus      |  3.6 MB  |  4.0 MB  | 336 KB    |
| kdl-rs    |  3.3 MB  |  3.8 MB  | 528 KB    |
| facet-kdl |  4.3 MB  |  4.8 MB  | 572 KB    |
| ckdl      |  3.4 MB  |  5.2 MB  | 1,848 KB  |

ckdl's footprint here is high because the same parse-event drain runs 200× on a small input — each parser instantiation is a fresh allocation cycle that the same-process measurement folds into the peak. The other parsers reuse allocator pages more aggressively across iterations.

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

ckdl is fastest per-file (no AST construction); nkdl follows at 2.43× ckdl's per-call time (up from 1.6× pre-rewrite — same regression pattern as the parse table) but with the highest spec coverage in the table. 243 of 338 fixtures accepted matches the kdl-org corpus's own "should parse" count exactly. knus's 111-accepted gap (~130 spec-valid files rejected) is a real correctness signal, not a perf artifact: knus does not implement some KDL v2 features the conformance suite exercises.

Source: `benchmarks/comparisons/last-corpus.txt` (regenerate with `benchmarks/comparisons/run.sh corpus`).

## Why ckdl is fast (and how the comparison shifted)

ckdl is a SAX-style parser. It emits events (start-node, argument, property, end-node, etc.) as it walks the input, never constructing an AST. The bench harness drains events into nothing. This is the absolute floor for "parse cost in C" because nothing is allocated downstream.

We do build an AST. Every node, every entry, every value gets stored in a `KdlDoc`. We're slower than the theoretical C floor would be... except on realistic + small inputs, we're not.

The pre-rewrite parser did recursive descent directly into the AST. Each node allocated once and moved up the call stack via sink semantics. No per-event dispatch, no callback indirection.

The post-rewrite parser still goes input → AST, but goes through a token cursor that emits `CursorEvent` values, then `buildDoc` folds those events into the AST. That intermediate event-emission layer is what makes Cat 1 (streaming) and Cat 2 (typed-derive) possible without traversing the AST. On small inputs the per-event overhead is small; on deep + large synthetic stressors it accumulates and ckdl pulls ahead.

So the comparison is now: nkdl's AST-building parser beats ckdl's event-stream parser when the workload is what real configs look like, and loses to ckdl when the workload is depth-stressing. Both interpretations are honest — the "AST-builder beats SAX-streamer on realistic inputs" claim still holds; the "across-the-board" claim doesn't.

## Edit-then-encode

The editor/formatter workflow: open file → mutate one node → save. Both nkdl and kdl-rs explicitly designed for this (byte-lossless preservation of unmutated regions). Other parsers don't have a mutable AST + encode path, so this is a 2-way comparison.

> **Section pending refresh.** The edit-cycle harness binary failed to rebuild in the last bench run. Regenerate with `benchmarks/comparisons/run.sh edit` after fixing the harness wiring. Pre-rewrite numbers: nkdl 98 μs/cycle, kdl-rs 860 μs/cycle (8.5× faster). The preserve-mode emitter changed (added `ensureNodeSeparator` invariant for append-after-unterminated case caught by P6); behavioral expectation: similar or slightly better.

The architectural claim that drives the result still holds: nkdl carries a per-node `parseHash`, so on encode the mutated subtree emits canonical text while every unmutated subtree splices source bytes verbatim — the encode cost is bounded by the size of the *change*, not the size of the document. kdl-rs stores per-token whitespace on every node and walks all of it on `to_string`, paying the full tree's emit cost whether or not anything changed.

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

- Error rendering quality (we have rustc-style diagnostics; kdl-rs has miette's colored carets — both work, both asymmetric)
- Mutation API throughput (asymmetric across libraries)
- Startup time (irrelevant for any non-trivial workload)
- Cold-cache vs warm-cache parse cost

## How to reproduce

All four bench harnesses (nkdl, ckdl, knus, kdl-rs, facet-kdl) are vendored into this repo at `benchmarks/comparisons/`. One script runs them all back-to-back in matched containers.

```bash
benchmarks/comparisons/run.sh           # all five + memory matrix + corpus + edit
benchmarks/comparisons/run.sh nkdl      # one specific
benchmarks/comparisons/run.sh ckdl knus # multiple
benchmarks/comparisons/run.sh memory    # memory footprint matrix only
benchmarks/comparisons/run.sh corpus    # 338-fixture conformance replay
```

Requires `podman` (or set `CONTAINER_RUNTIME=docker`). On hosts where Docker's bridge networking is flaky (Windows + WSL2 is the common case), the script passes `--network host` to the container runtime so apt-get / cargo / cmake can reach package mirrors.

See [benchmarks/comparisons/README.md](benchmarks/comparisons/README.md) for per-harness details, fixture provenance, and notes on each library's idiomatic API. If you find an issue with how we're calling one of the other libraries, please open a PR.
