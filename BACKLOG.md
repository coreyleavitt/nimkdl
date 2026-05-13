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

### `[ ]` `Medium` — Raw field mutation bypasses emPreserve silently

`encode(doc, emPreserve)` fast-paths to `return doc.sourceText` when
`doc.mutated == false`. A caller mutating via raw field access
(`doc.nodes[0].entries[1] = ...`) skips `markMutated` and the encoder
returns stale source bytes. Builder helpers all call `markMutated`
correctly; the risk is field-access patterns.

**Fix:** add a `when not defined(release)` doc-level hash sanity check
that recomputes a total hash and panics on mismatch when
`mutated == false`. OR add a prominent warning comment to the
fast-path branch naming this failure mode.

Files: `src/encode.nim:289-290`, `src/ast.nim:441-447`.

### `[ ]` `Medium` — validateDecimal passes dead exponent-range parameters

`validateDecimal` calls `validateDecimalFormat(v, "decimal",
maxDigits = -1, expLow = 0, expHigh = 0)`. The range checks are
guarded by `if maxDigits > 0`, so the `expLow = 0` / `expHigh = 0`
arguments are intentionally dead. A future maintainer flipping the
precision to a positive value will silently apply the wrong range.

**Fix:** early-return on `maxDigits < 0` at the top of
`validateDecimalFormat`, drop the dead parameters from
`validateDecimal`'s call site OR use `int.low` / `int.high` sentinels.

File: `src/reserved.nim:1102-1103`.

### `[ ]` `Low` — KdlValue.== compares typeAnnotation handles unsafely across docs

`KdlValue.==` does `a.typeAnnotation != b.typeAnnotation` directly on
the `InternedStr` (uint32) handle. Values from different documents
with different interners may have the same handle pointing to
different strings. `KdlNode.==` documents this caveat;
`KdlValue.==` doesn't.

**Fix:** add the cross-doc warning to the `KdlValue.==` doc comment,
and add a `valueEqual(aDoc, bDoc, a, b)` parallel to the existing
`nodeEqual` / `docEqual`.

File: `src/ast.nim:211-223`.

### `[ ]` `Low` — setProp / addArg / setArg don't re-intern cross-doc value annotations

These mutators intern the property NAME via the local doc's interner,
but if the supplied `KdlValue` carries a `typeAnnotation` interned in
a DIFFERENT doc, the resulting `KdlNode` holds a mix of handles. The
encoder will then call `interner.lookup` with the wrong interner and
produce wrong output silently.

**Fix:** the cross-doc value mutator should re-intern
`v.typeAnnotation` against the local interner, OR `assert` that
incoming values carry `InvalidInterned` or were minted from the same
doc.

File: `src/ast.nim:514-526`.

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

### `[ ]` `High` — decode[T] has no decodeAll[T] equivalent for typed multi-error

`parseAll` exists for the untyped layer; `decode[T]` doesn't have a
matching multi-error variant. The typed layer therefore stops at the
first error. Inline comment in `codegen.nim` (line 106-107)
acknowledges this gap explicitly.

**Fix:** add `decodeAll[T](source, sourcePath): tuple[value: T,
errors: seq[ParseError]]` matching `parseAll`'s contract at the
typed level.

File: `src/codegen.nim:106`.

### `[ ]` `Medium` — encode[T] has no EncodeMode parameter

Typed `encode[T](v)` always produces canonical (emPretty) output.
There is no way to compact-encode a typed value.

**Fix:** add optional `mode = emPretty` parameter — OR expose
`encodeNode[T](v): Result[KdlNode, ParseError]` so callers can
assemble the doc and choose mode.

File: `src/codegen.nim:1225`.

### `[x]` `Medium` — Doc-level `remove` / `replace` drop the qualifier

Resolved by renaming `remove(doc, name) → removeNode(doc, name)` and
`replace(doc, name, repl) → replaceNode(doc, name, repl)` in
`ast.nim`. Symmetric with `removeChild`/`replaceChild` at the node
level.

### `[x]` `Medium` — `kdlAttr` pragma vs `prop` accessor — vocabulary mismatch

Resolved by renaming `{.kdlAttr.}` → `{.kdlProp.}` throughout codegen,
tests, and README. No alias; per `no_pre_1_aliases` policy.

### `[ ]` `Medium` — Find-vs-bare verb inconsistency between node-level and doc-level accessors

Node-level: `child(n, doc, name)` / `children(n, doc, name)`.
Doc-level: `findNode(doc, name)` / `findNodes(doc, name)`. Same
semantic, different verb family.

**Fix:** rename to one of two options:
- `findChild` / `findChildren` at the node level
- `node` / `nodes` at the doc level

### `[x]` `Medium` — Missing `getArg` / `arg(n, idx)` reader

Resolved together with the "findArg moves to ast" item above. New:
`arg(n, idx): KdlValue` and `hasArg(n, idx): bool` in `ast.nim`.

### `[ ]` `Medium` — embed[T] docstring overclaims

The docstring says `embed[T]` validates at compile time, but the
return type is `Result[T, ParseError]` which implies fallibility
at the call site. Either commit to "compile-time guaranteed; returns
T directly" (with a build error on malformed input) OR re-word the
docstring to say "validates at module init; returns Result".

**Fix:** add a `requireEmbed[T]` variant that panics on init failure
for the always-valid-after-init use case, and clarify the docstring.

File: `src/codegen.nim:1293`.

### `[ ]` `Low` — Encode error spans on typed encode are synthetic placeholders

`encode[T]` errors carry `pointSpan(StartPosition)` — line 1:1 with
no useful location info. Decode errors carry real spans. Not wrong
(the encode error is about a Nim value, not a source file) but the
asymmetry is undocumented.

**Fix:** document on `encode[T]` that span info is synthetic; the
`hint` field is the useful diagnostic.

### `[ ]` `Low` — Pragma vocabulary mixes grammatical forms

`kdlNode/kdlArg/kdlAttr/kdlChild` (nouns), `kdlSkip/kdlRename`
(verbs), `kdlReserved` (adjective). Align to one form (nouns or
adjectives — `kdlOmit`/`kdlIgnore` for skip, `kdlName` for rename).

### `[ ]` `Low` — Internal symbols leaking via `*` export

These should not be in the public surface:
- `embedAux` (template plumbing — `codegen.nim:1270`)
- `collectShape`, `VariantBranch`, `VariantSpec`, `TypeShape`
  (macro-reflection internals — `codegen.nim:501-515`)
- `mismatchErrAt`, `missingErrAt`, `enumMismatchErrAt`,
  `discriminatorErrAt` (decoder helper constructors —
  `codegen.nim:108-125`)

**Fix:** drop `*` from each. If any are needed for `-d:dumpKdlGen`
debugging, surface that conditionally.

### `[ ]` `Low` — Module docstring default mode is stale

`src/encode.nim:4` says `emPretty (default)` but the actual default is
`emPreserve`. One-line fix.

### `[ ]` `Low` — codegen.nim's `hasProp` overload lacks a docstring

File: `src/codegen.nim:267-269`.

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

### `[ ]` `Medium` — Multi-line string lexer allocates three intermediate buffers

`lexRegularOrMultiline` builds `rawBuf` (phase 1), `dedented`
(phase 2), and `decoded` (phase 3) for `"""..."""` strings. For the
common case (no whitespace escapes), `rawBuf` and `dedented` are
identical — a copy is wasted.

**Fix:** detect "no whitespace escapes" during phase 1 and skip
phase 2.

File: `src/lexer.nim:671-815`.

### `[ ]` `Medium` — decodeFloatFromToken always allocates an underscore-stripped copy

`decodeFloatFromToken` does `for c in tok.numText: if c != '_':
clean.add(c)` unconditionally, even when the source has no
underscores (most cases).

**Fix:** scan first; allocate only if underscore present.

File: `src/numlit.nim:198-207`.

### `[ ]` `Medium` — emitNode builds entries into a seq[string] then joins

`var parts = @[...]; for e in n.entries: parts.add(emitEntry(...));
result = pad & parts.join(" ")`. N+2 heap allocations per node.

**Fix:** replace with direct `result.add()` calls.

Files: `src/encode.nim:196-199`, `src/encode.nim:246-249`.

### `[ ]` `Medium` — Generated decoders intern each field-name literal on every decode call

`codegen.nim:724` emits `let keyIdent = docIdent.interner.intern(
kdlNameStr)` per field per decode. The literal is constant; the
intern is wasted work.

**Fix:** use `interner.equals(handle, literal)` in the generated
lookup paths instead of `intern + compare`.

### `[ ]` `Medium` — collectTokens called multiple times on the same ParseNode

Reference interpreter path: `collectTokens` allocates a fresh
`seq[Token]` per call. Called by `buildValue`, `buildEntry`,
`buildNode` repeatedly on overlapping subtrees.

**Fix:** memoize via a cache OR pass a preallocated buffer.

File: `src/grammar.nim:552-554`.

### `[ ]` `Medium` — Reserved-keyword check does 6 string comparisons per identifier

`identStr in ReservedBarewords` (length-6 array of literal strings)
fires on every ident lookup in parser + grammar paths.

**Fix:** intern the 6 keywords at interner init and compare handles,
OR length-prefilter (max reserved length is 5).

Files: `src/parser.nim:152,220,306`, `src/grammar.nim:609,836,843`.

### `[ ]` `Low` — Pre-computed indent table would eliminate `PrettyIndent.repeat()` allocations

`emitNode`'s recursive descent calls `"    ".repeat(indent)` per
level. A `const Indents = ["", "    ", "        ", ...]` would
eliminate all small string allocations.

Files: `src/encode.nim:191`, `src/encode.nim:265`.

### `[ ]` `Low` — decodeEnumFromString allocates `$member` per iteration

The runtime enum-string match does `if $member == s` per member
of the enum, one allocation per iteration.

**Fix:** macro-generate a `case s of "..." : target = E.x` instead.

File: `src/codegen.nim:196-201`.

### `[ ]` `Low` — Interner inline-entry `lookup` could `copyMem`

For inline (≤22-byte) entries, `lookup` walks bytes byte-by-byte
into a `newString`. A `copyMem` would be marginally faster.

File: `src/intern.nim:147-151`.

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
