# nkdl

[![CI](https://github.com/coreyleavitt/nkdl/actions/workflows/ci.yaml/badge.svg)](https://github.com/coreyleavitt/nkdl/actions/workflows/ci.yaml)
[![Docs](https://img.shields.io/badge/docs-coreyleavitt.github.io%2Fnkdl-blue)](https://coreyleavitt.github.io/nkdl/)
[![Conformance](https://img.shields.io/endpoint?url=https://coreyleavitt.github.io/nkdl/conformance-badge.json)](BENCHMARK.md)
[![License](https://img.shields.io/badge/license-Apache_2.0-blue)](LICENSE)

A KDL v2 parser for Nim with compile-time-validated typed decode, byte-lossless format preservation, and dual-parser differential testing. Three-categories architecture: streaming events (Cat 1), typed-derive `decode[T]` / `encode[T]` (Cat 2), and untyped DOM `parse()` / `emitDoc` (Cat 3) are independent — pay only for what you use.

On realistic configs nkdl parses about **1.54× faster than [ckdl](https://github.com/tjol/ckdl)** (a hand-written C parser), **~7× faster than [knus](https://crates.io/crates/knus)**, and **~16× faster than [kdl-rs](https://github.com/kdl-org/kdl-rs)**. On typed encode `encode[seq[Service]]` is **2.34× faster than [facet-kdl](https://crates.io/crates/facet-kdl)**'s `to_string` (56.1K vs 24.0K ops/s). On typed decode knus's serde-derive edges us 1.22× (20.5K vs 16.8K ops/s). Highest spec coverage of any parser tested: **243/338** kdl-org reference fixtures (vs ckdl 240, kdl-rs 242, knus 111). On deep + large synthetic stressors ckdl pulls ahead. Per-fixture breakdown, honest regression disclosure vs the pre-rewrite numbers, and methodology in [BENCHMARK.md](BENCHMARK.md).

## Install

```
nimble install nkdl
```

Requires Nim 2.0+.

## Usage

```nim
import nkdl

kdl:
  type Service {.kdlNode: "service".} = object
    name {.kdlArg.}: string
    replicas {.kdlProp.}: int = 1
    enabled {.kdlProp.}: bool = true

let r = decode[seq[Service]](readFile("services.kdl"))
if r.isErr:
  stderr.writeLine r.getErr.formatError(readFile("services.kdl"),
                                        filename = "services.kdl")
  quit 1

for service in r.get:
  if service.enabled:
    echo service.name, " x", service.replicas
```

The same file can also be embedded at compile time. A parse error then fails `nim c` instead of production:

```nim
const builtins = embed[seq[Service]]("services.kdl").get
```

`embed[T]` runs lex + parse + decode inside Nim's VM and emits a `const`. Zero module-init cost; malformed input fails the build.

## What's in the box

| Layer | Surface | Notes |
|---|---|---|
| Parse | `parse(src, preserveFormat = false) -> Result[KdlDoc, ParseError]` | KDL v2 text to AST. `preserveFormat` is opt-in for `emPreserve`. |
| Encode | `encode(doc, mode = emPreserve) -> string` | `emPreserve` is byte-lossless; `emPretty` and `emCompact` are canonical. |
| Decode | `decode[T](src) -> Result[T, ParseError]` | Typed decode for types in a `kdl:` block. |
| Embed | `embed[T]("path")` | `staticRead` plus decode at compile time. Bad input fails the build. |
| Query | `path(items, [pred].chain)` | Compile-time field-checked filter and access. |
| Reference | `referenceInterpret(src)` | Table-driven independent parser used as differential-test oracle. |
| Multi-error | `parseAll(src) -> (doc, errors)` | Collects every error and returns a partial doc. |

All visible via `import nkdl`.

## Spec coverage

Full KDL v2. **338 / 338** of the [kdl-org/kdl test corpus](https://github.com/kdl-org/kdl/tree/main/tests/test_cases). Zero skipped cases. Byte-equivalence is **243 / 243** of positive corpus cases (every one satisfies `encode(parse(x, preserveFormat=true), emPreserve) == x`).

Reserved type annotations (spec §3) get parse-time validation for all 30-ish spec-defined tags: range checks for `i8` through `u128`, `f32`, `f64`; format validation for `uuid`, `ipv4`, `ipv6`, `date`, `time`, `date-time`, `duration`, `email`, `url`; ISO registry membership for `country-2`, `country-3`, `currency`; IEEE 754-2008 checks for `decimal`, `decimal64`, `decimal128`.

KSL (KDL Schema Language) and KQL (KDL Query Language) are intentionally not implemented. KSL targets v1 and has no working reference impl — we replace it with Nim-types-as-schema (`kdl:` block plus `{.kdlReserved.}`). KQL is marked unreleased in the spec — we replace it with the `path()` macro (compile-time field-checked).

## Pragmas

Type-level: `{.kdlNode: "name".}`.
Field-level: `{.kdlArg.}`, `{.kdlProp.}`, `{.kdlChild.}`, `{.kdlSkip.}`, `{.kdlRename: "x".}`, `{.kdlReserved.}`.

Native Nim 2.x field defaults (`field: type = expr`) work as fallback values.

## vs the alternatives

- **[kdl-nim](https://github.com/Patitotective/kdl-nim)** (Patitotective) — a more featureful Nim KDL impl covering v1, v2, JiK, and XiK. Pick this if you need v1 compatibility or the JSON/XML-in-KDL transforms.
- **[nimkdl](https://github.com/greenm01/nimkdl)** (greenm01) — older Nim KDL effort. Different package, predates nkdl.
- **nkdl** (this library) — v2-only, focused on type-driven decode, compile-time embed, and edit-then-encode perf. Pick this if you want the perf numbers above, compile-time-validated configs, or `path()`-style typed queries.

## Safety limits

| Constant | Default | Module | Purpose |
|---|---|---|---|
| `MaxParserDepth` | 256 | `parser.nim` | Recursion cap on `{ children }` nesting |
| `InlineCapacity` | 22 | `intern.nim` | SBO inline-string capacity per Entry |
| `InterpRecursionCap` | 1024 | `grammar.nim` | Reference interpreter recursion cap |
| `KdlReprMaxDepth` | 32 | `ast.nim` | `$KdlDoc` cycle and pathological-depth guard |
| `MaxRawStringHashes` | 255 | `lexer.nim` | Cap on `#` count in raw-string fence |

## Development

```bash
nimble test
nimble perfGuard           # regression guard for KdlNode deep-copy
podman run --rm -v "$PWD:/work:Z" -w /work docker.io/nimlang/nim:2.2.0 nimble test
```

## Links

- [BENCHMARK.md](BENCHMARK.md) — full per-fixture comparison + methodology.
- [Repo](https://github.com/coreyleavitt/nkdl) — issues and source.
- [LICENSE](LICENSE) — Apache 2.0.
