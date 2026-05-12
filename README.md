# lib/kdl

In-tree Nim library implementing **KDL v2** (https://kdl.dev/spec/) with type-driven parsing and a compile-time-validated typed-path DSL. Used by amoxtli for all user-facing config (rules, workspace config, scorecards, manifests).

> **Status: v0.1.** Ships in amoxtli, extractable later via `git subtree split --prefix=lib/kdl main` if reuse-elsewhere becomes valuable. See [epic #517](https://github.com/coreyleavitt/amoxtli/issues/517) for the build history.

## What you get

| Layer | API | Purpose |
|---|---|---|
| Parse | `parse(source: string)` → `Result[KdlDoc, ParseError]` | KDL v2 text → untyped AST. |
| Encode | `encode(doc, mode = emPretty)` → `string` | AST → canonical KDL text. |
| Decode | `decode[T](source)` → `Result[T, ParseError]` | KDL text → typed Nim value (`T` must be `deriveDecode`'d). |
| Embed | `embed[T]("path.kdl")` | `staticRead` + decode at module init; build fails on missing file. |
| Query | `path(items, [pred].field.chain)` | Compile-time-checked filter+access on `seq[T]`. |
| Reference | `referenceInterpret(source)` | Table-driven independent parser; differential-test oracle. |

All visible at the top level: `import kdl`.

## The headline differentiator

```nim
import kdl

type Rule {.kdlNode: "rule".} = object
  id {.kdlArg.}: string
  enabled {.kdlAttr.}: bool = true

deriveDecode(Rule)

let r = decode[seq[Rule]]("""
  rule "compaction" enabled=#true
  rule "permission" enabled=#false
""")
let rules = r.get

# Typo-catches at compile time:
for id in path(rules, [it.enabel].id):     # ← typo, iterator form
  process(id)
# error: undeclared field: 'enabel' for type Rule
#        did you mean enabled?
```

Every other config-language query system (JSON Path, jq, CUE, KQL, …) silently returns empty results on a typo. lib/kdl turns that into a Nim compile error with the standard "did you mean" suggestion list.

## Spec coverage

### KDL v2 (kdl.dev/spec)

**Full**, modulo the explicitly-deferred items below:

- Lexer: all v2 token forms — identifiers (bare + quoted + raw-string), strings (regular / raw with arbitrary `#` count / multi-line with indentation strip / raw multi-line), numbers (decimal / hex / octal / binary with underscore separators, sign, fractional, exponent), keywords (`#true`/`#false`/`#null`/`#inf`/`#-inf`/`#nan`), punctuation, slashdash `/-`, line + nested-block comments, line continuations (with optional inline comments), whitespace-escape `\<ws>`, `\u{XXXX}` escape with surrogate rejection, BOM at input start.
- Parser: documents, nodes (incl. quoted/raw-string names), entries (positional args + properties with last-write-wins on repeats), nested children, type annotations on nodes/values/property-values, slashdash on nodes/entries/children-blocks.
- Encoder: canonical form — bare-emit identifiers when safe (with reserved-bareword quoting), hex/oct/bin → decimal, underscore-stripping, `#inf`/`#-inf`/`#nan` keyword form, minimal-escape strings, type-annotation preservation. Pretty (4-space indent) + compact modes.

Conformance: **284 / 338** of the [kdl-org/kdl test corpus](https://github.com/kdl-org/kdl/tree/main/tests/test_cases) passes (vendored at `tests/conformance/`). 54 cases skipped with documented v0.2 reasons in `tests/conformance/skips.txt`:

- Full Unicode bare-ident charset
- Unicode bidi-control rejection
- Tighter number-lexer rejection of malformed forms (`1e`, `.0`, `1_`, etc.)
- Hex literals that exceed int64 (deferred until kvBigInt variant)
- Slashdash + comment / multi-newline interleaving polish
- Multi-line string corner cases (escape interactions with closing-line indent)
- Specific spec corners (BOM-mid-file rejection, v1 legacy raw-string rejection, etc.)

The harness runs in `./dev test` (tier 2). The reference interpreter (a table-driven independent recognizer from `grammar.nim`) differential-tests every case against the hand parser; agreement is the strongest validity signal we have.

### KDL Schema Language (KSL) — **NOT implemented**

KSL targets KDL v1 and has no working reference implementation. We replace it with **Nim-types-are-the-schema** via the `parse[T]` macro (#528). A pragma-annotated Nim object is the canonical schema; the macro reflects on it at compile time via `getImpl` and generates the KDL-to-field decoder directly. No separate `.ksl` file format.

### KDL Query Language (KQL) — **NOT implemented**

KQL is explicitly unreleased in the kdl-org spec: *"This document describes KQL `next`. It is unreleased."* The Rust reference implementation has its KQL tests under `tests/disabled_tests/`. Building against a moving target with no working oracle isn't worth the engineering cost.

We replace it with the **typed schema-path DSL** (#534). Compile-time field validation makes string queries strictly inferior for our use case — refactor-safe, IDE-aware, "did you mean" diagnostics for free.

## Worked examples

### Parse → encode round trip

```nim
import kdl

let r = parse("""
rule "compaction" {
  action "inject" template="ctx pressure rising"
}
""")
doAssert r.isOk
echo encode(r.get)
# rule "compaction" {
#     action inject template="ctx pressure rising"
# }
```

### Type-driven decode

```nim
type
  Action {.kdlNode: "action".} = object
    kind* {.kdlArg.}: string
    tmpl* {.kdlAttr, kdlRename: "template".}: string

  Rule {.kdlNode: "rule".} = object
    id*      {.kdlArg.}:  string
    enabled* {.kdlAttr.}: bool = true
    action*: Action

deriveDecode(Action)
deriveDecode(Rule)

let r = decode[Rule]("""
  rule "compaction" {
    action "inject" template="ctx pressure rising"
  }
""")
doAssert r.isOk
doAssert r.get.id == "compaction"
doAssert r.get.enabled               # default fired
doAssert r.get.action.kind == "inject"
```

### Compile-time embedded builtins

```nim
# rules/defaults.kdl ships in the binary via staticRead at compile time;
# build fails if the file is missing or unreadable.
let builtins = embed[seq[Rule]]("rules/defaults.kdl")
doAssert builtins.isOk
```

### Typed query — three styles

```nim
let rules = builtins.get

# Style 1: path() macro
for id in path(rules, [it.enabled].id):
  echo id

# Style 2: iterator chain
for r in rules.where(it.enabled):
  echo r.id
let first = rules.first(it.id == "compaction")

# Style 3: object-variant pattern matching (via Nim's existing surface)
# Use std/fusion/matching or gara — no lib/kdl-specific glue needed.
```

### Differential testing via the reference interpreter

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
- `{.kdlAttr.}` — property (`key=value`)
- `{.kdlChild.}` — child node (default for nested objects + `seq[T]`)
- `{.kdlSkip.}` — never decoded; keeps Nim's default value
- `{.kdlRename: "x".}` — KDL name differs from Nim field name

Native Nim 2.x field default syntax (`field: type = expr`) works for fallback values.

## Safety limits

Constants surfaced as `const` values:

| Constant | Default | Where | Purpose |
|---|---|---|---|
| `MaxParserDepth` | 256 | `parser.nim` | Recursion cap on `{ children }` nesting |
| `InlineCapacity` | 22 | `intern.nim` | SBO inline-string capacity per Entry |
| `InterpRecursionCap` | 1024 | `grammar.nim` | Reference interpreter recursion cap |
| `KdlReprMaxDepth` | 32 | `ast.nim` | `$KdlDoc` cycle / pathological-depth guard |

## AGENTS.md macro-depth bend

amoxtli's `AGENTS.md` keeps macros ≤2 levels of expansion by default. lib/kdl explicitly bends this rule for three macros where deeper expansion is intrinsic to the work:

- `deriveDecode` — emits a `kdlDecodeImpl` proc per user type by walking `getImpl(T)`
- `embedAux` — runs `staticRead` at compile time and emits the embedded literal + decode call
- `path` — walks a path expression AST and emits a typed iterator with `typeof(block: …)` type inference

Each macro's docstring explains the expansion shape. Set `-d:dumpKdlGen` to dump the generated code during compilation when debugging.

## Extraction path

If lib/kdl ever earns its own ecosystem story:

```
git subtree split --prefix=lib/kdl main
```

Produces a clean standalone repo with the full history of the in-tree work. No surgery needed in amoxtli.

## License

MIT.
