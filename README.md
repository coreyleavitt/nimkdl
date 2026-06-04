# nkdl

[![CI](https://github.com/coreyleavitt/nkdl/actions/workflows/ci.yaml/badge.svg)](https://github.com/coreyleavitt/nkdl/actions/workflows/ci.yaml)
[![Docs](https://img.shields.io/badge/docs-coreyleavitt.github.io%2Fnkdl-blue)](https://coreyleavitt.github.io/nkdl/)
[![Conformance](https://img.shields.io/endpoint?url=https://coreyleavitt.github.io/nkdl/conformance-badge.json)](BENCHMARK.md)
[![License](https://img.shields.io/badge/license-Apache_2.0-blue)](LICENSE)

A KDL v2 parser for Nim with compile-time-validated typed decode, byte-lossless format preservation, and dual-parser differential testing. Three-categories architecture: streaming events (Cat 1), typed-derive `decode[T]` / `encode[T]` (Cat 2), and untyped DOM `parse()` / `encode()` (Cat 3) are independent — pay only for what you use.

On realistic configs nkdl parses about **1.54× faster than [ckdl](https://github.com/tjol/ckdl)** (a hand-written C parser), **~7× faster than [knus](https://crates.io/crates/knus)**, and **~16× faster than [kdl-rs](https://github.com/kdl-org/kdl-rs)**. On typed encode `encode[seq[Service]]` is **2.34× faster than [facet-kdl](https://crates.io/crates/facet-kdl)**'s `to_string` (56.1K vs 24.0K ops/s). On typed decode knus's serde-derive edges us 1.22× (20.5K vs 16.8K ops/s). Full spec conformance: **338/338** on the kdl-org reference corpus (243/243 should-parse + 95/95 should-reject). ckdl misses 3 should-parse files, kdl-rs misses 1, knus misses 132. On deep + large synthetic stressors ckdl pulls ahead. Per-fixture breakdown, honest regression disclosure vs the pre-rewrite numbers, and methodology in [BENCHMARK.md](BENCHMARK.md).

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
const builtins = embedFile[seq[Service]]("services.kdl")
```

`embedFile[T]` `staticRead`s the file and runs lex + parse + decode inside Nim's VM, emitting a `const`. Zero module-init cost; malformed input fails the build. (`embed[T](src)` is the same thing for an in-line KDL **string** rather than a path.)

## What's in the box

| Layer | Surface | Notes |
|---|---|---|
| Parse | `parse(src, preserveFormat = false) -> Result[KdlDoc, ParseError]` | KDL v2 text to AST. `preserveFormat` is opt-in for `emPreserve`. |
| Encode | `encode(doc) -> string` | Canonical by default. `encode(doc, preserve = true)` (or `encode(doc, emPreserve)`) is byte-lossless; `encode(doc, emPretty)` is indented. (`emCompact`, canonical minimal, is planned — [#26](https://github.com/coreyleavitt/nkdl/issues/26).) |
| Decode | `decode[T](src) -> Result[T, ParseError]` | Typed decode for types in a `kdl:` block. |
| Decode (file) | `decodeFile[T](path) -> Result[T, ParseError]` | Reads `path`, decodes it, attributes errors to the real filename. I/O failure → `peIOError`. |
| Bridge | `decodeNode[T](doc, node)` / `decodeChild[T]` / `coerce[T]` | Decode an individual DOM node, child, or scalar value into `T`. See [the consumer bridge](#typeddom-bridge). |
| Embed | `embed[T](src)` / `embedFile[T](path)` | Compile-time decode of KDL **content** (`embed`) or a **file** (`embedFile`, `staticRead` + decode). Bad input fails the build. |
| Query | `path(items, [pred].chain)` | Compile-time field-checked filter and access. |
| Reference | `referenceInterpret(src)` | Table-driven independent parser used as differential-test oracle. |
| Multi-error | `parseAll(src) -> (doc, errors)` | Collects every error and returns a partial doc. |

All visible via `import nkdl`.

## Typed↔DOM bridge

`decode[T]` decodes a whole source into one type. Real configs are
**heterogeneous**: differently-typed top-level nodes dispatched by name. The
bridge lets you walk the DOM and decode each node into its own type, while
keeping **true source line/col** on every error.

```nim
import nkdl

kdl:
  type Daemon {.kdlNode: "daemon".} = object
    listen {.kdlProp.}: int
  type Permissions {.kdlNode: "permissions".} = object
    user {.kdlArg.}: string

type Config = object
  daemon: Daemon
  perms: Permissions

let doc = parse(readFile("config.kdl"), "config.kdl").get
var cfg: Config
for n in doc.nodes:
  case n.name
  of "daemon":      cfg.daemon = decodeNode[Daemon](doc, n).get
  of "permissions": cfg.perms  = decodeNode[Permissions](doc, n).get
  else: discard
```

`decodeNode[T](doc, n)` slices the node's **original bytes** out of the doc and
feeds them to the one decoder — so all the Cat-2 pragmas work unchanged, and a
type error reports the real file position, not a synthetic offset:

```nim
let r = decodeNode[Daemon](doc, n)
if r.isErr:
  echo r.getErr        # config.kdl:14:5: value type mismatch (listen)
```

`ParseError` is self-sufficient: `$err` renders `path:line:col: message
(field.path)` with **no source argument** — the location is filled eagerly at
the decode boundary, so the error outlives the source string.

| Entry point | Purpose |
|---|---|
| `decodeNode[T](doc, node) -> Result[T, ParseError]` | Decode a parsed node from its verbatim source bytes (true line/col on errors). |
| `decodeNode[T](node) -> Result[T, ParseError]` | Doc-less overload for **hand-built** nodes (re-emits then decodes; lossier — see `derive-reference.md`). |
| `decodeChild[T](doc, parent, childName) -> Result[T, ParseError]` | Decode `parent`'s first child named `childName`. |
| `decodeOr[T](doc, node, fallback) -> T` | Decode, or return `fallback` on any error — never raises. |
| `coerce[T](val: KdlValue) -> Result[T, ParseError]` | Coerce a single scalar `KdlValue` into `T` (the value leg of the bridge). |

## Spec coverage

Full KDL v2. **338 / 338** of the [kdl-org/kdl test corpus](https://github.com/kdl-org/kdl/tree/main/tests/test_cases). Zero skipped cases. Byte-equivalence is **243 / 243** of positive corpus cases (every one satisfies `encode(parse(x, preserveFormat=true), emPreserve) == x`).

Reserved type annotations (spec §3) get parse-time validation for all 30-ish spec-defined tags: range checks for `i8` through `u128`, `f32`, `f64`; format validation for `uuid`, `ipv4`, `ipv6`, `date`, `time`, `date-time`, `duration`, `email`, `url`; ISO registry membership for `country-2`, `country-3`, `currency`; IEEE 754-2008 checks for `decimal`, `decimal64`, `decimal128`.

KSL (KDL Schema Language) and KQL (KDL Query Language) are intentionally not implemented. KSL targets v1 and has no working reference impl — we replace it with Nim-types-as-schema (`kdl:` block plus `{.kdlReserved.}`). KQL is marked unreleased in the spec — we replace it with the `path()` macro (compile-time field-checked).

## Pragmas

Full reference with examples: [docs/derive-reference.md](docs/derive-reference.md).

Type-level: `{.kdlNode: "name".}`, `{.kdlRenameAll: kc….}`, `{.kdlIgnoreUnknown.}`, `{.kdlEncodeOnly.}` / `{.kdlDecodeOnly.}`, `{.kdlUntagged.}`.

Field-level: `{.kdlArg.}`, `{.kdlVariadic.}`, `{.kdlProp.}`, `{.kdlChild.}`, `{.kdlScalar.}`, `{.kdlRename: "x".}`, `{.kdlAlias("a", "b").}`, `{.kdlReserved.}`, `{.kdlSkip.}` / `{.kdlSkipEncode.}` / `{.kdlSkipDecode.}`, `{.kdlFlatten.}`.

Native Nim 2.x field defaults (`field: type = expr`) work as fallback values for absent props; inherited fields (`object of Base`) are included; custom scalars use the `kdlEncodeValue` / `kdlDecodeValue` `KdlValue` hook pair.

## vs the alternatives

- **[kdl-nim](https://github.com/Patitotective/kdl-nim)** (Patitotective) — a more featureful Nim KDL impl covering v1, v2, JiK, and XiK. Pick this if you need v1 compatibility or the JSON/XML-in-KDL transforms.
- **[nimkdl](https://github.com/greenm01/nimkdl)** (greenm01) — older Nim KDL effort. Different package, predates nkdl.
- **nkdl** (this library) — v2-only, focused on type-driven decode, compile-time embed, and edit-then-encode perf. Pick this if you want the perf numbers above, compile-time-validated configs, or `path()`-style typed queries.

## Safety limits

| Constant | Default | Module | Purpose |
|---|---|---|---|
| `MaxParserDepth` | 256 | `cursor.nim` | Recursion cap on `{ children }` nesting |
| `InterpRecursionCap` | 1024 | `grammar.nim` | Reference interpreter recursion cap |
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
