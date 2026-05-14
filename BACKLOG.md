# lib/kdl — pre-staged issue backlog

This file lists outstanding items that would land as GitHub issues if
`lib/kdl` is ever extracted as a standalone library (`git subtree split
--prefix=lib/kdl main`). It mixes three categories:

- **Feature gaps** — capabilities a generic KDL library might be
  expected to have. Some are design choices we made deliberately; the
  rationale is recorded so the next maintainer doesn't re-litigate.
- **Correctness items** — bugs / edge cases surfaced by audits that we
  haven't fixed yet.
- **API / quality cleanup** — naming, symmetry, allocation hot-spots,
  documentation drift.

Status notation:
- `[ ]` — pending
- `[~]` — partial / under known limitation
- `[x]` — done (kept here for traceability of decisions)
- `[—]` — deliberate non-goal with rationale

Severity is the column right after the title.

---

## Correctness

### `[x]` `High` — emPreserve: preserved children in a modified parent lose indentation

Resolved by c3e6d16. Encoder now does textual-splice at byte
granularity — starts from the node's source bytes and replaces only
the elements that diverge from their parse-time fingerprint. No
canonical reconstruction means no flush-left seam can appear.

### `[x]` `High` — emPreserve: preserved nodes produce spurious blank lines

Resolved by c3e6d16. Parser now ends `KdlNode.span` at the last
consumed token's finish (not at the next token's start), so trailing
newlines / terminators live at the doc level where the splice can
preserve them correctly.

### `[x]` `Medium` — parseAll: node-level error inside a children block inflates error count

Resolved by c3e6d16. `parseChildren` is now accumulating-aware
(mirror of `parseDocumentAccumulating`); inner parseNode failures
push to the error buffer and call the new `skipToBlockBoundary`
helper (balanced-brace-aware) instead of propagating up.

### `[x]` `Medium` — Raw field mutation bypasses emPreserve silently

Resolved by a debug-only sanity check at the top of the emPreserve
fast path: before returning `doc.sourceText`, walk top-level nodes
and assert each node's current hash matches its `parseHash`. Raw
field mutation that bypassed `markMutated` now raises
`AssertionDefect` with a message naming `markMutated` and the
builder API. Zero overhead in release builds — guarded by
`when not defined(release)`. Tests in `test_preserve.nim` cover
the mutation-caught, clean-doc-still-fast-paths, and
markMutated-skips-assertion cases.

### `[x]` `Medium` — validateDecimal passes dead exponent-range parameters

Resolved by grouping the three loose ints into a `DecimalBounds`
object and providing named constants (`Decimal64Bounds`,
`Decimal128Bounds`). Two overloads of `validateDecimalFormat` now
exist:

- `validateDecimalFormat(v, tag)` — unbounded, used by `(decimal)`.
- `validateDecimalFormat(v, tag, bounds)` — bounded, used by
  `(decimal64)` and `(decimal128)`.

A shared `parseDecimalShape` helper does the format parse and
returns the significand + exponent; the bounded overload applies
ranges on top. A future maintainer adding a new bounded form
defines a new constant — they can't accidentally leave
`expLow=0`/`expHigh=0` because there is no place to type them
separately.

### `[x]` `Low` — KdlValue.== compares typeAnnotation handles unsafely across docs

Already resolved (stale BACKLOG entry): `KdlValue.==` carries the
cross-doc caveat in its docstring and points at `valueEqual(aDoc,
bDoc, a, b)`, which uses `equalsAcross` to compare the typeAnnotation
by interned bytes rather than handle. Behavior regression-guarded
by two new tests in `test_ast.nim` (same-string-different-handles →
equal; different-strings-same-handle → not equal).

### `[x]` `Low` — setProp / addArg / setArg don't re-intern cross-doc value annotations

Resolved via the dedicated-helper route (option C in the slice plan):

- New `migrateValue(srcDoc: KdlDoc, dstDoc: var KdlDoc, v: var KdlValue)`
  re-interns `v.typeAnnotation` against `dstDoc`'s interner. No-op
  when annotation is `InvalidInterned` or when the two docs share
  an interner (compared by `addr`).
- Mutator docstrings (`setProp`, `addArg`, `setArg`) now name the
  cross-doc caveat and point at `migrateValue`.

The signature-change route was rejected: adding a `srcDoc` parameter
to every mutator pollutes the 99% case (values constructed via
`newStringValue` carry `InvalidInterned`) for one rare migration
case. A runtime cross-doc assertion was also rejected as
fundamentally unsound — a valid foreign handle can coincide with a
valid local handle.

---

## API consistency

### `[—]` `High` — encode(doc) is infallible; encode[T](v) is fallible — same name, opposite contracts

Deliberate non-goal. The pairing is `parse↔encode` (text↔doc) and
`decode[T]↔encode[T]` (text↔T). Two `encode` overloads for two
distinct pairings is correct; overload resolution dispatches by
argument type. Reader confusion is a docs problem (call this out
in README's API table), not a rename problem.

### `[x]` `High` — Two overlapping `hasProp` overloads with incompatible key types

Resolved by renaming the InternedStr-keyed variant in `codegen.nim`
to `hasPropInterned`. Similar rename for the other codegen-internal
helpers (`findPropInterned`, `findChildInterned`, `hasChildInterned`,
`childrenNamedInterned`). User code uses the bare string-keyed
versions in `ast.nim`; codegen-emitted decoder bodies use the
`*Interned` versions. Module docstring at the top of the codegen
helper block documents the boundary.

### `[—]` `High` — parseAll returns a tuple; parse returns a Result — asymmetric

Deliberate non-goal. `parseAll`'s semantics are *intrinsically*
different: it always produces a doc (possibly partial). Forcing it
into `Result[KdlDoc, seq[ParseError]]` loses the partial doc on error.
The tuple shape reflects the semantics; documenting the contract is
the right fix, not reshaping the return type.

### `[x]` `High` — `prop` / `findProp` and `child` / `findChild` are different verbs at different modules

Resolved together with the `hasProp` disambiguation: codegen's
internal `findProp`/`findChild` now have the `Interned` suffix.
Public string-keyed API lives in `ast.nim` (`prop`, `child`,
`findNode`, etc.). Same operation, different layer; the suffix
makes the layer visible.

### `[x]` `High` — findArg is exported from codegen.nim with no ast.nim counterpart

Resolved by moving the positional-argument readers from `codegen.nim`
to `ast.nim` and renaming. New: `arg(n, idx): KdlValue` and
`hasArg(n, idx): bool` in `ast.nim`. Codegen-emitted decoders
delegate to these.

### `[x]` `High` — Sentinel-node return is undocumented and asymmetric with `hasProp`

Resolved by switching public string-keyed readers to `Option[T]`:
`prop` now returns `Option[KdlValue]`, `child` and `findNode` return
`Option[KdlNode]`. Sentinel pattern is retained only on the
InternedStr-keyed codegen-internal helpers where it's a hot-path
optimisation. Predicate companions `hasProp`/`hasChild`/`hasNode`
all exist for alloc-free presence checks. The Option-vs-sentinel
distinction also lets callers tell missing properties apart from
properties whose value is `#null`.

### `[x]` `High` — decode[T] has no decodeAll[T] equivalent for typed multi-error

Resolved by adding `decodeAll[T](source, sourcePath) →
tuple[value, errors]` in `codegen.nim`. Aggregates parse-time errors
(via `parseAll`) AND decode-time errors at the **node** boundary:
each top-level node either decodes fully or contributes exactly one
error; siblings continue independently.

Granularity is at the node, not the field — a deliberate scope choice
to avoid reworking every primitive decoder for per-field
accumulation. If finer granularity becomes necessary, it'll arrive
as an additive `granularity` parameter, not a contract break.

Tests live in `tests/test_decode_all.nim` covering: clean input,
parse-error-doesn't-stop-siblings, decode-error-doesn't-stop-siblings,
single-T missing-node, and combined parse+decode error aggregation.

### `[x]` `Medium` — encode[T] has no EncodeMode parameter

Resolved as a layered API per the BACKLOG sketch (we did both
options):

- **New primitive**: `encodeNode*[T: object](v, doc: var KdlDoc):
  Result[KdlNode, ParseError]` — typed-value → single AST node.
  Composable for multi-node docs, manual-node mixing, and
  fragment assembly.
- **`encode[T](v, mode = emPretty)`**: thin wrapper that calls
  `encodeNode` → wraps in a fresh doc → renders at the requested
  mode. Default `emPretty` (vs `encode(doc)`'s `emPreserve`)
  because a freshly-constructed typed value has no source bytes
  to preserve.
- **`encode[seq[T]](vs, mode = emPretty)`**: each element becomes
  one top-level node. Symmetric with `decode[seq[T]]`. Layer 1
  kdlReserved validation stops at the first failure.

Mirrors the parse/decode layering: `parse` (text→AST) +
`decode[T]` (AST→T) ↔ `encodeNode[T]` (T→AST) + `encode[T]`
(T→text).

### `[x]` `Medium` — Doc-level `remove` / `replace` drop the qualifier

Resolved by renaming `remove(doc, name) → removeNode(doc, name)` and
`replace(doc, name, repl) → replaceNode(doc, name, repl)` in
`ast.nim`. Symmetric with `removeChild`/`replaceChild` at the node
level.

### `[x]` `Medium` — `kdlAttr` pragma vs `prop` accessor — vocabulary mismatch

Resolved by renaming `{.kdlAttr.}` → `{.kdlProp.}` throughout codegen,
tests, and README. No alias; per `no_pre_1_aliases` policy.

### `[x]` `Medium` — Find-vs-bare verb inconsistency between node-level and doc-level accessors

Resolved by aligning doc-level to bare nouns (option 2 in the
original fix sketch):

- `findNode(doc, name)` → `node(doc, name): Option[KdlNode]`
- `findNodes(doc, name)` → `nodes(doc, name): seq[KdlNode]`

Matches the existing node-level convention (`child`, `prop`, `arg`)
and the broader bare-noun accessor family. The `doc.nodes` field
(unfiltered) coexists with `doc.nodes(name)` proc (filtered) the
same way `KdlNode.children` (field) coexists with
`n.children(doc, name)` (proc) — established Nim pattern;
arity disambiguates.

### `[x]` `Medium` — Missing `getArg` / `arg(n, idx)` reader

Resolved together with the "findArg moves to ast" item above. New:
`arg(n, idx): KdlValue` and `hasArg(n, idx): bool` in `ast.nim`.

### `[x]` `Medium` — embed[T] docstring overclaims

Resolved by making the code match the claim, not the doc match the
code. The `embedAux` macro now emits a `when isErr: {.error: ...}`
gate on the compile-time-evaluated decode result. A malformed KDL
file (or a decode-type-mismatch against `T`) fails the **build**
with a message carrying the file path and the parse hint —
previously the Err was silently embedded as data and surfaced only
at the user's `.get()` at runtime.

The `Result[T, ParseError]` return type is preserved for
compositional ergonomics; in a successfully-built binary it's
always `Ok`. The originally-proposed `requireEmbed[T]` variant is
unnecessary now: append `.get` at the call site for the
always-valid-after-init use case.

Regression-guarded by `tests/test_embed.nim`'s `compiles()` checks
against `fixtures/rule_broken.kdl` (does NOT compile) and
`fixtures/rule_simple.kdl` (still compiles).

### `[x]` `Low` — Encode error spans on typed encode are synthetic placeholders

Resolved with a real diagnostic improvement: encode-side
`kdlReserved` failures now carry `TypeName.fieldName` as the hint
prefix (via `prefixEncodeHint` in `codegen.nim`). The span stays
synthetic — there's no source file to anchor to — and that's now
explicitly documented on `encode[T]`. The hint field carries the
useful diagnostic.

### `[—]` `Low` — Pragma vocabulary mixes grammatical forms

Deliberate non-goal. `kdlNode/kdlArg/kdlProp/kdlChild` (nouns)
describe the *shape* the field maps to; `kdlSkip/kdlRename`
(verbs) describe an *action*; `kdlReserved` (adjective) describes
a *property*. These are different grammatical categories because
they're doing different jobs. The spec itself mixes "property"
(noun) and "slashdash" (verb-y); forcing one form is bikeshedding.

### `[x]` `Low` — Internal symbols leaking via `*` export

Resolved by dropping `*` from the macro-reflection internals
that are used only at compile time inside `codegen.nim` itself:
`collectShape`, `VariantBranch`, `VariantSpec`, `TypeShape`.
The decoder error constructors (`mismatchErrAt`, `missingErrAt`,
`enumMismatchErrAt`, `discriminatorErrAt`) stay exported because
the macros emit bare-ident calls into user-scope decoder bodies;
the user's compiled code resolves them by name. `embedAux` stays
exported for the same reason (template `embed*` expands at the
caller, references embedAux in caller scope).

### `[x]` `Low` — Module docstring default mode is stale

`src/encode.nim:4` updated to list emPreserve (default), emPretty,
and emCompact instead of claiming emPretty was the default.

### `[x]` `Low` — codegen.nim's `hasProp` overload lacks a docstring

Resolved as part of Batch C Slice 2 (InternedStr-keyed
disambiguation). The renamed `hasPropInterned` and sibling
`*Interned` helpers now sit under a module-level docstring block
explaining the layer boundary and why the `Interned` suffix is
load-bearing.

---

## Performance

### `[x]` `High` — hashNodeContent allocates a string per entry it hashes

Resolved by redesigning the hash to feed AST structure directly
(kind discriminant + raw payload bytes) instead of routing through
`emitEntry`. Net: zero allocation per entry, and `emitEntry`'s
output format can now evolve without invalidating cached hashes.

Implementation: `Interner.feedHash(handle, h)` folds interned bytes
through `fnv128Update` without materialising a `string`. New
internal helper `feedValue` hashes a `KdlValue` from its variant
fields directly (string length-prefix + bytes; int/float/bool/bigint
as raw byte patterns; null as nothing). `hashEntry` /
`hashNodeContent` are rewritten on top.

### `[x]` `High` — String-keyed accessors call `lookup()` instead of `equals()`

Resolved by mechanical replacement throughout `ast.nim`. The 11
string-comparison sites in `prop`, `hasProp`, `child`, `children`,
`findNode`, `findNodes`, `removeProp`, `removeChild`,
`replaceChild`, `remove`, and `replace` now use
`interner.equals(handle, name)` (zero-alloc) instead of
`interner.lookup(handle) == name` (heap-allocated temp).

### `[x]` `High` — emPreserve re-hashed every subtree on every mutated-doc encode

Resolved by threading the hash through the encode recursion. The
preserving encoder now returns `(text, hash)` per node and computes
each node's hash bottom-up from its children's already-computed
hashes (new helper `hashNodeFromChildHashes`). Each node is hashed
exactly once per encode pass — linear, not quadratic.

Regression guard: `tests/test_preserve.nim` has a test (gated on
`-d:kdlHashStats`) that asserts hash-call count ≤ node count.

### `[~]` `Medium` — Multi-line string lexer allocates three intermediate buffers

Partially resolved with `newStringOfCap(rawBuf.len)` on the
dedented buffer (elides one growth realloc per multi-line string).

**Defended skip on the larger fix.** The BACKLOG claim that
"rawBuf and dedented are identical in the common case" is
structurally inaccurate: `dedented` excludes the closing-prefix
line by design (built from `lines[0..^2]` only) and applies the
whitespace-only-line-collapse rule. The three phases are doing
distinct work — fusing them is a non-trivial restructuring for
marginal gain. If profiling later shows multi-line strings on
the hot path, a phase-2/3 fusion with cursor-based dedent is the
natural next step.

### `[x]` `Medium` — decodeFloatFromToken always allocates an underscore-stripped copy

Resolved. Now scans for `_` first; reuses `tok.numText` directly
when none present, allocates the stripped copy only when needed.

### `[x]` `Medium` — emitNode builds entries into a seq[string] then joins

Resolved. Both `emitNode` and `emitNamePart` write directly into
`result` via `result.add(...)` — no intermediate seq[string],
no `join(" ")` allocation per node.

### `[x]` `Medium` — Generated decoders intern each field-name literal on every decode call

Resolved with a deeper fix than the BACKLOG sketched: the macro now
emits calls to the public `prop(n, doc, name)` / `child(n, doc, name)`
/ `children(n, doc, name)` accessors, which use `interner.equals`
internally. This eliminates BOTH the redundant `intern` AND the
paired two-scan pattern (the old emit called `hasPropInterned` then
`findPropInterned`, walking entries twice). Single byte-comparison
scan per field, zero allocation.

### `[x]` `Medium` — collectTokens called multiple times on the same ParseNode

Resolved by:
- Adding `collectTokensInto(n, buf: var seq[Token])` for hot-path
  callers that already hold a buffer to reuse.
- Pre-sizing the convenience `collectTokens(n)` via
  `newSeqOfCap(n.tokens.len + 1)` — elides the growth realloc that
  fires on the common single-token-leaf case.

The "overlapping subtrees" claim in the original BACKLOG entry was
overstated — call sites operate on distinct match subtrees from
the grammar — but the per-call allocation overhead is real and now
mitigated.

### `[x]` `Medium` — Reserved-keyword check does 6 string comparisons per identifier

Resolved by `isReservedBareword(s)` in `lexer.nim` — does an
`s.len > MaxReservedBarewordLen` (5) prefilter, then a
length-then-bytes match against the 6 entries. Identifiers longer
than 5 chars skip the table walk entirely; the parser + grammar
sites all route through this single helper.

### `[x]` `Low` — Pre-computed indent table eliminates `PrettyIndent.repeat()` allocations

Resolved with a 64-element `const Indents` table indexed by depth.
`indentStr(depth)` looks up the precomputed string when `depth <
PrecomputedIndentLevels` and falls back to `repeat()` beyond
(unreachable in practice — `MaxParserDepth = 256` is the parser cap
and real KDL configs rarely nest past 8). All `emitNode` /
`emitNodePreserve` indent allocations are now zero.

### `[x]` `Low` — decodeEnumFromString allocates `$member` per iteration

Resolved by a `buildEnumCaseImpl` macro that emits a per-enum
`case s of "memberStr": target = E.member` block at instantiation
time. Nim's `case` on `string` lowers to an efficient dispatch
internally; no allocations per call. Honors Nim 2.x's
stringified-value syntax (`akInject = "inject"` → matches "inject");
bare members match their symbol name.

### `[x]` `Low` — Interner inline-entry `lookup` uses `copyMem`

Resolved. The bulk-copy path uses `copyMem` at runtime; a byte-loop
fallback fires under `when nimvm` because `copyMem` is `importc`'d
from C and isn't VM-callable — `embed[T]` runs `lookup` at compile
time and would otherwise error.

### `[ ]` `Low` — Switch to xxh3-128 for node-content hashing

FNV-1a 128 is correct and ~25 LOC; xxh3-128 is ~4× faster at ~150
LOC. Only worth doing if a profiler shows hashing as hot — for
amoxtli's small configs FNV is fine.

Files: `src/fnv.nim`.

---

## Feature gaps

### `[ ]` `Medium` — Pretty-print configurability

Only `emPretty` (4-space) / `emCompact` exist. No knob for indent
width, max line length, sort-children-by-key, etc. Real value for
code-formatter tooling.

**Acceptance:** `EncodeOptions` struct with at minimum indent-width
(`int`, default 4) and maybe-wrap-long-lines threshold. `encode(doc,
mode, opts)`. Tests covering each option.

### `[ ]` `Low` — Diff / merge between two KdlDocs

Useful for config-management tooling (show me what changed between
two configs; apply a patch to a config). Neither lib/kdl nor kdl-rs
ships this today.

**Acceptance:** `diff(a, b: KdlDoc): seq[Patch]` and
`apply(doc: var KdlDoc, patch: Patch): Result[void, ApplyError]`.
Patch semantic TBD — most likely structural (add/remove/replace per
path) rather than textual.

### `[ ]` `Low` — KDL Schema (portable schema files) reader

The KDL Schema spec (separate from KDL itself) defines a KDL-format
*schema file* describing valid documents. We have **strict superset**
coverage at the type level via `deriveDecode` + `kdlReserved` +
`Option[T]` (see "Design choices" below), but a portable schema FILE
that any KDL implementation can read isn't supported.

Real value only if/when there's a need to publish a schema file for
third-party tooling. For amoxtli specifically: no need (we own both
schema and docs).

**Acceptance:** sibling module `lib/kdl-schema` reading the KDL
Schema format and validating arbitrary `KdlDoc` against it.

---

## Design choices (documented non-goals)

The following are decisions we made deliberately. Recorded here so a
future maintainer (us in 6 months, or an external user) doesn't
re-litigate them without knowing the reasoning.

### `[—]` v1 KDL parser mode (we reject v1; spec allows either)

KDL v2 spec says: "the parse will either fail completely, or, if the
parse succeeds, the data represented by a v1 or v2 parser will be
identical". kdl-rs takes the "succeed if v1" route via a feature flag.
We take the "fail completely" route — explicitly reject v1 raw-string
syntax (`r"..."`) and other v1-isms.

**Rationale:** doubling the parser surface for marginal user value.
v1 KDL files are rare (it's been ~2 years since v2 stabilized) and
the migration tool `kdl-fmt --upgrade` exists in the ecosystem. Open
this back up if a real consumer hits v1 input.

### `[—]` KQL (KDL Query Language) — replaced with typed path DSL

Spec marks KQL as "next / unreleased". The Rust reference impl has
KQL tests under `tests/disabled_tests/`. We replaced it with the
compile-time typed-path DSL in `src/path.nim` — refactor-safe field
access via `path(doc, .field.where(it.enabled))`. Compile errors on
typos, IDE-aware, zero runtime cost.

**Rationale:** KQL is a moving target with no working oracle. Our
DSL is strictly safer (compile-time validated) at the cost of being
Nim-only. Re-evaluate if the KQL spec ever lands stably AND a
consumer needs runtime string-keyed queries.

### `[—]` KSL replaced by `deriveDecode` + `kdlReserved` (strict superset)

The (v1) KDL Schema Language and the (v2) KDL Schema are runtime
schema-validation systems. We cover every feature they offer via
type-level pragmas:

| Schema feature | Our equivalent |
|---|---|
| Cardinality 0..1 / 0..N / exactly 1 | `Option[T]` / `seq[T]` / bare `T` |
| Property required / optional | no-default / has-default |
| Value type constraint | Nim type IS the constraint |
| Numeric range | `kdlReserved: "i8"`, `"u32"`, etc. |
| String format (uuid, email, ipv4, …) | `kdlReserved: "uuid"`, etc. |
| Enum literal set | Nim `enum` type |
| Child structure | nested object type |

Strict superset because we also get static refactor-safety,
compile-time validation via `embed[T]`, and IDE field-name completion
that no portable schema file can give you. **Trade-off:** schema
lives in code, not a portable file. See the "KDL Schema (portable
schema files) reader" entry above for the open question of whether to
add the portable-file form.

### `[—]` Streaming / iterator-based parse

Neither lib/kdl nor kdl-rs has this. KDL is config-grade format
(typically &lt;100 KB documents), not stream-grade. The parser holds
the entire token stream in memory.

**Rationale:** the use case doesn't exist for amoxtli (configs and
rules) and adding it would force major refactoring of the
parser-to-AST construction path.

### `[—]` Layer 2 (user-defined reserved tag namespace)

Earlier design considered three layers for reserved-type validation:
- Layer 1 (parse-time, all 40 spec tags) — done
- Layer 2 (user-declared extra tags accepted strictly) — rejected
- Layer 3 (per-field `kdlReserved` pragma) — done

Layer 2 was rejected because Layer 3 + strict-decode covers every
realistic case where catching unknown-tag typos matters. A schemaless
KDL tool (formatter, linter) shouldn't reject custom tags per spec;
a typed-schema consumer catches typos via the field-level pragma.
The "untyped consumer that wants typo detection" persona was
classified as incoherent.

### `[—]` Path / cursor API for emPreserve dirty propagation

Considered for tracking per-node dirty bits with ancestor
propagation. Rejected in favor of FNV-1a 128 per-node freshness
(deriving freshness at encode time rather than tracking it
eagerly). The cursor approach requires either parent pointers (don't
compose with value semantics) or a `KdlCursor` type holding doc + path
indices (forces a parallel API alongside bare mutators). The
hash-based approach has zero API churn and works for arbitrary
mutation patterns including raw field access.

**Trade-off recorded:** the FNV approach pays O(N) on every
mutated-doc encode. For tight edit-encode loops this matters; for
amoxtli's parse-edit-write workflow it doesn't. If a profiler ever
shows it hot, the refinement is the per-node dirty bit (Performance →
"emPreserve re-hashes" item above).

### `[—]` Option[seq[T]]

The macro rejects `Option[seq[T]]` at deriveDecode time with a clear
error message. `seq[T]` already represents "zero or more"; wrapping
in Option adds "present-but-empty vs absent" which has no analog in
KDL (an absent child IS an empty seq).

**Rationale:** removes a confusing pattern that has no useful
encoding. If someone wants the distinction, they can model it
explicitly (e.g., a wrapper object with an `inhabited: bool` field).

---

## Done — kept for traceability

- `[x]` Full KDL v2 spec coverage — 338/338 corpus
- `[x]` All 40 reserved-type validators (parse-time Layer 1)
- `[x]` `kdlReserved` pragma (Layer 3) for typed schemas
- `[x]` `deriveDecode[T]` / `deriveEncode[T]` symmetric round-trip
- `[x]` `Option[T]` field support for primitives, enums, objects
- `[x]` Type-level `kdlReserved` pragma (top-level node tag)
- `[x]` String-keyed convenience accessors
- `[x]` Builder / mutation API with positional insert + arg ops
- `[x]` `parseAll` multi-error reporting (node + entry level recovery)
- `[x]` `emPreserve` byte-lossless round-trip
- `[x]` FNV-1a 128 per-node content freshness
- `[x]` Encode-side reserved-type validation (Layer 1 symmetric)
- `[x]` 128-bit integer support (`kvBigInt`)
- `[x]` Byte-equivalence conformance harness (243 positive cases)
- `[x]` Differential testing (hand parser vs grammar.nim reference interpreter)
- `[x]` Compile-time decode (`embed[T]` runs full chain in Nim VM)
- `[x]` Typed path DSL with compile-time field validation
