# RFC: nkdl core rebuild — self-contained AST + per-category API

**Status:** **LANDED + COMMITTED (2026-06-03)** — the cutover is complete and verified.
The self-contained owned-string core is live; the interned core
(`ast`/`intern`/`doc_build`/`doc_emit`/`hashing`) is deleted. Built via a strangler
migration (parallel pipeline kept continuously green, then cut over). Foundation =
**owned strings (O)**; SSO measurement (Stage-0) deferred — plain-O shipped (the RFC's
take-on-tie default). Committed on `core-rebuild` (`776bff2` the rebuild, `7af6e96`
field-path; not pushed). **Default suite `nimble -y test` EXIT=0 (conformance 338/338,
byte-exact preserve 243/0); gated `NKDL_PROPTEST=1 nimble test` EXIT=0, 710 OK** (the
full property tier rebuilt onto the new core).
**Done post-cutover:** property-suite migration (P1–P12); §8.7 — name-preserving slot
inference, `uint`, `eqIdent`, >64-field guard, field-path errors; stable
`ParseErrorCode`. `encode(doc)` defaults canonical (settled).
**Remaining (finicky §8.7 polish, diminishing returns):** `ckOption` (Option[object]
child — `nodeNameOf` needs inner→sym resolution), `ckRef`, `kdlScalar` + mixin
`kdlDecodeValue`, leaf-field path enrichment, `$fieldType`→`getTypeImpl` dispatch, and
partial-splice preserve under mutation.
**Date:** 2026-06-03 (R3 review folded)
**Supersedes:** the *substrate* sections of `rfc-api-v0.2-hardening.md` (F.0–F.6,
§2.5 C0-x, the `ownerDocument`/`adopt`/ref-vs-arena material). That RFC's **API
surface** (§6, §8.1) survives as input to this one — see §13. At SJ,
`rfc-api-v0.2-hardening.md` gets a header redirect to this RFC as single source
of truth.
**Seeds / inputs:** `docs/core-rebuild-summary.md` (decision record + design goals
+ two depth reviews), plus a third five-lens review (R3) whose findings are folded
throughout and called out inline as **[R3]**.

---

## 1. Summary

nkdl's storage core is **interner-first + handle-based**: a `KdlNode` stores
`InternedStr` handles resolvable only against some doc's interner. The v0.2
hardening targeted a **doc-free, self-contained, cross-doc-safe** API and had to
bolt an `ownerDocument` back-reference onto every node — creating a doc↔node ORC
cycle and a **+61% parse regression** (§2).

This RFC **rebuilds the DOM core around self-contained nodes** — a `KdlNode` owns
its name and property keys as plain strings, exactly as `KdlValue` already owns its
`strVal` — so doc-free accessors, cross-doc safety, and cycle-free layout fall out
*by construction*, with no interner, no `ownerDocument`, no `adopt`. The **proven
periphery is ported in, not re-derived**: lexer, numlit, grammar, cursor, emitter,
the conformance corpus, and the Lean proofs are kept; only the AST core
(`ast`/`doc_build`/`doc_emit`/`hashing`) and the conformance adapter are rebuilt.
The typed codegen's **dispatch path is rebuilt** (replacing `$fieldType`
string-switching with `getTypeImpl`-resolved dispatch) while its module surface and
test suite are preserved — same "port the periphery, rebuild the core" model as the
AST, applied to the macro. (**[R3]**: "finish not rewrite" was optimistic framing —
§8.7 is a dispatch rewrite, scoped below.)

The work runs on a **fresh branch**, **measure-first** (Stage 0 measures whether SSO
pays), with a **monotonic green-net** and a triaged test suite.

---

## 2. Motivation

The substrate fought the goals. To make `n.name` doc-free over interned handles we
added `ownerDocument: ref KdlDoc`, which cascaded into `adopt` (O(subtree)
re-interning on cross-doc insert), `equalsAcross`, and a doc↔node reference cycle
(`ast.nim:130–131`, `==` reaching into `ownerDocument.interner` at `ast.nim:311`).

Parse-to-DOM regression (min-of-5, same container):

| build | µs/parse | vs F.1 |
|---|---|---|
| F.1 (interner, ref-AST, no `ownerDocument`) | 126 | — |
| F.3 (`ref ownerDocument` + `Option[string]` value anno) | 203 | **+61%** |
| F.3 + `{.cursor.}` ownerDocument (diagnostic; unsound) | 155 | +23% |

`{.cursor.}`/`ptr` recover the cycle cost but are **unsound** — a non-owning back-ref
dangles the instant a node outlives its doc (the common
`let n = parse(s).get.node("x")` pattern). **The lesson:** we already solved this
correctly for *values* (owned `strVal` + `Option[string]` annotation → doc-free,
cross-doc-safe, adopt-free, cycle-free). Do the same for *nodes*. (These numbers are
pre-rebuild wall-clock and are re-measured by the corrected Stage-0 method, §5.4 —
they motivate the rebuild; they do not set its acceptance bar.)

---

## 3. Design principles

The project's D1–D6 doctrine, plus the founding axiom:

- **D1 — errors are self-sufficient values** (`$err` renders `path:line:col:` with no
  re-passed source).
- **D2 — the no-raise boundary is real** (public entries `{.raises:[].}` or a
  documented residual; see the `canPreserve` resolution in §9.3).
- **D3 — fail loud, never silently wrong.**
- **D4 — one source of truth for cross-cutting logic** (`fieldInfo`, pragma parsing,
  field iteration exist once — `derive_common`).
- **D5 — design the interface for the ideal end state**, then build to it.
- **D6 — consistent by construction, not by differential test.**
- **Self-containedness (axiom):** an AST node/value owns all bytes it needs to render
  and compare. No node depends on an external table (interner) or a back-reference
  (doc). **[R3]**: with foundation O this axiom now holds *unconditionally* — including
  detached nodes (`newNode` with no doc) and cross-doc `==`. (The earlier candidate
  foundation B — a shared per-doc byte blob — was dropped precisely because it could
  not satisfy this axiom for detached nodes or cheap cross-doc equality without
  reintroducing a doc dependency; see §5.3.)

---

## 4. Non-goals

- **Backwards compatibility.** No deployed consumer exists. milpa is *not* an nkdl
  consumer (own Python KDL parser). amoxtli hit a wall and has not adopted; whether it
  adopts later remains a goal, and the `decodeNode(doc,node)` signature change (§8.1,
  reversing the hardening RFC's no-doc promise) is a deliberate, announced correction.
  The contract is this RFC's API surface, not any call sites.
- **A from-scratch rewrite.** The lexer, numlit, grammar, cursor, emitter, corpus, and
  Lean proofs are proven and ported in (unchanged or mechanically adapted).
- **Cross-document identifier dedup.** Cross-doc safety is achieved by *owning* bytes,
  not sharing storage; arena-with-global-dedup is rejected on that basis.
- **A query language in core.** KQL is an unreleased `next` draft, superseded for
  in-process use by the Nim-native typed traversal (§9.4); deferred to an optional
  module.

---

## 5. Substrate — self-contained nodes (foundation O; SSO measured)

### 5.1 The model

`KdlNode`/`KdlDoc` stay **`ref`** (mutate-through reads return the live node; `nil` =
absent). Names, type annotations, and property keys are **owned strings**, not
interned. Consequences, all by construction:

- doc-free accessors (`n.name`, `n.prop("x")`, …) — the name is a field, no `doc`
  param, no lookup;
- `==` is a structural string compare — cross-doc-correct, no `equalsAcross`, no copy;
- detached `newNode("x")` is fully self-contained — the headline mutation ergonomic;
- cross-doc insert is a no-op — no `adopt`, no foreign-handle footgun;
- no doc↔node cycle — `--mm:arc`-safe.

The interner is **deleted**.

### 5.2 Foundation O — owned strings (the design)

```nim
type
  KdlValue* = object              # lives in value.nim — the shared leaf (§6)
    typeAnnotation*: Option[string]      # none / some("") / some("x")
    case kind*: KdlValueKind
    of kvString: strVal*: string
    of kvInt:    intVal*: int64
    of kvBigInt: bigHi*, bigLo*: uint64; bigNegative*: bool
    of kvFloat:  floatVal*: float
    of kvBool:   boolVal*: bool
    of kvNull:   discard
    # no span here — parse spans live in the per-node/per-entry sidecar (§5.5)

  KdlEntry* = object
    case kind*: KdlEntryKind
    of keArgument: argValue*: KdlValue
    of keProperty: propKey*: string; propValue*: KdlValue

  KdlNode* = ref object
    name*: string                        # owned; doc-free
    typeAnnotation*: Option[string]
    entries: seq[KdlEntry]               # NOT public-mutable (§9.2)
    childNodes: seq[KdlNode]             # NOT public-mutable
    dirty*: bool
    meta*: ref NodeMeta                  # nil unless preserveFormat (§5.5)

  KdlDoc* = ref object
    sourcePath*, sourceText*: string
    preserveFormat*: bool
    tokens*: ref TokenStream             # retained only when retainTokens=true (§5.5)
    rootNodes: seq[KdlNode]
```

**Target struct-size table** (64-bit; `string`=16, `Option[string]`=24 incl. flag+pad,
`seq`=16, `ref`=8) — **[R3] the seed required this before coding; it is the SA
acceptance bar**:

| field | bytes | | field | bytes |
|---|---|---|---|---|
| `KdlNode.name` | 16 | | `KdlValue.typeAnnotation` | 24 |
| `.typeAnnotation` | 24 | | `.kind` + largest branch (`bigHi/Lo/neg`) | 17→24 |
| `.entries` | 16 | | **KdlValue total** | **~48** |
| `.childNodes` | 16 | | | |
| `.dirty` | 1→8 | | | |
| `.meta` | 8 | | | |
| **KdlNode payload** | **~88** | | | |

SA must land within ±1 word of this or document the divergence. (The point of the
table: the owned-string layout otherwise gets designed accidentally.)

### 5.3 The Stage-0 question — plain O vs O+SSO

The only open variable. O always heap-allocates a `string`, even for `"x"`. The
interner's `InlineCapacity = 22` (`intern.nim:40`) tells us the overwhelming majority
of KDL identifiers are ≤22 bytes — so a manual SSO that inlines short names and
heap-allocates long ones could remove most per-identifier allocations **while keeping
full self-containedness** (an SSO name is owned bytes, detach-safe, no doc):

```nim
type KdlStr* = object            # 24 bytes; tagged union, fully owned
  case inline: bool
  of true:  ibytes: array[22, byte]; ilen: uint8
  of false: heap: string
# accessor returns openArray[char] / string; `==` is cmpMem on the inline case
```

This is the only candidate that addresses O's allocation profile without
compromising the §3 axiom. (**[R3]**: the rejected foundation B — a per-doc byte blob
with `(offset,len)` node slices — looked attractive on allocations but **could not
serve a detached `newNode` or cheap cross-doc `==`** without a back-ref/doc-param/
per-node micro-blob, i.e. it structurally violated the axiom the rebuild exists to
establish. SSO captures B's win — zero alloc for short idents — without B's cost.)

### 5.4 The Stage-0 measurement gate

Decides plain-O vs O+SSO. **[R3] allocation count is the co-primary metric, not a
secondary** — allocation pressure is the entire reason to consider SSO; an
instruction-count-only gate measures the wrong thing.

- **Tooling:** **allocation count** (massif / `getOccupiedMem` delta) **and** callgrind
  instruction count, co-primary; RSS secondary.
- **Fixtures (≥3):** `homogeneous-services-100.kdl`, `realistic-config.kdl`, and a new
  `mixed-names-200.kdl` (~200 nodes, ~30 distinct names — the adversarial case).
- **Comparison:** head-to-head **plain-O vs O+SSO**, both benched the same way (not
  vs the broken current baseline — the pre-work isolation handles regression
  attribution separately, §16).
- **Rule:** SSO must show a **measurable allocation reduction on `mixed-names-200`**
  *and* be within ±20% on instructions to justify its complexity. **On a tie, take
  plain O** (simpler). If SSO doesn't reduce allocations on the adversarial fixture,
  its rationale collapses → plain O.
- **Artifact:** `docs/stage0-measurement.md` records the winner + numbers.

### 5.5 Parse-metadata sidecar — per-node identity, never positional

`span`, `parseHash`, `headLen`, `parseEntryCount`, `parseChildCount` (node-level) and
the entry-level `span`/`parseHash`, plus the doc-level `parseTopLevelCount`, are
**parse-only metadata** used only on the preserve + error paths. They move **off** the
hot `KdlNode`/`KdlValue`/`KdlEntry` structs into a **per-node `ref NodeMeta`**
(`KdlNode.meta`, nil unless `preserveFormat=true`) and a per-doc `DocMeta`. **[R3]
CRITICAL: the metadata is keyed by node identity, NOT by a DFS-position array.** A DFS
array breaks under `insertChild`/`removeChild` — every shifted clean sibling would
read the wrong metadata and preserve would emit silently-wrong bytes. Per-node `ref
NodeMeta` travels *with* the node through any structural mutation, so the preserve
path stays correct by construction (and a mutated node simply has `dirty=true`, so its
`meta` is ignored and it re-emits canonically). This also keeps the hot node one
pointer larger only, allocating `NodeMeta` lazily.

`doc.mutated` is **removed**; doc-level preservability is lazy:
`canPreserve(doc) = doc.preserveFormat and doc.sourceText.len > 0`. Per-node `dirty`
stays (set by every mutator, which always has the node in hand). With identity-keyed
metadata, **no `metaStale` flag is needed** — there is no positional index to
invalidate.

**Token retention.** `decodeNode(doc,node)` needs the doc's token stream. Tokens are
retained (`KdlDoc.tokens`, a `ref TokenStream`) **only when `retainTokens=true`** is
passed to `parse` — opt-in, like `preserveFormat`, because for a large file the token
stream is large. `decode[T]`/`decodeAll[T]` (whole-doc) don't need it; only the
node-targeted `decodeNode`/`decodeChild` path does.

---

## 6. Keep / rebuild / adapt boundary

Verified against the real import DAG (acyclic). **[R3] correction:** `ast` has **10
import sites, 1 dead (`cursor`'s `import ./ast` is unused), 9 live dependents.**

- **REBUILD (design work):** `ast`, `doc_build`, `doc_emit`,
  **`conformance/adapters/nkdl.nim`** (interner-coupled — the corpus + Lean proofs
  themselves are untouched).
- **NEW:** **`value.nim`** — extract `KdlValue`/`KdlEntry` (the shared low-level leaf)
  out of `ast.nim` so **Cat-1 (`cursor.resolveValue`), Cat-2 (codec), and Cat-3 (DOM)**
  all depend on the leaf, not on the Cat-3 tree (**[R3]**: `resolveValue` otherwise
  makes Cat-1 depend on Cat-3). `token_text.nim` — extract `tokenAsString`
  (`doc_build.nim:42`, uses only `Token`/`TokenStream`/`string`) to cut the
  `derive_decode → doc_build` edge.
- **ADAPT (mechanical, no design):** `emitter` (drop `appendInternedAnno` + the 3
  `InternedStr` overloads); `cursor` (**drop *two* dead imports: `./intern` and
  `./ast`**; add `resolveValue`/`resolveNodeName`/`resolvePropKey`, `depth()` proc in
  the concept); `grammar` (swap ~8 handle reads in `resolveName`/`resolveEntry`/`mapDoc`
  for string reads — narrow, mechanical); `hashing` (**[R3] ADAPT not REBUILD** —
  field-rename port + FNV→word-at-a-time/xxh3 swap gated `when not nimvm:`);
  `derive_decode`/`derive_encode` (the §8.7 dispatch rebuild + `token_text` edge);
  `pragmas` (**[R3] KEEP→ADAPT** — must *add* `kdlArgs`, `kdlScalar`, `kdlIgnoreUnknown`,
  `kdlRenameAll`); `api` (`decodeNode(doc,node)`, `Parsed[T]`); `nkdl`/`parser`/`reserved`.
- **KEEP (verbatim):** `lexer`, `numlit`, `spans`, `fnv`, `spec_literals`, `path`
  (rename → `typed_path`, Cat-2), the conformance corpus, the Lean proofs,
  `kdl_block`.

---

## 7. Category 1 — streaming cursor (foundation, minimal surface)

Keep the **pull cursor** (`advance`/`peek`/`skip`/`pos`/`seek`/`depth`). Changes:

- **Fix `skip()` swallowing `ceError` in `cmAccumulating` mode** (`cursor.nim:707` —
  `of ceEof, ceError: return` is unconditional; in accumulating mode a `ceError` inside
  a skipped node returns without consuming `ceNodeEnd`, corrupting `depth`/`nodeFrames`
  for all later events). Fix: in accumulating mode absorb `ceError`, keep skipping; only
  `ceEof` terminates early. **Lands at SG′, before Cat-2 features.**
- Add **`depth*(c): int`** as a proc (the concept matches procs, not the existing field)
  and add `depth(c) is int` to the `KdlCursor` concept — essential for recursive-descent
  re-sync.
- Add **`resolveValue(c, valTok, annoTok): KdlValue`** plus **`resolveNodeName`** and
  **`resolvePropKey`** as *required* surface (**[R3] not optional sugar** — a quoted node
  name / prop key carries escapes; without these a consumer re-implements string
  unescaping). All return owned data built from `value.nim` (the leaf, §6).
- `Checkpoint` is **already a concrete exported type** (`cursor.nim:648`); the deferral
  is only "the concept hardwires `Checkpoint`; a future polymorphic cursor may want an
  associated type" — reword accordingly, don't imply it's unbuilt.
- **embed[T]/NimVM:** `resolveValue` allocates `strVal` strings; trace its
  `noSideEffect`-ness through the `embed` compile-time path and either confirm or add it
  to the `{.error.}` boundary (§8.1).

---

## 8. Category 2 — typed codegen

> **Doc-free vs decode-takes-doc (callout).** *Read accessors* (`n.name`, `n.prop`,
> `n.child`) take no doc. *Decode operations* (`decodeNode`, `decodeChild`) take a doc
> because they cursor-seek the doc's token stream — decode is a parse op, not an
> accessor. The "doc-free" guarantee is about the accessor surface only.

### 8.1 Entry surface (6 procs — **doc first wherever a doc appears**)

```nim
proc decode*[T](src: string; sourcePath = "<input>"): Result[T, ParseError]
proc decodeAll*[T](src: string; sourcePath = "<input>"): Parsed[T]          # T = seq[U]
proc decodeNode*[T](doc: KdlDoc; node: KdlNode): Result[T, ParseError]
proc decodeChild*[T](doc: KdlDoc; parent: KdlNode; name: string): Result[T, ParseError]
proc encode*[T](v: T): string                                              # total; canonical
proc embed*[T](src: static[string]; sourcePath: static[string] = "<input>"): T
```

**[R3] param-order fix:** `decodeChild` takes `doc` *first*, matching `decodeNode` — both
are parse ops, so the doc-first discipline is uniform. `Parsed[T]` (`.value`/`.errors`/
`.isComplete`) is defined in `spans.nim` and used by **both** `decodeAll` *and*
`buildDocAll` (today a bare tuple). `embed[T]` is **Cat-2 only**; it gains
`{.noSideEffect.}` itself (**[R3]** — it currently lacks it, so the NimVM premise didn't
hold), and `{.error.}` if a type routes through DOM/`decodeNode` paths.

### 8.2 Slot inference (name-preserving) + dispatch order

A field maps to a slot by **type + name**, but **pragmas always win over inference**
(**[R3]** — the load-bearing dispatch rule). The order:

1. **Field pragma** (`kdlArg`/`kdlArgs`/`kdlProp`/`kdlChild`) → explicit slot.
2. **Type-level `{.kdlScalar.}`** on the field's type → value slot (prop, or arg if
   `kdlArg`), dispatching to the `kdlDecodeValue` extension (§8.4). *This is how an
   `object` like `IpAddress` with a custom codec is routed as a scalar instead of a
   child* — without it the §8.4 "dispatch after inference fails" rule is incoherent
   (the object would be misrouted to child first).
3. **Structural inference**, resolved via `getTypeImpl` (**not** the syntactic shape):
   `object`/`ref object`/`seq[object]` → **child**; primitive/enum → **prop** (field
   name = key). `Option[X]` **inherits X's routing** (`Option[object]` → optional child,
   `Option[primitive]` → optional prop). Bare `seq[primitive]` **without `{.kdlArgs.}` is
   a compile error** (a seq can't be one prop value; demand the explicit pragma).
4. **else** → compile `error` (the current `classify` silently drops unannotated fields,
   `derive_decode.nim:293` — a D3 violation; the resolved else-branch closes it).

**Strict-everywhere:** unknown props, unknown **children** (today silently `skip`'d,
`derive_decode.nim:589`), and unconsumed positional args all error;
`{.kdlIgnoreUnknown.}` (type-level) is the opt-out. `kdlArgs` replaces the
strict-unconsumed-arg check with an append-collector.

### 8.3 Pragma vocabulary

Core: `kdlNode(name)`, `kdlArg`, `kdlArgs` *(new)*, `kdlProp`, `kdlChild`, `kdlScalar`
*(new)*, `kdlRename`, `kdlRenameAll(convention)` *(new; also fixes `nodeNameOf`'s
`HTTPServer→httpserver` mis-casing to PascalCase→kebab)*, `kdlReserved(tag)`, `kdlSkip`,
type-level `kdlNoEncode`/`kdlNoDecode`/`kdlIgnoreUnknown` *(new)*. **No `kdlDefault`** —
honor native Nim field defaults (§8.5). **No `kdlWith`** — use `kdlDecodeValue` (§8.4).
Deferred/filed: `kdlAlias`, directional skip, `kdlFlatten`, untagged variants.

### 8.4 Extension point for custom scalars

```nim
proc kdlDecodeValue*[T](v: var T; val: KdlValue): Result[void, ParseError]
proc kdlEncodeValue*[T](v: T; e: var BufferEmitter)
```

**[R3] drop the `StringCursor` param** — `KdlValue` (which carries the span) is all a
scalar decoder needs; passing the live cursor leaks an internal stateful type the user
can corrupt, serde's `Deserialize` gets the value not the cursor, and the encode side is
already cursor-free. `KdlValue` lives in `value.nim` (§6) — this couples Cat-2 to the
leaf, not the node tree. Reached only after a `{.kdlScalar.}` type marker (§8.2 step 2);
no `compiles()` probe.

### 8.5 Native field defaults

`var v: T` zero-inits; it does **not** apply `port: int = 8080`. The macro reads the
default from `IdentDefs[^1]` — **[R3] `regularFields` must be extended to *yield* it**
(it currently drops `child[^1]`) — and splices `v.field = <default>` when the required
slot is unset, erroring only when no default exists. Inherited-field defaults
(`nnkOfInherit`) are a **noted scoped limitation**, not handled v1. For `embed[T]`:
`{.error.}` if a default expr is a `Call`/`Command` whose head proc lacks
`{.noSideEffect.}` (one `getImpl`); complex default exprs aren't statically checked and
will surface as a clear NimVM error.

### 8.6 Variant dispatch

Inline-discriminator case objects (discriminator is `kdlArg`/`kdlProp`); node-name
dispatch is the consumer-side `case n.name` pattern (no library work). **[R3]** the
generated branch `case` must have an `else` (non-exhaustive `case` on a many-valued enum
discriminant is a latent codegen hole). Library-level untagged/tagged sum types deferred.

### 8.7 Codegen dispatch rebuild (do FIRST — Stage SD)

Extract `derive_common.nim` (one `fieldInfo`, the `*`-export strip, the `nodeNameOf`
casing fix). **Replace `$fieldType` string-switch with `getTypeImpl`-resolved dispatch**
(so `distinct`/aliases route correctly, not silently `error`). Fix `isOptionType` →
`t.kind == nnkBracketExpr and t[0].eqIdent("Option")` (**[R3]** — `$t[0]` breaks under
qualified imports; `eqIdent` is the documented-correct, identity-agnostic form). Add
`ckOption` children, **`ckRef`** (`ref T` fields crash `nodeNameOf` today), `uint`/
`uint8..64` (with a negative-literal bounds check), the **`>64`-required-field hard
`{.error.}` at `claimSlot()`** (today slots ≥64 silently become optional —
`derive_decode.nim:371`), and honor `{.kdlSkip.}`.

---

## 9. Category 3 — DOM

### 9.1 Types + accessors

Self-contained nodes (§5). Doc-free read surface:

```nim
func name*(n): string
func typeAnnotation*(n): Option[string]
func arg*(n, i): Option[KdlValue]; func args*(n): seq[KdlValue]; iterator arguments*(n)
func prop*(n, key): Option[KdlValue]                 # LAST-wins (§9.3)
func props*(n): seq[tuple[key: string, value: KdlValue]]; iterator properties*(n)
func child*(n, name): KdlNode                        # nil = absent
func children*(n): seq[KdlNode]                      # by value — see §9.2 note
func children*(n, name): seq[KdlNode]
func node*(doc, name): KdlNode; func nodes*(doc): seq[KdlNode]; func nodes*(doc, name)
iterator descendants*(n): KdlNode                    # iterative DFS
func find*(n, name): KdlNode                         # first descendant, or nil
# typed value conveniences (core; symmetric coverage — [R3]):
func propInt*/propStr*/propBool*/propFloat*(n, key): Option[...]
func argInt*/argStr*/argBool*/argFloat*(n, i): Option[...]
```

**Absence policy:** `nil` for nodes (refs are nullable), `Option` for values (value
types aren't). No `has*`. **No parent pointers** (mutable `ref` + no borrow checker makes
parent-maintenance a per-mutation footgun); `find` returns the live ref (mutate through
it). **[R3]: `findPath(root, name): seq[KdlNode]`** (ancestor chain, trivial iterative
DFS with a stack) is added now, **not deferred** — removal-of-found otherwise forces
every consumer to hand-roll a root re-traverse and some will mis-target a same-named node
higher in the tree.

### 9.2 Mutation

`newNode(name)` **without a doc** (the headline win; trivial under owned strings —
`clone(n)` is a plain deep copy of the ref tree, **[R3] no `adopt`/offset-remap because
foundation B was dropped**). `addArg`/`setArg`(by index)/`removeArg`; `addChild`/
`insertChild`/`removeChild`(→int)/`replaceChild`(→bool); `setProp`(upsert)/`removeProp`;
`setName`/`setTypeAnnotation`; doc-level `add`/`insert`/`removeNode`/`replaceNode`;
symmetric `setPropInt`/`setPropStr`/`setPropBool`/`setPropFloat`. **Drop `addProp`** (the
parser collapses dup keys to last-wins — `doc_build.nim:178` — so a parsed DOM never has
them; `addProp` only manufactures the footgun). Every mutator sets `n.dirty`.

**[R3] `children()`/`nodes()` return `seq[KdlNode]` BY VALUE, not `lent`.** A `lent` view
into `childNodes` dangles if a mutator reallocates the seq mid-iteration, and Nim's
borrow checker can't prevent it (the same "no borrow checker" reason we reject parent
pointers). The copy is O(children), already the iteration cost. **Raw `entries`/
`childNodes` are not public-mutable fields** — `lent`-free read accessors + the mutation
API are the surface; raw access is a `{.dangerous.}`-named escape that re-canonicalizes.

### 9.3 Preserve

Dirty-flag + per-node `NodeMeta` (§5.5) is the operative path; the per-entry
`parseHash`-driven surgical splice is the planned **#284** path, not wired today (stated
so contributors don't think it drives the current decision). `encode(doc, emPreserve)`
splices source bytes for clean subtrees, canonical-emits dirty ones. **[R3] `prop()`
returns LAST** (KDL 2.0 §Properties = rightmost wins; `ast.nim:515` returns first — a
backward scan, identical cost, spec-correct even for `{.dangerous.}`-built nodes).
**`canPreserve` loud-fail:** `encode(doc, emPreserve)` when `not canPreserve(doc)`
**returns `Result[string, KdlError]`** (the silent-canonical degrade at
`doc_emit.nim:117` is the footgun; `doAssert` violates D2, a warning violates D3 — a
`Result` honors both). The non-preserve `encode` stays total `string`.

### 9.4 Query / traversal

`descendants`/`find`/`findPath` + generic `where`/`first`/`only`. **[R3] signatures must
be specified** (they don't exist yet):

```nim
iterator descendants*(n): KdlNode                              # lazy
proc where*(it: iterable[KdlNode]; pred: proc(n: KdlNode): bool): seq[KdlNode]
proc first*(it: iterable[KdlNode]; pred: proc(n: KdlNode): bool): KdlNode   # nil if none
proc only*(it: iterable[KdlNode]; pred: proc(n: KdlNode): bool): Result[KdlNode, ...]
```

accepting the lazy `descendants` iterator so chaining isn't O(n²). Plus a **predicate
combinator set** `byName`/`hasProp`/`propEq`/`propMatches` so the "strict superset of
KQL" claim is *ergonomically* honest (**[R3]** — without combinators it's only
Turing-superset; with them it's one-liner-superset, and it's ~10 trivial predicates, not
a query language). **KQL deferred** to optional `nkdl/kql` (string language → no
compile-time typo safety; unreleased `next` draft; thin cross-impl adoption). Relabel
`path.nim` → `typed_path.nim` (Cat-2, not Cat-3).

---

## 10. Error model

`ParseError` renders standalone (`path:line:col: error[code]: msg` + caret via the
source-taking overload), carrying `severity`, `relatedSpans`, a **field-path**
(`server.listen.port`), a named missing-required field, a did-you-mean on unknown-field,
and a **stable `ParseErrorCode`** (explicit integer values). **[R3] `ParseErrorCode`
lives in a new `errors.nim` leaf** (not `spans.nim`, which is KEEP-verbatim and would
otherwise be amended); `ParseError`/`Parsed[T]` reference it. Field-path threading
prepends the field name at each child-decode boundary on the error path — **empty on
success (no alloc on the hot path); one seq alloc on the first error propagation, then
O(depth) prepends** (the "no alloc" claim holds only for success — stated precisely).
Two-tier construction: `initError` (source-less) / `makeError` (source-bearing). `embed[T]`
failure → `{.error: formatError(...).}` (caret), not `doAssert`.

---

## 11. Execution plan (stable IDs; each stage = a working, benchable checkpoint)

**Pre (§16):** checkpoint branch; 30-min callgrind cycle-attribution isolation;
generate `mixed-names-200.kdl`; the A/B/C test triage; **a codegen spike** validating the
`classify`/`getTypeImpl` dispatch rewrite (**[R3]** — sizes the SD/SE risk before
committing to the schedule); write the §5.2 struct-size table.

- **S0 — SSO gate.** Prototype plain-O + minimal parse, then O+SSO; massif + callgrind on
  3 fixtures; pick per §5.4; write `docs/stage0-measurement.md`.
- **SA — `ast` + `value.nim`.** Self-contained nodes (chosen layout, within the §5.2
  table), per-node `NodeMeta`, hidden raw fields, `clone`, `==` string-compare, `prop`
  last-wins; **extract `value.nim`/`errors.nim`**; delete `intern`; drop C-class tests.
- **SB — `doc_build` + `grammar` + conformance adapter.** Owned-string builder;
  `canPreserve` loud-fail `Result`; `buildDocAll → Parsed[KdlDoc]`; extract `token_text`;
  **adapt `grammar` here ([R3]: it's on SI's critical path — `test_conformance.nim` calls
  `referenceInterpret`)**; **rewrite the adapter** (closes the conformance dark window).
- **SC — `doc_emit` + `emitter` + `hashing` + `Parsed[T]`.** Drop `InternedStr`
  overloads; owned-string reads; `hashing` field-rename port + xxh3 swap.
- **SD — `derive_common` + codegen dispatch rebuild (§8.7).** Silent-drop `classify` fix,
  `getTypeImpl` dispatch, `eqIdent`, `ckOption`/`ckRef`, `uint`, 64-field hard-error,
  `kdlSkip`, `kdlScalar` routing, variant `else`.
- **SG′ — Cat-1 fixes (§7), before features.** `skip`/`ceError`, `resolveValue`/
  `resolveNodeName`/`resolvePropKey`, `depth()` proc.
- **SE — Cat-2 features.** Native defaults, `mixin kdlDecodeValue` (`KdlValue`-only),
  `decodeNode(doc,node)`/`decodeChild(doc,…)`, field-path errors, `decodeAll → Parsed[T]`,
  `embed` `{.noSideEffect.}` + `{.error.}`, document canonical-always `encode`.
- **SF — Cat-3 surface.** `descendants`/`find`/`findPath`/combinators/`clone`, drop
  `addProp`, by-value `children`/`nodes`, relabel `path`, symmetric conveniences.
- **SH — error model (§10).** `errors.nim` codes, severity, caret, did-you-mean.
- **SI — proptest + CI** (**[R3] split**): **SI-a** wire the property suites + the
  rebuilt adapter corpus gate; **SI-b** (after grammar, i.e. post-SB) wire
  `test_conformance.nim` + `test_crosscat_properties.nim`. `NKDL_PROPTEST` gating.
- **SJ — completeness + cutover (§13/§14).** Supersession header-redirect on the
  hardening RFC, NFC/DoS/arc/thread-safety docs, versioning issue, examples, retire the
  checkpoint branch.

**Determined orderings:** S0 first; grammar at SB; SD before SE; SG′ before SE; adapter
within SB. ~90 TDD slices; **~3.5–4.5 weeks** (**[R3]** — the larger-than-claimed B-class
test rewrite + the codegen-dispatch macro work add ~1.5 days over the prior estimate).

---

## 12. Test strategy

**Triage (A survives / B mechanical-rewrite / C delete) — [R3] corrected by line count
(8013 test LOC):** ~**61% A**, ~**35% B**, ~**3% C** (the earlier "73/24/3" undercounted
B — `test_emitter.nim`, `test_cursor.nim`, `test_substrate_properties.nim`,
`test_parser.nim` carry more interner/`nameHandle`/`initInterner` sites than estimated).
B = mechanical (`interner.lookup(n.nameHandle)` → `n.name`, `intern("x")` → `some("x")`,
drop `initInterner()`). C = `test_intern.nim` + `test_owner_document.nim` (267 LOC).
Files needing judgment: `test_ast.nim`'s cross-doc equality suite, the conformance
adapter, and **`test_conformance.nim` (B-class, runs only after grammar @ SB —
[R3] previously unclassified)**.

**Pin characterization tests BEFORE touching `ast`:** byte-exact preserve; **the
self-containedness proof** — `let n = parse(s).get.node("x"); discard doc; check n.name
== "x"` (impossible under handles); cross-doc `==`; the parser-as-conformance baseline.

**Green-net:** monotonic; the `test` job stays green throughout. **Conformance dark
window (S0→SB):** a `adapter-compiles` CI job, **expected-red and visible** — a *second,
explicitly-dark gate* distinct from the always-green `test` job (the dual-gate contract
is documented so a red dashboard reads as "known gap," not regression). Flipped to
run-and-pass + hard merge gate at SB. **CI jobs:** `test` (blocking), `adapter-compiles`
(dark→blocking at SB), `proptest`+corpus (merge gate), `perfGuard`.

---

## 13. Supersession of `rfc-api-v0.2-hardening.md`

Its **API-surface spec** survives as input; its substrate sections get a "superseded"
header. **[R3] at SJ, fold its §6 API surface into §8–§9 here and replace it with a
header-redirect** so the two docs don't rot in parallel. Item disposition:

| Hardening-RFC item | Disposition |
|---|---|
| §2.5 C0-a..e, F.0–F.4 (`ownerDocument`/`adopt`/`equalsAcross`/ptr-vs-ref) | **CANCELLED** |
| F.5 perf numbers | **CANCELLED** — re-measured by S0 |
| §8.2 cross-doc handle guard, `migrateValue`, tombstone deletion | **CANCELLED** |
| F.1 (ref nodes) | **SURVIVING** |
| F.2.5 (tombstones-never) | **SURVIVING intent** — by construction |
| F.3a (`n.name` as accessor) | **SURVIVING surface** — impl is a field read |
| `decodeNode`/`decodeChild` "no doc param" | **REMAPPED** → doc-first (§8.1) |
| §6.1 `Parsed[T]`, §7.1.1 codegen fixes, §7.2.1 `kdlArgs`/`rename_all`, §8.1 doctrine, Phase 2 error contract | **SURVIVING** — folded into §8/§10 |

The uncommitted F.2.5/F.3 working tree has nothing to cherry-pick. Keep
`checkpoint/pre-rebuild-*` 30 days as a test cherry-pick source.

---

## 14. Behavioral changes + completeness

- **Thread-safety (**[R3]**):** under O each node's strings are independent heap
  allocations — a `KdlDoc` is a `ref` tree with no shared sub-string state, so it's
  single-thread-owned like any `ref object` (no special blob-aliasing hazard, since B
  was dropped). Document: share a parsed doc across threads read-only or clone per
  thread; no internal locking.
- **Unicode (nkdl#36):** byte-equality is now unconditional (no interner normalization
  layer). nkdl does **not** NFC-normalize; identifier equality is byte-equality;
  caller's responsibility. Resolve #36 accordingly.
- **DoS (nkdl#32):** owned-strings change the per-identifier allocation profile; nesting
  is still capped by `MaxParserDepth = 256`. Update #32's analysis.
- **`embed[T]` / NimVM:** Cat-2 only; gains `{.noSideEffect.}`; the ref-AST DOM and
  `decodeNode` are not embeddable — `{.error.}`-enforced. Trace `resolveValue`'s purity
  (§7).
- **`--mm:arc`:** no `KdlNode`↔`KdlDoc` cycle (`ownerDocument` gone) → arc-safe.
- **Versioning/publish/stability:** deferred (still pre-adoption = zero-compat) but the
  **issue is filed in pre-work and must exist before SI** so CI doesn't merge without a
  stability signal.
- **Worked examples (**[R3]** — add to §SJ docs):** one end-to-end snippet per category —
  Cat-1 streaming read, Cat-2 `decode[T]` of a config struct, Cat-3 parse→mutate→
  `encode(emPreserve)` — so two implementers don't diverge at the integration seams.
- **Conformance adapter spec (**[R3]**):** the rebuilt `conformance/adapters/nkdl.nim`
  must preserve a stated invariant set (a node reports value X iff the fixture says X;
  the neutral-JSON mapping is unchanged) — it's the only bridge from the Lean proofs to
  running code, so SB specifies its before/after API diff, not just "rewrite."

---

## 15. Risks + open items

- **[R3] Codegen SD/SE scope** (now top risk): the §8.7 dispatch rebuild is macro-level
  Nim work that is hard to estimate, and SI's property suite (P7/P8/P9) stays dark until
  it's correct. **Mitigation: the pre-work codegen spike** (§16) sizes it before the
  ~90-slice schedule is committed.
- **SSO complexity not paying** → the S0 gate's take-plain-O-on-tie rule caps the
  downside; plain O is always a correct fallback.
- **`hashing` rewrite invalidates pre-rebuild `parseHash`** → harmless (canonical
  fallback); document old/new hashes are incomparable.
- **`grammar` oracle adaptation** (896 lines, ~8 coupling sites) → done at SB, gated on a
  known-good corpus-diff.
- **No genuine open *design* fork remains** — the SSO question is data-gated; everything
  else is determined.

---

## 16. Pre-work checklist (before the branch)

1. `git tag`/branch `checkpoint/pre-rebuild-2026-06-03`; commit the current green tree.
2. 30-min callgrind isolation (current vs `ownerDocument`-removed) → confirm the cycle
   attribution; record numbers.
3. Generate `benchmarks/fixtures/mixed-names-200.kdl`.
4. Run `nimble test`; capture per-file counts; produce the A/B/C triage table.
5. **Codegen spike** ([R3]): prototype the `classify` else-branch + `getTypeImpl`
   dispatch on 2–3 representative types; confirm the SD estimate.
6. Write the §5.2 struct-size table into this RFC's §5.2 as the SA acceptance bar.
7. File issues: versioning/publish policy; KQL optional module; deferred pragmas
   (`kdlAlias`/directional-skip/`kdlFlatten`); inherited-field defaults limitation.
8. Open the fresh branch; begin **S0**.
