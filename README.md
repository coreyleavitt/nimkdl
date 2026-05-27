# nkdl

A KDL v2 parser for Nim with compile-time-validated typed decode, byte-lossless format preservation, and dual-parser differential testing. On realistic configs nkdl parses about 1.58× faster than [ckdl](https://github.com/tjol/ckdl) (a hand-written C parser) and 9-20× faster than the Rust options ([knus](https://crates.io/crates/knus), [kdl-rs](https://github.com/kdl-org/kdl-rs)). On typed decode `parseInto[T]` edges knus's serde-derive (23.3K vs 21.8K ops/s). On typed encode `encodeFrom[T]` is **4.87× faster than [facet-kdl](https://crates.io/crates/facet-kdl)** (139.6K vs 28.7K). One grammar, 338/338 conformance fixtures. Per-fixture breakdown and methodology in [BENCHMARK.md](BENCHMARK.md).

## Install

```
nimble install nkdl
```

Requires Nim 2.0+.

## Usage

```nim
import nkdl

type Service {.kdlNode: "service".} = object
  name {.kdlArg.}: string
  replicas {.kdlProp.}: int = 1
  enabled {.kdlProp.}: bool = true

deriveDecode(Service)

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
| Decode | `decode[T](src) -> Result[T, ParseError]` | Typed decode via `deriveDecode[T]`. |
| Embed | `embed[T]("path")` | `staticRead` plus decode at compile time. Bad input fails the build. |
| Query | `path(items, [pred].chain)` | Compile-time field-checked filter and access. |
| Reference | `referenceInterpret(src)` | Table-driven independent parser used as differential-test oracle. |
| Multi-error | `parseAll(src) -> (doc, errors)` | Collects every error and returns a partial doc. |

All visible via `import nkdl`.

## Spec coverage

Full KDL v2. **338 / 338** of the [kdl-org/kdl test corpus](https://github.com/kdl-org/kdl/tree/main/tests/test_cases). Zero skipped cases. Byte-equivalence is **243 / 243** of positive corpus cases (every one satisfies `encode(parse(x, preserveFormat=true), emPreserve) == x`).

Reserved type annotations (spec §3) get parse-time validation for all 30-ish spec-defined tags: range checks for `i8` through `u128`, `f32`, `f64`; format validation for `uuid`, `ipv4`, `ipv6`, `date`, `time`, `date-time`, `duration`, `email`, `url`; ISO registry membership for `country-2`, `country-3`, `currency`; IEEE 754-2008 checks for `decimal`, `decimal64`, `decimal128`.

KSL (KDL Schema Language) and KQL (KDL Query Language) are intentionally not implemented. KSL targets v1 and has no working reference impl — we replace it with Nim-types-as-schema (`deriveDecode[T]` plus `{.kdlReserved.}`). KQL is marked unreleased in the spec — we replace it with the `path()` macro (compile-time field-checked).

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
- [Repo](https://github.com/coreyleavitt/nimkdl) — issues and source.
- [LICENSE](LICENSE) — Apache 2.0.
