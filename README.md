# nimkdl

A KDL v2 parser for Nim with compile-time-validated typed decode, byte-lossless format preservation, and dual-parser differential testing. Currently the fastest format-preserving KDL parser benchmarked. About 16x faster than kdl-rs and 15x faster than greenm01/nimkdl on realistic configs ([benchmarks](BENCHMARK.md)).

```nim
import kdl

type Service {.kdlNode: "service".} = object
  name {.kdlArg.}: string
  replicas {.kdlProp.}: int = 1
  enabled {.kdlProp.}: bool = true

deriveDecode(Service)

# Parse error fails the BUILD, not the runtime. VM-evaluated:
const services = embed[seq[Service]]("config/services.kdl")

# Compile-time field-checked iteration:
for name in path(services, [it.enabled].name):
  echo name
# A typo (it.enabeled) becomes a compile error with the standard
# "did you mean 'enabled'?" suggestion instead of silently returning
# an empty result the way string-based query languages do.
```

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

All visible via `import kdl`.

## Intent

KDL is a strong document language with a thin parser ecosystem. The existing options are kdl-rs (Rust, mature, slow for the work it does) and greenm01/nimkdl (Nim, no compile-time integration, fails the v2 multi-script identifier corpus). Neither offered what we wanted for Nim consumers writing config-driven systems.

We wanted to catch config errors at compile time, not runtime. KDL files are configuration. They ship in the binary or get loaded at startup. `embed[T]("config.kdl")` evaluates the full parse and decode chain inside Nim's VM. A malformed file fails `nim c`, not production.

We wanted to catch query errors at compile time. Every JSON-Path-style query system returns silent empty results on a field-name typo. The `path()` macro walks an AST expression that the Nim compiler actually type-checks. Typos surface as "did you mean" diagnostics with standard editor integration.

We wanted byte-lossless format preservation without per-token overhead. kdl-rs stores leading and trailing whitespace plus comments on every AST token. We store a 128-bit `parseHash` per node (opt-in, default off) and surgically splice canonical output into the byte ranges that diverge from the parse-time fingerprint. Same round-trip guarantee, roughly 5x less data per node.

We wanted differential testing. The full conformance corpus runs against a hand-written recursive-descent parser AND an independent table-driven recognizer (`grammar.nim`). Agreement between two implementations is the strongest validity signal short of a formal proof.

We wanted honest perf. See [BENCHMARK.md](BENCHMARK.md). Methodology matters more than the headline number. The cross-implementation numbers are reproducible in the same container at the same flag profile, and we publish the path each fix took.

## Performance

Roughly 16x faster than kdl-rs and 15x faster than greenm01/nimkdl on realistic configs. Methodology, per-fixture comparison, and reproduction steps in [BENCHMARK.md](BENCHMARK.md). The architectural story behind the numbers is written up [on the blog](https://blog.leavitt.dev/posts/nimkdl-perf-hunt/).

## Spec coverage

### KDL v2

Full v2 spec coverage. The lexer handles every token form (bare and quoted and raw-string idents, all string variants including multi-line with indentation strip, all number bases with underscores and sign and fractional and exponent, all 6 keywords, line and nested-block comments, slashdash, line continuations, `\u{XXXX}` escapes with surrogate rejection, BOM handling, full Unicode whitespace tables, bidi-control rejection). The parser handles documents, nodes, entries, nested children, type annotations, slashdash at every level, token-adjacency enforcement, and multi-error reporting.

Conformance is **338 / 338** of the [kdl-org/kdl test corpus](https://github.com/kdl-org/kdl/tree/main/tests/test_cases). Zero skipped cases. The corpus is vendored at `tests/conformance/`.

Byte-equivalence is **243 / 243** of positive corpus cases. Every one satisfies `encode(parse(x, preserveFormat=true), emPreserve) == x`.

Reserved type annotations (spec §3) get parse-time validation for all 30-ish spec-defined tags. Range checks for `i8` through `u128`, `f32`, `f64`. Format validation for `uuid`, `ipv4`, `ipv6`, `date`, `time`, `date-time`, `duration`, `email`, `url`. ISO registry membership for `country-2`, `country-3`, `currency`. IEEE 754-2008 checks for `decimal`, `decimal64`, `decimal128`.

### KDL Schema Language (KSL), not implemented

KSL targets KDL v1 and has no working reference implementation. We replace it with Nim-types-are-the-schema. A pragma-annotated Nim type is the canonical schema. `deriveDecode[T]` reflects on it at compile time via `getImpl` and generates the decoder directly. Combined with the `kdlReserved` pragma (field or type level), this is a strict superset of KSL's portable-schema capability at the cost of being Nim-only.

### KDL Query Language (KQL), not implemented

The kdl-org spec marks KQL as "unreleased". The Rust reference implementation has its KQL tests under `disabled_tests/`. Building against a moving target with no working oracle isn't a good trade.

We replace it with the typed schema-path DSL (`path()` macro). Compile-time field validation makes string queries strictly worse for our use case. Refactor-safe, IDE-aware, "did you mean" diagnostics for free.

## Worked examples

### Parse then encode round-trip

```nim
import kdl

let r = parse("""
rule "compaction" {
  action "inject" template="ctx pressure rising"
}
""", preserveFormat = true)  # opt-in for byte-lossless emPreserve

doAssert r.isOk
echo encode(r.get)  # byte-identical to the input
```

### Type-driven decode

```nim
type
  Action {.kdlNode: "action".} = object
    kind {.kdlArg.}: string
    tmpl {.kdlProp, kdlRename: "template".}: string

  Rule {.kdlNode: "rule".} = object
    id      {.kdlArg.}:  string
    enabled {.kdlProp.}: bool = true
    action: Action

deriveDecode(Action)
deriveDecode(Rule)

let r = decode[Rule]("""
  rule "compaction" {
    action "inject" template="ctx pressure rising"
  }
""")
doAssert r.isOk
doAssert r.get.id == "compaction"
doAssert r.get.enabled                # default fired
doAssert r.get.action.kind == "inject"
```

### Compile-time embed

`embed[T]("path")` evaluates `lex` then `parse` then `decode[T]` inside Nim's VM and emits a `const`. A parse error fails the build, not the runtime. Zero module-init cost because the typed value is already in the binary's data segment.

```nim
const builtins = embed[seq[Rule]]("rules/defaults.kdl")
doAssert builtins.isOk   # always true at runtime, error would
                         # have failed the build
```

### Typed query

```nim
let rules = builtins.get

# path() macro, compile-time field-checked
for id in path(rules, [it.enabled].id):
  echo id

# iterator chain
for r in rules.where(it.enabled):
  echo r.id
let first = rules.first(it.id == "compaction")
```

### Differential testing

```nim
let viaFast = parse(source)
let viaRef  = referenceInterpret(source)
doAssert viaFast.isOk == viaRef.isOk
if viaFast.isOk:
  doAssert docEqual(viaFast.get, viaRef.get)
```

## Pragmas

Type-level.
- `{.kdlNode: "name".}` is the KDL node name (default is the type name lowercased).

Field-level.
- `{.kdlArg.}` is a positional argument.
- `{.kdlProp.}` is a property (`key=value`).
- `{.kdlChild.}` is a child node (default for nested objects and `seq[T]`).
- `{.kdlSkip.}` is never decoded and keeps Nim's default value.
- `{.kdlRename: "x".}` is used when the KDL name differs from the Nim field name.
- `{.kdlReserved.}` enables field-level or type-level reserved-type validation.

Native Nim 2.x field defaults (`field: type = expr`) work as fallback values.

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
nimble test                # full suite
nimble perfGuard           # regression guard for KdlNode deep-copy
nim c -r -d:release -p:src benchmarks/bench.nim
```

Containerized.

```bash
podman run --rm -v "$PWD:/work:Z" -w /work docker.io/nimlang/nim:2.2.0 nimble test
```

## License

MIT.
