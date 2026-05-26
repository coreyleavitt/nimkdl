# nimkdl

A KDL v2 parser for Nim with **compile-time-validated typed decode**,
**byte-lossless format preservation**, and **dual-parser differential
testing**. Currently the fastest format-preserving KDL parser
benchmarked: **~16× kdl-rs**, **~15× greenm01/nimkdl** on realistic
configs ([benchmarks](BENCHMARK.md)).

```nim
import kdl

type Service {.kdlNode: "service".} = object
  name {.kdlArg.}: string
  replicas {.kdlProp.}: int = 1
  enabled {.kdlProp.}: bool = true

deriveDecode(Service)

# Parse error fails the BUILD, not the runtime — VM-evaluated:
const services = embed[seq[Service]]("config/services.kdl")

# Compile-time field-checked iteration:
for name in path(services, [it.enabled].name):
  echo name
# At a typo (`it.enabeled`) the compiler errors with
# "did you mean 'enabled'?" — instead of silently returning empty.
```

## What's in the box

| Layer | Surface | Notes |
|---|---|---|
| Parse | `parse(src, preserveHashes = false) -> Result[KdlDoc, ParseError]` | KDL v2 text → AST. `preserveHashes` opt-in for `emPreserve`. |
| Encode | `encode(doc, mode = emPreserve) -> string` | `emPreserve` is byte-lossless; `emPretty` / `emCompact` canonical. |
| Decode | `decode[T](src) -> Result[T, ParseError]` | Typed decode via `deriveDecode[T]`. |
| Embed | `embed[T]("path")` | `staticRead` + decode at compile time. Bad input = build error. |
| Query | `path(items, [pred].chain)` | Compile-time field-checked filter+access. |
| Reference | `referenceInterpret(src)` | Table-driven independent parser used as differential-test oracle. |
| Multi-error | `parseAll(src) -> (doc, errors)` | Collects every error; returns partial doc. |

All visible via `import kdl`.

## Intent — why this exists

KDL is a strong document language with a thin parser ecosystem. The
existing options are `kdl-rs` (Rust, mature, slow for the work it
does) and `greenm01/nimkdl` (Nim, no compile-time integration, fails
the v2 multi-script identifier corpus). Neither offers what we want
for Nim consumers writing config-driven systems:

1. **Catch config errors at compile time, not runtime.** KDL files
   are configuration — they ship in the binary or get loaded at
   startup. `embed[T]("config.kdl")` evaluates the full parse +
   decode chain in Nim's VM. A malformed file fails `nim c`, not
   production.

2. **Catch query errors at compile time.** Every JSON-Path-style
   query system returns silent empty results on a field-name typo.
   The `path()` macro walks an AST expression that the Nim compiler
   actually type-checks; typos surface as "did you mean" diagnostics
   with the standard editor integration.

3. **Byte-lossless format preservation without per-token overhead.**
   `kdl-rs` stores leading/trailing whitespace + comments on every
   AST token. We store a 128-bit `parseHash` per node (opt-in,
   default off) and surgically splice canonical output into the byte
   ranges that diverge. Same round-trip guarantee, ~5× less data
   per node.

4. **Differential-tested.** The full conformance corpus runs against
   both a hand-written recursive-descent parser AND an independent
   table-driven recognizer (`grammar.nim`). Agreement is the
   strongest validity signal short of a formal proof.

5. **Honest perf.** See [BENCHMARK.md](BENCHMARK.md) — methodology
   matters more than the headline number. Cross-impl numbers are
   reproducible in the same container at the same flag profile, and
   we publish the path each fix took.

## Technique — how the speed happens

The 8× total perf improvement over our own starting point (and the
~16× lead over kdl-rs) didn't come from one trick. The architectural
choices that compounded:

### Compile-time-eval forced zero-alloc patterns

`embed[T]("file.kdl")` evaluates the entire parser inside Nim's VM.
The VM has no FFI, no exceptions, restricted pointer semantics. To
make `embed` work at all, the parser had to be `{.noSideEffect.}`
end-to-end, which forced:

- `Result[T, E]` instead of exception-based errors
- Span-based tokens with payloads in side-tables (no string copies
  per token)
- A pure-Nim FNV-128 (xxh3 via FFI would have broken `embed[T]`)
- String interning with small-buffer optimization

None of these were "for perf" — they were for compile-time
correctness. Perf came as a side effect.

### Sink-perfect Nim ORC

Nim 2.x's ORC supports move semantics on last-use, but the
discriminant on `case object` blocks the move analysis. Without
explicit `sink` hooks, every `nodes.add(parseResult.get)` deep-copied
the entire subtree at every level of recursion — `Σ N = O(N²)` on
deep configs. Sink overloads on `Result.ok` (producer-side move-in)
and a `take()` method (consumer-side move-out) brought parse-time
copying to zero. Caught by `perf record` showing
`eqcopy_(seq<KdlNode>)` at 19% of CPU recursing 10+ levels deep.

The `nimble perfGuard` CI task pins this — `proc =copy(KdlNode)
{.error.}` under `-d:probeKdlNodeCopy` makes any new copy site a
compile error.

### Opt-in `parseHash`

The format-preservation path needs an FNV-128 fingerprint per
node + entry, computed at parse time. The 95% of consumers who
don't preserve format (typed decode, validation-and-discard,
codegen) shouldn't pay for it. `parse(src, preserveHashes = false)`
is the default; `encode(doc, emPreserve)` fails loud if called on
a no-hash doc rather than silently emitting reformatted output.
~18% perf win for default consumers.

### SWAR bare-ident scanner

The lexer's bare-ident hot loop processes 8 bytes per memory load
using the standard XOR + `hasZeroByte` SWAR pattern. Branch-free,
handles ASCII fast-path; defers to the byte loop on the first
non-ASCII byte for Unicode codepoint validation. ~4% win on
real-world configs — modest because most idents in realistic configs
are <8 bytes and skip the SWAR loop, but it's the right pattern for
long namespaced identifiers (`deployment.coreyleavitt.io/owner`).

### Single-source-of-truth discipline

Two parallel hash functions over the same node shape (`hashNodeContent`
recursing vs `hashNodeFromChildHashes` using stored child hashes)
caused a 14.4× perf regression on deep configs. The fix: parser uses
the bottom-up form; the debug-only ground-truth recomputation uses
the recursive form. An algebraic equivalence test pins the
relationship; conformance byte-equivalence (243/243) exercises it
end-to-end.

## Spec coverage

### KDL v2

**Full** v2 spec coverage. Lexer covers every token form (bare +
quoted + raw-string idents, all string variants including multi-line
with indentation strip, all number bases with underscores +
sign + fractional + exponent, all 6 keywords, line + nested-block
comments, slashdash, line continuations, `\u{XXXX}` escapes with
surrogate rejection, BOM handling, full Unicode whitespace tables,
bidi-control rejection). Parser covers documents, nodes, entries,
nested children, type annotations, slashdash at every level,
token-adjacency enforcement, multi-error reporting.

**Conformance: 338 / 338** of the
[kdl-org/kdl test corpus](https://github.com/kdl-org/kdl/tree/main/tests/test_cases)
passes (vendored at `tests/conformance/`). Zero skipped cases.

**Byte-equivalence: 243 / 243** of positive corpus cases satisfy
`encode(parse(x, preserveHashes=true), emPreserve) == x`.

**Reserved type annotations** (spec §3): all ~30 spec-defined tags
validated at parse time (range checks for `i8`..`u128`/`f32`/`f64`,
format validation for `uuid`/`ipv4`/`ipv6`/`date`/`time`/`date-time`/
`duration`/`email`/`url`/etc., ISO registry membership for
`country-2`/`country-3`/`currency`, IEEE 754-2008 checks for
`decimal`/`decimal64`/`decimal128`).

### KDL Schema Language (KSL) — not implemented

KSL targets KDL v1 and has no working reference implementation. We
replace it with **Nim-types-are-the-schema**: a pragma-annotated
Nim type is the canonical schema; `deriveDecode[T]` reflects on it
at compile time via `getImpl` and generates the decoder directly.
Combined with the `kdlReserved` pragma (field- or type-level), this
is a strict superset of KSL's capability — at the cost of being
Nim-only.

### KDL Query Language (KQL) — not implemented

The kdl-org spec marks KQL as "unreleased"; the Rust reference
implementation has its KQL tests under `disabled_tests/`. Building
against a moving target with no oracle isn't a good trade.

We replace it with the typed schema-path DSL (`path()` macro).
Compile-time field validation makes string queries strictly worse
for our use case — refactor-safe, IDE-aware, "did you mean"
diagnostics for free.

## Worked examples

### Parse → encode round trip

```nim
import kdl

let r = parse("""
rule "compaction" {
  action "inject" template="ctx pressure rising"
}
""", preserveHashes = true)   # opt-in for byte-lossless emPreserve

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
doAssert r.get.enabled            # default fired
doAssert r.get.action.kind == "inject"
```

### Compile-time embed

`embed[T]("path")` evaluates `lex → parse → decode[T]` inside Nim's
VM and emits a `const`. **A parse error fails the build**, not the
runtime. Zero module-init cost — the typed value is in the binary's
data segment.

```nim
const builtins = embed[seq[Rule]]("rules/defaults.kdl")
doAssert builtins.isOk   # always true at runtime — error would
                         # have failed the build
```

### Typed query

```nim
let rules = builtins.get

# path() macro — compile-time field-checked
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

## Pragmas reference

Type-level:
- `{.kdlNode: "name".}` — KDL node name (default: type name lowercased)

Field-level:
- `{.kdlArg.}` — positional argument
- `{.kdlProp.}` — property (`key=value`)
- `{.kdlChild.}` — child node (default for nested objects + `seq[T]`)
- `{.kdlSkip.}` — never decoded; keeps Nim's default value
- `{.kdlRename: "x".}` — KDL name differs from Nim field name
- `{.kdlReserved.}` — field- or type-level reserved-type validation

Native Nim 2.x field defaults (`field: type = expr`) work as fallback values.

## Safety limits

| Constant | Default | Module | Purpose |
|---|---|---|---|
| `MaxParserDepth` | 256 | `parser.nim` | Recursion cap on `{ children }` nesting |
| `InlineCapacity` | 22 | `intern.nim` | SBO inline-string capacity per Entry |
| `InterpRecursionCap` | 1024 | `grammar.nim` | Reference interpreter recursion cap |
| `KdlReprMaxDepth` | 32 | `ast.nim` | `$KdlDoc` cycle / pathological-depth guard |
| `MaxRawStringHashes` | 255 | `lexer.nim` | Cap on `#` count in raw-string fence |

## Development

```bash
nimble test                 # full suite (~25 test files)
nimble perfGuard            # regression guard for KdlNode deep-copy
nim c -r -d:release -p:src benchmarks/bench.nim   # benchmark
```

Containerized:

```bash
podman run --rm -v "$PWD:/work:Z" -w /work docker.io/nimlang/nim:2.2.0 nimble test
```

## License

MIT.
