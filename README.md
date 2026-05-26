# nimkdl

A KDL v2 parser for Nim with compile-time-validated typed decode, byte-lossless format preservation, and dual-parser differential testing. On realistic configs nimkdl runs about 1.4x faster than [ckdl](https://github.com/tjol/ckdl) (a hand-written C parser) and 8-18x faster than the Rust options (knus, kdl-rs). See [BENCHMARK.md](BENCHMARK.md).

```nim
import kdl

type Service {.kdlNode: "service".} = object
  name {.kdlArg.}: string
  replicas {.kdlProp.}: int = 1
  enabled {.kdlProp.}: bool = true

deriveDecode(Service)

# Runtime parse of a user-supplied config file.
let r = decode[seq[Service]](readFile("services.kdl"))
if r.isErr:
  stderr.writeLine r.getErr.formatError(readFile("services.kdl"),
                                        filename = "services.kdl")
  quit 1

for service in r.get:
  if service.enabled:
    echo service.name, " x", service.replicas
```

The same file can also be embedded at compile time. A parse error then fails `nim c` instead of production. See [the embed section](#compile-time-embed).

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

KDL is a strong document language with a thin parser ecosystem. The viable options before nimkdl were [kdl-rs](https://github.com/kdl-org/kdl-rs) (the canonical Rust impl, mature, slow for the work it does), [knus](https://crates.io/crates/knus) (Rust serde-style, type-driven, also slow), and [ckdl](https://github.com/tjol/ckdl) (a well-engineered C library with a SAX-style event API). None of them ran on Nim's compile-time VM, none caught query typos at compile time, and the Rust options carry per-token whitespace storage that's heavy for the byte-lossless round-trip case.

We wanted the runtime case to be ergonomic. Loading a user-supplied config at startup, parsing a config submitted to an HTTP endpoint, validating a file an operator just edited. These are the common scenarios. The library leans on `Result[T, ParseError]` for the happy path, structured errors with rich span information for the diagnostic path, and `parseAll` for "show me every error at once" workflows (LSP, CI lint, batch validation).

We wanted to catch query errors at compile time. Every JSON-Path-style query system returns silent empty results on a field-name typo. The `path()` macro walks an AST expression that the Nim compiler actually type-checks. Typos surface as "did you mean" diagnostics with standard editor integration.

We wanted compile-time integration as a bonus, not the only path. KDL files that ship in the binary (built-in rules, default policies, embedded schemas) can be validated at `nim c` time via `embed[T]("config.kdl")`. The parser runs inside Nim's VM and a malformed file fails the build. Same library, opt-in capability.

We wanted byte-lossless format preservation without per-token overhead. kdl-rs stores leading and trailing whitespace plus comments on every AST token. We store a 128-bit `parseHash` per node (opt-in, default off) and surgically splice canonical output into the byte ranges that diverge from the parse-time fingerprint. Same round-trip guarantee, roughly 5x less data per node.

We wanted differential testing. The full conformance corpus runs against a hand-written recursive-descent parser AND an independent table-driven recognizer (`grammar.nim`). Agreement between two implementations is the strongest validity signal short of a formal proof.

We wanted honest perf. See [BENCHMARK.md](BENCHMARK.md). Methodology matters more than the headline number. The cross-implementation numbers are reproducible in the same container at the same flag profile, and we publish the path each fix took.

## Performance

Roughly 1.4x faster than ckdl (C), 8x faster than knus, and 18x faster than kdl-rs on realistic configs. Methodology, per-fixture comparison, and reproduction steps in [BENCHMARK.md](BENCHMARK.md). The story of how we got there is on [the blog](https://blog.leavitt.dev/posts/nimkdl-perf-hunt/).

## Spec coverage

### KDL v2

Full v2 spec coverage. The lexer handles every token form (bare and quoted and raw-string idents, all string variants including multi-line with indentation strip, all number bases with underscores and sign and fractional and exponent, all 6 keywords, line and nested-block comments, slashdash, line continuations, `\u{XXXX}` escapes with surrogate rejection, BOM handling, full Unicode whitespace tables, bidi-control rejection). The parser handles documents, nodes, entries, nested children, type annotations, slashdash at every level, token-adjacency enforcement, and multi-error reporting.

Conformance is **338 / 338** of the [kdl-org/kdl test corpus](https://github.com/kdl-org/kdl/tree/main/tests/test_cases). Zero skipped cases. The corpus is vendored at `tests/conformance/`.

Byte-equivalence is **243 / 243** of positive corpus cases. Every one satisfies `encode(parse(x, preserveFormat=true), emPreserve) == x`.

Reserved type annotations (spec §3) get parse-time validation for all 30-ish spec-defined tags. Range checks for `i8` through `u128`, `f32`, `f64`. Format validation for `uuid`, `ipv4`, `ipv6`, `date`, `time`, `date-time`, `duration`, `email`, `url`. ISO registry membership for `country-2`, `country-3`, `currency`. IEEE 754-2008 checks for `decimal`, `decimal64`, `decimal128`.

### KDL Schema Language (KSL), not implemented

KSL targets KDL v1 and has no working reference implementation. We replace it with Nim-types-are-the-schema. The Nim type IS the schema, and the compiler enforces it.

Say you want to validate a config that looks like this.

```kdl
service "auth" {
  replicas 3
  port 8443
  env {
    LOG_LEVEL "info"
  }
}
```

A KSL-style approach would put validation in a separate `.ksl` file your tooling would have to parse and apply at runtime. Our approach puts it in the Nim type, validated at compile time.

```nim
import kdl

type
  EnvVar {.kdlNode.} = object
    name  {.kdlArg.}: string
    value {.kdlArg.}: string

  Env {.kdlNode: "env".} = object
    vars: seq[EnvVar]

  Service {.kdlNode: "service".} = object
    name     {.kdlArg.}: string
    replicas {.kdlChild.}: int = 1
    port     {.kdlChild.}: int
    env      {.kdlChild.}: Env

deriveDecode(EnvVar)
deriveDecode(Env)
deriveDecode(Service)

let r = decode[Service](readFile("auth.kdl"))
if r.isErr:
  echo r.getErr.formatError(filename = "auth.kdl")
  quit 1
```

A missing `port` value is a parse error. A typo in `replcias` becomes the standard "did you mean 'replicas'" diagnostic. A wrong type (`port "8443"` when the field is `int`) errors at parse time. None of this requires a separate schema file or a runtime validation pass.

Combined with the `kdlReserved` pragma (`{.kdlReserved.}` at the type level rejects any unknown node names, at the field level rejects any unknown props), this is a strict superset of what KSL was meant to provide, at the cost of being Nim-only.

### KDL Query Language (KQL), not implemented

The kdl-org spec marks KQL as "unreleased". The Rust reference implementation has its KQL tests under `disabled_tests/`. Building against a moving target with no working oracle isn't a good trade.

We replace it with the typed schema-path DSL (`path()` macro), which is a string-free analog of JSONPath or jq for KDL.

Say you have a parsed config and you want all the enabled service names.

```nim
# KQL (hypothetical, no working impl):
let result = query(doc, """top() >> service[.enabled == true] >> @name""")
# Returns Result[seq[string]], at runtime.
# A typo in 'service' or 'enabled' produces an empty result, silently.

# nimkdl path():
let names = path(services, [it.enabled].name)
# Returns iterator[string], compile-time field-checked.
# A typo (it.enabeled) becomes a compile error with the standard
# "did you mean 'enabled'?" suggestion.
```

The `path(items, [pred].chain)` syntax reads as `items where pred yielding chain`. Predicates and accessors are real Nim expressions, type-checked against the actual type. Iterator output means it composes with the rest of the stdlib (`toSeq`, `map`, etc.).

```nim
import std/sequtils

# All enabled service names
for name in path(services, [it.enabled].name):
  echo name

# Just the first matching one
let firstAuth = services.first(it.name.startsWith("auth"))
if firstAuth.isSome:
  echo firstAuth.get.replicas

# Compose with sequtils
let allPorts = path(services, [it.enabled].port).toSeq.sorted
```

String queries are strictly worse for our use case because the field references aren't refactor-safe, IDE-aware, or typo-detected. The trade-off is that you can't ship a query as a string to a runtime user (e.g. a CLI flag), which is something jq-style tools do support. We assume the consumer is Nim code, not an interactive query layer.

## Getting started

For consumers new to nimkdl or Nim, the simplest possible usage is `parse(source)`, then walk the resulting `KdlDoc` directly. No macros, no pragmas, no compile-time machinery.

Given this file `services.kdl`:

```kdl
service "auth" port=8443 replicas=2
service "gateway" port=8080 replicas=4
service "metrics" port=9090
```

The shortest useful program reads it and prints the names.

```nim
import kdl

let r = parse(readFile("services.kdl"))
if r.isErr:
  echo "parse failed: ", r.getErr.hint
  quit 1

for node in r.get.nodes:
  echo r.get.interner.lookup(node.name)

# Output:
#   service
#   service
#   service
```

Every node has a `name` (interned, look it up to get the string), zero or more `entries` (the args and props), and zero or more `children` (more nodes).

To read the first arg of each node:

```nim
for node in r.get.nodes:
  for entry in node.entries:
    if entry.kind == keArgument:
      echo entry.argValue.strVal   # the first positional arg
      break
```

To read a specific property:

```nim
for node in r.get.nodes:
  for entry in node.entries:
    if entry.kind == keProperty and r.get.interner.lookup(entry.propName) == "port":
      echo entry.propValue.intVal
```

That's enough to do useful work. Most consumers move from there to typed decode, which is more concise and catches schema errors at compile time.

```nim
type Service {.kdlNode: "service".} = object
  name {.kdlArg.}: string
  port {.kdlProp.}: int
  replicas {.kdlProp.}: int = 1

deriveDecode(Service)

let services = decode[seq[Service]](readFile("services.kdl")).get
for s in services:
  echo s.name, " on port ", s.port, " x", s.replicas
```

Same data, less boilerplate, and a missing field or wrong type fails at parse time with a useful error pointing at the right line.

## Worked examples

### Handling user-submitted input

This is the common case. A file the user just edited, a config posted to an HTTP endpoint, a CLI flag pointing at a path. The user gets a useful diagnostic on failure and the program continues to do its job on success.

```nim
import kdl

proc loadServices(path: string): seq[Service] =
  let src = readFile(path)
  let r = decode[seq[Service]](src)
  if r.isErr:
    stderr.writeLine r.getErr.formatError(src, filename = path)
    quit 1
  r.get

let services = loadServices("services.kdl")
```

`formatError` renders the standard caret diagnostic.

```
error: expected an integer, got string
  --> services.kdl:3:14
   |
 3 |   port "8443"
   |        ^^^^^^
   hint: type annotation (int) expected here
```

For interactive tools, IDEs, or batch validators that need to surface every error at once, use `parseAll` instead. It collects every lex and parse error at the doc, node, and entry level and returns a partial AST built from whatever did parse.

```nim
let (doc, errors) = parseAll(readFile("services.kdl"), sourcePath = "services.kdl")

if errors.len > 0:
  for e in errors:
    stderr.writeLine e.formatError(doc.sourceText, filename = "services.kdl")
  # Decide whether to continue with the partial doc or bail.
  # CI lint = bail. IDE = continue (highlight + autocomplete).
```

For untrusted input (an HTTP body, a user upload), apply a size cap before parsing. The lexer has internal guards against pathological strings (`MaxRawStringHashes`) and recursion depth (`MaxParserDepth`), but you generally want a coarse size limit at the boundary too.

```nim
const MaxConfigBytes = 1 * 1024 * 1024  # 1 MB
if body.len > MaxConfigBytes:
  return Http413(detail: "config too large")
let r = decode[ServiceList](body)
```

### Parse then encode round-trip

```nim
import kdl

let r = parse(readFile("rules.kdl"), preserveFormat = true)
if r.isErr:
  echo "parse failed: ", r.getErr.hint
  quit 1

let doc = r.get
echo encode(doc)  # byte-identical to the input
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

let r = decode[Rule](readFile("rule.kdl"))
if r.isErr:
  echo r.getErr.formatError(filename = "rule.kdl")
  quit 1

let rule = r.get
echo "loaded rule '", rule.id, "', action ", rule.action.kind
if rule.enabled:
  apply(rule)
```

### Compile-time embed

This is the niche case. For configs that ship in the binary (built-in defaults, embedded schemas, generated tables) you can validate at `nim c` time instead of startup.

`embed[T]("path")` evaluates `lex` then `parse` then `decode[T]` inside Nim's VM and emits a `const`. A parse error fails the build, not the runtime. Zero module-init cost because the typed value is already in the binary's data segment.

For everything else (user-supplied files, HTTP bodies, anything that arrives at runtime) you want `decode[T](readFile(path))` from the section above.

```nim
const builtins = embed[seq[Rule]]("rules/defaults.kdl").get
# `.get` is safe here. If the file were malformed, the build would
# have failed at `nim c` rather than producing a runtime Err.

for rule in builtins:
  echo "loaded builtin '", rule.id, "'"
```

### Typed query

```nim
# path() macro, compile-time field-checked
for id in path(builtins, [it.enabled].id):
  echo "enabled: ", id

# iterator chain
for rule in builtins.where(it.enabled):
  apply(rule)

let compaction = builtins.first(it.id == "compaction")
if compaction.isSome:
  apply(compaction.get)
```

### Differential testing

```nim
# Used in the test suite to cross-validate every conformance fixture.
let viaFast = parse(source)
let viaRef  = referenceInterpret(source)

if viaFast.isOk != viaRef.isOk:
  echo "parsers disagree on success/failure for: ", source
elif viaFast.isOk and not docEqual(viaFast.get, viaRef.get):
  echo "parsers disagree on AST for: ", source
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

Apache 2.0. See [LICENSE](LICENSE).
