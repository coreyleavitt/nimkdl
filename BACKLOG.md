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

### `[ ]` `High` — emPreserve: preserved children inside a modified parent lose indentation

When `emitNodePreserve` recurses into children of a dirty parent, an
unmodified child returns its source bytes verbatim. The source span
starts at the child's first token (no leading whitespace), so the
reconstructed parent block shows children flush-left.

**Fix:** prepend `PrettyIndent.repeat(indent + 1)` before each
preserved-child's source bytes, OR fall back to canonical for all
children whenever the parent itself is dirty (simpler, less code).

File: `src/encode.nim:262-275`.

### `[ ]` `High` — emPreserve: preserved nodes produce spurious blank lines

`KdlNode.span.finish.offset` is set to `p.peek.span.start` after the
node's terminator is consumed (parser.nim:450), so the span already
includes the trailing newline. `encode()` then calls
`parts.join("\n")` and inserts a SECOND newline between siblings.
Output stays syntactically valid but is no longer byte-stable.

**Fix:** strip trailing newline from preserved source bytes before
appending, OR record `span.finish.offset` at the position just before
the terminator.

Files: `src/encode.nim:289-296`, `src/parser.nim:450`.

### `[ ]` `Medium` — parseAll: node-level error inside a children block inflates error count

When a node-level error fires inside `{ ... }`, `parseChildren`
propagates Err up. `skipToRecovery` stops at `tkRBrace` without
consuming it; the forward-progress guard then force-advances past `}`,
treating the closing brace as a stolen separator. For nested children
blocks this generates one spurious "expected node name" error per
nesting depth, and the partial doc loses all well-formed siblings of
the failed node within the same block.

**Fix:** teach `skipToRecovery` to consume balanced `{...}` pairs
(brace-depth counter; advance past `}` only when depth reaches zero),
OR give `parseChildren` its own accumulating loop matching
`parseDocumentAccumulating`.

Files: `src/parser.nim:454-473`, `src/parser.nim:497-508`.

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

### `[ ]` `High` — encode(doc) is infallible; encode[T](v) is fallible — same name, opposite contracts

`encode(doc: KdlDoc)` returns `string`. `encode[T](v: T)` returns
`Result[string, ParseError]` (it can fail Layer-1 reserved-type
content validation). Overload resolution picks the right one by
argument type, but a reader skimming the API will not see both
signatures together — same name, opposite contracts.

**Fix:** rename the typed variant `encodeTyped[T]` or `encodeAs[T]`.

Files: `src/encode.nim:274`, `src/codegen.nim:1225`.

### `[ ]` `High` — Two overlapping `hasProp` overloads with incompatible key types

`ast.nim:398` exports `hasProp(n, doc, name: string): bool` (string
key, public API). `codegen.nim:267` exports `hasProp(n, key:
InternedStr): bool` (interned key, used by generated decoders). Same
name, same type, no docstring on the boundary.

**Fix:** rename the InternedStr variant `hasPropInterned` and document
that user code should always use the string variant.

Files: `src/ast.nim:398`, `src/codegen.nim:267`.

### `[ ]` `High` — parseAll returns a tuple; parse returns a Result — asymmetric

`parse → Result[KdlDoc, ParseError]` vs `parseAll → tuple[doc:
KdlDoc, errors: seq[ParseError]]`. These cannot be pattern-matched
uniformly; helpers that want to "parse and handle errors" must branch
on which entry point was used. The tuple shape also has no way to
indicate "fully successful" without checking `errors.len == 0`
separately.

**Fix:** `parseAll` should return `Result[KdlDoc, seq[ParseError]]`
or a named object type.

File: `src/parser.nim:562`.

### `[ ]` `High` — `prop` / `findProp` and `child` / `findChild` are different verbs for the same operation at different modules

`ast.nim` exports `prop(n, doc, name)` (string-keyed user API).
`codegen.nim` exports `findProp(n, key: InternedStr)` (interned-key
internal helper). Same semantic, different name. Same story for
`child` vs `findChild`. A new reader has no way to know which to call.

**Fix:** pick one family. Recommend `find*` for both string-keyed and
interned-keyed flavors, with the interned variant living under an
internal namespace.

Files: `src/ast.nim:390-395`, `src/codegen.nim:262-272`.

### `[ ]` `High` — findArg is exported from codegen.nim with no ast.nim counterpart

`findArg(n, idx): KdlValue` is publicly exported from `codegen.nim`
but conceptually belongs to `ast.nim` next to `prop` and `child`.
Users importing only `ast` lose access to positional-argument lookup.

**Fix:** move `findArg` / `hasArg` to `ast.nim` and rename
consistently (e.g. `arg(n, idx)` / `hasArg(n, idx)`).

File: `src/codegen.nim:247`.

### `[ ]` `High` — Sentinel-node return is undocumented and asymmetric with `hasProp`

`child(n, doc, name)` and `findNode(doc, name)` return
`KdlNode(name: InvalidInterned)` as the "not found" sentinel. The
sentinel pattern isn't documented on either; only `findChild` mentions
it. Meanwhile `hasProp` exists for properties, so the asymmetry
across families is jarring.

**Fix:** add `hasChild(n, doc, name)` and `hasNode(doc, name)` —
OR switch all three to `Option[KdlNode]`.

Files: `src/ast.nim:405-422`.

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

### `[ ]` `Medium` — Doc-level `remove` / `replace` drop the qualifier

Node-level: `removeChild`, `removeProp`, `removeArg`. Doc-level:
`remove`, `replace` — bare, no `Node` suffix. Should be `removeNode`,
`replaceNode` for symmetry.

File: `src/ast.nim:584-602`.

### `[ ]` `Medium` — `kdlAttr` pragma vs `prop` accessor — vocabulary mismatch

Pragma is `{.kdlAttr.}` (attribute) but the spec + accessors use
"property" throughout (`prop`, `setProp`, `removeProp`, `hasProp`).
Rename `kdlAttr` → `kdlProp`.

File: `src/codegen.nim:74`.

### `[ ]` `Medium` — Find-vs-bare verb inconsistency between node-level and doc-level accessors

Node-level: `child(n, doc, name)` / `children(n, doc, name)`.
Doc-level: `findNode(doc, name)` / `findNodes(doc, name)`. Same
semantic, different verb family.

**Fix:** rename to one of two options:
- `findChild` / `findChildren` at the node level
- `node` / `nodes` at the doc level

### `[ ]` `Medium` — Missing `getArg` / `arg(n, idx)` reader

Builder API has `addArg` / `setArg` / `removeArg` but no positional
reader. Users must iterate `arguments` or reach into the codegen-only
`findArg`.

**Fix:** add `arg(n, idx)` / `hasArg(n, idx)` to `ast.nim` to match
the `prop` / `hasProp` family.

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

### `[ ]` `High` — hashNodeContent allocates a string per entry it hashes

`hashNodeContent` calls `emitEntry` to produce a throwaway string,
then hashes its bytes. For a node with 10 entries this is 10 heap
allocations per call. The hash is called once per node at parse and
again per node inside `emitNodePreserve` on every mutated-doc encode.

**Fix:** add a `hashEntryDirect` proc that feeds interner bytes and
entry bytes directly via `fnv128Update` without the intermediate
string.

File: `src/encode.nim:234`.

### `[ ]` `High` — String-keyed accessors call `lookup()` (heap-allocating) instead of `equals()` (zero-alloc)

`prop`, `hasProp`, `child`, `children`, `findNode`, `findNodes`,
`remove`, `replace`, `removeProp`, `removeChild`, `replaceChild` all
call `doc.interner.lookup(handle) == name`. `lookup` allocates a
fresh string per call. The interner exposes `equals(handle,
openArray[char])` which compares without allocating; none of the
string-keyed APIs use it.

**Fix:** mechanical replacement throughout `ast.nim`.

Files: `src/ast.nim:390-422`, `src/ast.nim:514-602`.

### `[ ]` `High` — emPreserve re-hashes every subtree on every mutated-doc encode

`emitNodePreserve` calls `hashNodeContent` unconditionally per node.
Recursive: a node with 5 children × 5 entries hashes all 25 entries
on every encode. In an edit-encode loop, every untouched sibling gets
re-hashed to confirm it didn't change.

**Fix:** add a per-node dirty bit (or reuse `parseHash == zeroHash`
as the sentinel for freshly-constructed nodes) and skip the hash
recompute when the bit indicates clean. The path-API alternative was
considered and rejected (see Design choices below).

File: `src/encode.nim:262`.

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
