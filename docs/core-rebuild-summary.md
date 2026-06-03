# nkdl core rebuild — summary & design-goals seed

**Status:** decision record + RFC seed. Captures how we got here, what we're
building toward, and the design constraints the new core must satisfy. This is
the *starting point* for the core-rebuild RFC; it supersedes the substrate parts
of `rfc-api-v0.2-hardening.md` (which stays valid as the **API-surface spec**).

---

## 1. What happened

A first external consumer (amoxtli) hit ~10 holes in the public API. We wrote
`rfc-api-v0.2-hardening.md`, ran a 5-agent depth review (R1), and executed it as
TDD slices. The API-surface goals it defined are **correct and proven** — the
work below validates them. The problem is *where* we tried to land them.

### The substrate fought the goals

The hardening targeted a **doc-free, self-contained, cross-doc-safe** node API.
But the storage core underneath was **interner-first + handle-based**: a
`KdlNode` stored `InternedStr` handles (`nameHandle`, prop keys) that can only be
resolved against *some* doc's interner. To make accessors doc-free we bolted a
`ownerDocument` back-reference onto every node (F.3) — and the bolt-ons cascaded:

- `ownerDocument: ref KdlDoc` → a **doc↔node reference cycle** ORC must trace.
- cross-doc inserts now need **`adopt`** (O(subtree) re-interning).
- `==` needed cross-interner resolution (`equalsAcross`).
- the cross-doc-foreign-handle footgun (C0-d) existed *only because* of handles.

### The regression that forced the question

Parse-to-DOM benchmark (`profile_parse`, min-of-5, same container):

| build | µs/parse | vs F.1 |
|---|---|---|
| F.1 (ref-AST, interner, no `ownerDocument`) | 126 | — |
| F.3 (`ref ownerDocument` + `Option[string]` value anno) | **203** | **+61%** |
| F.3 with `{.cursor.}` ownerDocument (diagnostic only) | 155 | +23% |

Isolated cost: **~48 µs (~38%) is the doc↔node cycle** (`ref` vs `{.cursor.}`);
the remaining **~29 µs (~23%) is value-struct growth** (`Option[string]`).

`{.cursor.}`/`ptr` recover the cycle cost but are **unsound** — a non-owning
back-ref dangles the instant a node outlives its doc, which is the *most common*
pattern (`let n = parse(src).get.node("x")` drops the doc temporary). Same
hazard we already rejected for `ptr`. So the cycle is the *price of soundness*
under a node→doc back-reference.

### The lesson

We already solved this correctly **for values**: a `KdlValue` *owns* its `strVal`
and `Option[string]` annotation → doc-free, cross-doc-safe, adopt-free **by
construction**, zero machinery. We did the opposite for nodes (interned handles
needing a doc) and then bolted the back-ref back on. The complexity
(`ownerDocument`/`adopt`/cycle/`equalsAcross`/foreign-handle guard) is the
substrate telling us it wasn't designed for the goal.

**Conclusion:** stop migrating the interner-handle model toward doc-free goals.
Rebuild the DOM core around **self-contained nodes** — the model we already
proved works for values.

---

## 2. Goals moving forward

Build the DOM core that the v0.2 API surface *wants*, designed for it from line
one, on a clean branch — reusing the proven periphery, rebuilding only the core.

### Keep / rebuild boundary

**KEEP (foundation-independent, proven, do not touch):**
- `lexer`, `cursor` (Cat-1 streaming), `numlit`, escape/number handling, `spans`
- **The typed hot path** — `derive_decode` / `derive_encode` / `kdl_block`. It is
  **cursor↔struct, DOM-free; it never touches `KdlNode`.** The knus-parity perf
  we fought for is **untouched** by a core rebuild.
- `emitter` (byte-level `BufferEmitter`) — takes strings/values, AST-agnostic
- conformance corpus + Lean proofs (model-level)
- the test suite (port early — it's the behavior contract; 676 green today)

**REBUILD (the DOM core only — ~4 modules of ~20):**
- `ast.nim` — self-contained nodes; the doc-free API as the *native* design
- `doc_build.nim` — Cat-3 builder emits self-contained nodes
- `doc_emit.nim` — reads owned strings, not interner lookups
- `hashing.nim` — `parseHash` over owned bytes

**DELETE:** `intern.nim` (the `InternedStr` type and per-doc interner) — unless
the foundation measurement says dedup must stay, in which case it survives as an
*internal storage detail*, never in the AST type.

---

## 3. Design goals (the new core must satisfy)

These are the constraints the rebuilt core is designed *around* — not migrated
toward.

1. **Self-contained nodes.** A `KdlNode` owns its name and property keys as plain
   strings (mirroring `KdlValue`'s owned `strVal` / `Option[string]` annotation).
   No `InternedStr` in the AST, no `ownerDocument`, no per-node doc back-ref.
   - `n.name` is a field. Doc-free **by construction**.
   - cross-doc move is a **no-op** (`adopt` deletes itself).
   - `==` is a string compare — cross-doc-correct for free.
   - the C0-d foreign-handle footgun is **unrepresentable**.
   - no doc↔node cycle → no ORC cycle-scan cost.

2. **Mutate-through coherence (keep F.1's win).** `KdlNode`/`KdlDoc` stay `ref`;
   reads return the live node; mutation is through the ref; `nil` = absent. No
   value-copy-on-read, no `var`-threading.

3. **The doc-free API surface is the spec.** `rfc-api-v0.2-hardening.md` slices
   1–6 already define it: `n.name`/`n.typeAnnotation`/`n.prop`/`n.child`/
   `n.children`/`n.args`/`n.properties` (no `doc`); mutators without `doc`;
   `==` cross-doc-correct; `Option` for missing-vs-present (incl. explicit `("")`
   via `Option[string]`); `encode[T] → string`; no `has*`. Build the new core to
   this contract directly.

4. **Three-category layering preserved.** Cat-1 streaming cursor / Cat-2 typed
   DOM-free decode+encode / Cat-3 DOM. The rebuild is Cat-3 only; Cat-1/Cat-2 are
   reused untouched.

5. **Byte-exact preserve.** Keep the dirty-flag + span + `parseHash` model
   (works today via `doc_emit`'s subtree-canonical fallback). Self-contained
   nodes don't change this; finer-grained intra-node splice + slashdash
   byte-exact (#284) remain separate roadmap features.

6. **Fail-loud, illegal-states-unrepresentable, single-source-of-truth, root-
   cause-over-symptom** — the standing project principles (D1–D6 from the
   hardening RFC) carry over verbatim.

---

> **§4 and §6.2 below are partially superseded by the R2 review — see §9.** The
> measurement plan (§4) and the `decodeNode` signature (§6.2) were corrected.

## 4. The one open decision — foundation perf (measure first)

Self-contained nodes need identifier bytes *somewhere*. The interner existed to
avoid heap-allocating every repeated identifier (Nim strings have no
small-string optimization). Two sound, cycle-free candidates:

- **(O) Owned-string nodes.** `name`/keys are owned `string` fields. Simplest;
  zero machinery; deletes the interner. Cost: a heap alloc per identifier
  instance (no dedup).
- **(A) Arena / blob.** Identifier bytes live in contiguous per-doc storage; a
  node reaches them via offset/`NodeId`. Dedup preserved, no cycle, sound (handle
  keeps the doc alive; an index can't dangle into UB). Cost: a handle-based core
  + more impl surface.

**Decide on data, not vibes.** Day one of the clean branch = the new `ast.nim`
(start with **(O)**, simplest) + a minimal `parse → DOM` path, benched against
the **126 µs** F.1 baseline:
- competitive or better → **(O)** is the foundation.
- acceptably close → take **(O)** for the simplification; identifiers aren't the
  hot path.
- materially slower → the interner earns its keep → build **(A)** (arena), still
  cycle-free and sound.

The typed hot path is DOM-free, so whichever wins, Cat-2 perf is unaffected.

---

## 5. Process — clean branch, port the proven stack in, build the core to spec

The execution model is a **clean-room re-layering on a fresh branch**, NOT an
in-place mutation of the current (tangled, half-migrated F.2.5/F.3) tree, and NOT
a from-scratch rewrite of the proven stack. The R2 review (§9) confirmed the
findings cluster on the *core* and the *codegen gaps* — never the lexer, grammar,
cursor, emitter, or proofs — so those are *ported in*, not re-derived.

- **Fresh branch.** The current branch is kept only as an artifact to cherry-pick
  tests/reference from; the uncommitted F.2.5/F.3 work is **superseded** (F.3
  `ownerDocument`/`adopt` cancelled — see the §11 supersession table the RFC
  carries). Decide at branch time: commit the current green tree as a labeled
  checkpoint first (to cherry-pick tests cleanly) vs leave it as a working-tree
  reference.
- **Port the proven modules in (per the §9.3 tiers):** `lexer`, `numlit`, `spans`,
  `fnv`, `grammar`, `cursor`, `emitter`, the conformance **corpus**, the Lean
  **proofs** — verbatim or with only their mechanical adaptation (`emitter` drops
  `InternedStr` overloads; `cursor` drops the vestigial `intern` import).
- **Foundation-measurement first (Stage 0).** Build the minimal new-core types +
  a parse-to-DOM path under the chosen foundation — **prototype (B) the per-doc
  string blob first** — and bench it on the *corrected* gate (§9.1: callgrind +
  allocations + RSS, ≥3 fixtures incl. `mixed-names-200`, ±20% threshold). The
  whole rebuild gates on this number; nothing else is built until it's decided.
- **Build the new core to the §6/§9 spec:** `ast` (self-contained nodes, the
  doc-free accessor surface, hidden raw fields, sidecar'd parse metadata),
  `doc_build`, `doc_emit`, `hashing`.
- **Finish the codegen to spec:** implement the §9.5 fixes (slot inference,
  native-default splice, `mixin kdlDecodeValue`, `isOptionType` via `bindSym`,
  field-path errors, `ref T`/`uint`/64-field, strict×`kdlArgs`).
- **Triage the tests in (A/B/C, §9.7):** A survives verbatim, B rewritten against
  the new substrate, C deleted (tests of deleted concepts: interner, ownerDocument).
  **Rewrite the conformance adapter** (it's REBUILD, not KEEP) so the corpus gate
  is green before merge.
- **`rfc-api-v0.2-hardening.md`** stays as the **API-surface spec** (its determined
  API fixes live on); the substrate/F.x sections get a "superseded — see
  core-rebuild RFC" header per the §9.7 supersession table.
- Bench (callgrind) continuously; keep a green net by porting in dependency order
  so each module arrives with its tests.

---

## 6. API design per category (determined)

A 5-expert review (one lens per category, two contrasting lenses each for Cat-2
and Cat-3) was run against the current surface + design goals. The contrasting
pairs **converged** far more than they diverged; the apparent forks all resolve
to determined best-in-class answers under first-principles (§7). This is the
API the rebuild builds to.

### 6.1 Cat-1 — streaming cursor (small; foundation, not a consumer surface)

Human-facing Cat-1 ergonomics genuinely don't matter much — its real consumer is
Cat-2/Cat-3. Keep the **pull cursor** (`advance`/`peek`/`skip`/`pos`/`seek`);
visitor-push and Nim-`iterator`-as-primary are both rejected (StAX/serde/quick-xml
lineage — a recursive-descent consumer must own its own stack and be able to
`seek`). The work is *correctness of the foundation* + one ergonomic must:

- **Fix** `skip()` swallowing `ceError` in `cmAccumulating` mode (corrupts
  `decodeAll` recovery — see §8); put `depth()` in the `KdlCursor` concept; add a
  no-alloc `bytesEq(c, tok, s: string): bool`.
- **Add `resolveValue(c, valTok, annoTok): KdlValue`** (+ `resolveArg` /
  `resolvePropValue` / `resolveNodeName` sugars). Events say *where* a value is,
  not *what*; without this a direct Cat-1 consumer re-implements `numlit`
  number-parsing — the exact supply-chain risk `numlit.nim` centralizes.
- Defer: associated-type `Checkpoint` in the concept (v0.3), an `events` sugar
  iterator (additive; Cat-2/3 must not use it internally).

### 6.2 Cat-2 — typed codegen (decode/encode)

**Entry surface (6 procs, nothing more):**

```nim
proc decode*[T](src: string; sourcePath = "<input>"): Result[T, ParseError]
proc decodeAll*[T](src: string; sourcePath = "<input>"): Parsed[T]   # T = seq[U]
proc decodeNode*[T](node: KdlNode): Result[T, ParseError]            # no doc param
proc decodeChild*[T](parent: KdlNode; name: string): Result[T, ParseError]
proc encode*[T](v: T): string                                        # total
proc embed*[T](src: static[string]; sourcePath: static[string] = "<input>"): T
```

`kdlDecode(v: var T; c)` / `kdlEncode(v: T; e)` stay the generated `mixin`s (not
public). `Parsed[T]` (`.value`/`.errors`/`.isComplete`) replaces the bare tuple.

**Slot inference (the determined model — name-preserving):** a Nim object field
maps to a KDL slot by **type + name**, not by a guess:

- `object` / `ref object` / `seq[object]` → **child** (structural; inferable)
- primitive / enum / `Option[primitive]` → **prop** (the field name *is* the key —
  the lossless name-preserving mapping)
- `{.kdlArg.}` / `{.kdlArgs.}` → the explicit **name-dropping positional** exception
- `seq[primitive] {.kdlArgs.}` → variadic args (`tag "a" "b" "c"`)

This is not silently-wrong: with **strict-everywhere** (unknown props/children
**and** unconsumed positional args all error), any mismatch between the schema's
slot intent and the actual KDL surfaces as a loud decode error. The dominant
all-prop-plus-sections config needs **zero** annotations; positional args are the
one honest, localized annotation.

**Pragma vocabulary (core + the determined additions):**

- Core: `kdlNode(name)`, `kdlArg`, `kdlArgs`, `kdlProp`, `kdlChild`, `kdlRename`,
  `kdlReserved(tag)`, `kdlSkip`, type-level `kdlNoEncode` / `kdlNoDecode`,
  type-level `kdlIgnoreUnknown` (opt OUT of strict).
- `kdlRenameAll(convention)` — **add**, but only as the knob for the casing
  transform we must build anyway (`nodeNameOf` currently mis-cases
  `HTTPServer→httpserver` — a bug; fix it to correct PascalCase→kebab/snake, and
  `rename_all` is its explicit override).
- **No `kdlDefault` pragma** — honor **Nim's native object field defaults**
  (`port: int = 8080`). Required field missing → error; field-with-default missing
  → use it; `Option` missing → `none`. (Better than a pragma *and* better than
  `Option`+post-fill; zero new surface.)
- **No `kdlWith` pragma** — for an unknown *scalar* field type (`IpAddress`,
  `DateTime`, `Uri`), the codegen emits a `mixin kdlDecodeValue` /
  `kdlEncodeValue` call the user **overloads**. The idiomatic Nim equivalent of
  "manually implement `Deserialize`", resolved at compile time. No string module
  paths.
- **Defer / file:** `kdlAlias`, directional field-skip (`kdlSkipEncode/Decode`),
  `kdlFlatten`, untagged variants, `Spanned[T]`-as-default. JSON-interop artifacts
  or footguns with no config-authoring use case a post-decode step / wrapper can't
  cover. (Variants: node-name dispatch + inline-discriminator both supported; the
  node name *is* the natural KDL tag.)

**Codegen correctness (do FIRST, before features):** extract `derive_common.nim`
with a single `fieldInfo` (the `*`-export strip + the double-bug live here);
replace `$fieldType` string-switch dispatch with **`getTypeImpl`-resolved**
dispatch (so `distinct`/aliases/newtypes don't silently fall into `error`); add
`ckOption` for `Option[T]` children (currently a silent compile failure); honor
`{.kdlSkip.}`.

**Error model (the highest-leverage UX):** `ParseError` renders standalone
(`path:line:col: error[code]: msg` + caret via the source-taking overload), with
`severity`, `relatedSpans`, a **field-path** (`server.listen.port` — both Cat-2
agents call this the single biggest diagnostic win; knus/miette have it), named
missing-required field, did-you-mean on unknown-field, and a **stable**
`ParseErrorCode` (explicit integer values). Two-tier construction
(`initError` source-less / `makeError` source-bearing + boundary enrichment).

### 6.3 Cat-3 — DOM

**Self-contained `ref` nodes (the §3 substrate), doc-free accessors.** Both DOM
lenses converged on essentially "kdl-rs's model ported to Nim":

- Read: `name: string`, `typeAnnotation: Option[string]`, `arg(i)`/`args`/
  `arguments`, `prop(key)`/`props`/`properties` (string keys), `child(name)` (nil
  = absent) / `children` (`lent seq`, zero-copy) / `children(name)`, doc-level
  `node`/`nodes`. **Add `descendants` (lazy iterator) + `find(name)`** — both
  agents independently named this *the* missing read primitive.
- **Typed value conveniences** (`propInt`/`propStr`/`propBool`, `argInt`/`argStr`,
  symmetric `setPropInt`/…) — kill the `v.get.intVal` + nil-check noise; the real
  ergonomic win is value/predicate expression, not traversal. In core (every
  consumer reaches for them in the first 10 minutes).
- Mutate: `newNode(name)` **without a doc** (headline win); `addProp` (append) vs
  `setProp` (upsert) — KDL allows duplicate keys; `removeChild`/`removeNode`→`int`,
  `setArg`/`removeArg`/`replace*`→`bool`. A `kdl{}` builder macro for
  construction-from-scratch lives in an **optional module**, not core.
- **No parent pointers — ever** (determined, §7). Upward navigation → root-down
  path visitor, filed if a real consumer needs it.
- Equality: `==` is a plain structural string compare (no `equalsAcross`,
  cross-doc-correct for free). Absence policy is **named**: `nil` for nodes
  (refs are nullable), `Option` for values (value types aren't). No `has*`.
- Preserve: keep the dirty-flag + span + `parseHash` model; **fix the
  `emPreserve`-without-`preserveFormat` silent-canonical footgun** (add
  `canPreserve(doc): bool`, fail loud). Finer-grained splice + slashdash byte-exact
  stay #284.

**Query — Nim-native typed traversal in core; KQL deferred to an optional module.**
`descendants`/`find` + `where`/`first`/`only` (already generic) + arbitrary Nim
boolean predicates are a **strict superset** of KQL's CSS-selector matchers
(`>`/`>>`/`[]`/`val()`/`^=`…) for the in-process consumer, and compile-time-safe.
KQL's only differentiated value is *runtime / string-portable / cross-impl*
queries — and (verified against kdl-org/kdl) the spec is an **unreleased `next`
draft** with thin cross-impl adoption. So KQL is superseded for in-process use,
not stable to build on, and unproven in the wild → **`nkdl/kql` optional module,
deferred**; build only if KQL *releases* AND a dynamic-query consumer (config
editor, `kdl query` CLI) appears. **Also:** the existing `path.nim` is mislabeled
(§8) — it's a Cat-2 typed-struct traversal helper, not Cat-3 DOM query; rename /
relocate it accordingly.

---

## 7. Apparent forks — resolved to determined (the reasoning)

The review surfaced five apparent design forks. None is genuinely opinion-based;
each resolves under first-principles. Recorded so the rebuild isn't re-litigated:

1. **Inference default (props vs explicit-required):** DETERMINED → props-as-default,
   reframed as the *name-preserving canonical mapping* (named field → named slot;
   positional is the name-dropping exception; objects infer to child). Strict-
   everywhere makes mismatches fail loud, so it isn't silently-wrong. knus chose
   explicit-required, but that's derive-macro conservatism, not a principled counter.
2. **`kdlDefault`:** DETERMINED → no pragma; honor Nim's native field defaults
   (cleaner than serde's pragma AND than Option+post-fill).
3. **`kdlWith` custom codec:** DETERMINED → no pragma; a `mixin kdlDecodeValue`/
   `kdlEncodeValue` extension point (Nim's idiomatic "implement Deserialize").
4. **Cat-3 query (KQL vs Nim-DSL vs both):** DETERMINED → a *layering* decision, not
   a fork. Nim typed traversal in core (superset, compile-safe); KQL deferred
   optional module (superseded + unreleased draft + thin adoption).
5. **Parent pointers:** DETERMINED → no. Mutable `ref` + no borrow checker makes
   parent-maintenance correct-by-*discipline* — a footgun on every mutation;
   Roslyn/roxmltree only survive it via immutability/borrow-lifetimes we lack.

---

## 8. Live bugs found during the design review (independent of the rebuild)

1. **`skip()` swallows `ceError` in `cmAccumulating` mode** (`cursor.nim`) — on a
   broken token inside a skipped subtree it breaks early, leaving `depth`/
   `nodeFrames` inconsistent, which corrupts `decodeAll`'s recovery loop. A real
   correctness defect on the Cat-2 path. Fix: in accumulating mode, absorb
   `ceError` and keep skipping; only `ceEof` terminates early.
2. **`path.nim` is mislabeled as a Cat-3 DOM query DSL** — it actually traverses
   *typed decoded structs* (Cat-2 post-`decode[T]`) and has zero knowledge of
   `KdlNode`/names/args/props. So the "DOM query DSL" we thought we had doesn't
   exist (it's the §6.3 gap). Relabel it a Cat-2 typed-traversal helper; build the
   real Cat-3 traversal (`descendants`/`find` + conveniences) fresh.

---

## 9. R2 depth+breadth review — corrections + folded fixes + blockers

A 5-agent depth/breadth review (substrate/perf, cross-category coherence, Cat-2
codegen, Cat-3 DOM+preserve, completeness meta-critic) was run against this seed,
grounded in the actual code. It confirmed the direction but corrected several
load-bearing assumptions and surfaced four RFC-blockers. Determined fixes are
recorded here (they supersede the relevant earlier prose); the genuine fork and
the spec-assumption corrections are called out explicitly.

### 9.1 The foundation fork is three-way, not two — and the gate was wrong

**THE one true fork (measurement-decided): owned-strings (O) vs per-doc string
blob (B) vs arena (A).** The seed framed O-vs-A. The real contender is **(B): a
per-doc contiguous byte blob + `(offset: uint32, len: uint16)` indices on nodes.**
B has no interner, no hash table, no doc↔node cycle, **and no per-identifier heap
alloc** (one blob alloc; identifiers are pointer-bumps; `==` is `cmpMem`, zero
alloc; reads are `blob.toOpenArray`). Since the perf log already names *allocation*
as the #1 cost, B likely dominates O on realistic input. A (arena/`NodeId`) only
matters for cross-doc dedup, which the goals reject. **Real fork is O vs B.**

**The §4 measurement plan was unsound (DETERMINED corrections):**
- **126µs is the wrong gate** — wall-clock on WSL2 (±13% noise) and a *degenerate
  fixture* (`homogeneous-services-100.kdl`: 1 node name, 3 ≤8-byte keys, 100
  repeats) that maximally favors the interner. It tells you nothing about O/B on
  real docs.
- Gate on **callgrind instruction count + allocation count + RSS**, on **≥3
  fixtures incl. a new `mixed-names-200.kdl`** (≈30 distinct names, realistic key
  spread), baselined against the **current substrate**, not F.1.
- **Set an explicit threshold:** within **±20%** of baseline → take the simpler
  design; beyond → the alternative. ("Materially slower" was undefined.)
- **30-minute pre-work:** a callgrind isolation (current substrate vs the same
  with `ownerDocument` removed) to *confirm* the 38%/23% cycle/value split, which
  is currently unconfirmed wall-clock subtraction.
- **Day-one prototype: build (B), not (O)** — it's the likely winner and the more
  interesting measurement; fall back to O if B's blob bookkeeping doesn't pay.
- The RFC must contain an **(A) arena + (B) blob type sketch** as a contingency so
  it isn't internally inconsistent if the measurement picks one over O.

### 9.2 Spec-assumption corrections (escalated)

1. **`decodeNode[T](node)` → `decodeNode[T](doc, node)`.** Deleting `ownerDocument`
   removes the node's path to the token stream, so cursor-seek has nothing to seek
   into. **Decode is a *parse operation*, not a read accessor** — the "no `doc`
   param" doctrine (correct for `n.name`/`n.prop`) does not extend to it. The seed
   *and* hardening-RFC §5.1 conflated the two. `decodeNode`/`decodeChild` take a
   `doc` first-param (kdl-rs's `from_node` does the same). Determined, but it's a
   real API change vs the prior spec.
2. **milpa is NOT an nkdl consumer.** milpa parses KDL with its own Python parser;
   nkdl's only (potential) Nim consumer is amoxtli, which hasn't adopted. **The
   contract to honor is `rfc-api-v0.2-hardening.md §6` (the API surface)** — there
   are no deployed call sites to protect.
3. **The preserve narrative is aspirational.** The emitter decides on
   **dirty-flag + span** only; `parseHash` comparison is *not wired* (it's the
   planned finer-grained #284 path). The seed's "self-contained nodes don't change
   this" is true for the hash *bytes* but the RFC must state the two tiers
   explicitly so contributors don't think `parseHash` drives the current decision.

### 9.3 Boundary is a dependency graph, not a list (DETERMINED)

The "keep periphery untouched" framing understates the blast radius. Redraw as
three tiers:
- **REBUILD (design work):** `ast.nim`, `intern.nim` (delete under O/B),
  `doc_build.nim`, `doc_emit.nim`, **`conformance/adapters/nkdl.nim`** (hard-coupled
  to `InternedStr` — must be rewritten; the corpus + Lean proofs are genuinely
  reusable, the adapter is not).
- **ADAPT (mechanical):** `hashing.nim` (field-rename port, no design decisions —
  also: switch FNV-128 per-byte `mul128` → word-at-a-time/xxh3, gated `when not
  nimvm:`); `emitter.nim` (**drop the `InternedStr`/`Interner` overloads** → take
  `string`/`Option[string]`; makes it truly AST-agnostic); `cursor.nim` (audit and
  drop the **vestigial `intern` import** — verifies the "foundation-independent"
  claim); `derive_decode.nim` (the `doc_build`/`tokenAsString` edge + re-export of
  `ast`).
- **KEEP truly untouched:** `lexer`, `numlit`, `spans`, `fnv`, `grammar`, the
  conformance *corpus*, the Lean *proofs*.

### 9.4 Substrate determined fixes

- **Sidecar the parse-only metadata.** `span`/`parseHash`/`headLen`/
  `parseEntryCount`/`parseChildCount` belong in an **opt-in parallel array** on
  `KdlDoc` (allocated only when `preserveFormat`), not on the hot `KdlNode`/
  `KdlValue` structs (prior art: Swift `AttributedString` runs, LLVM `DILocation`).
  `KdlValue.span` comes off the base type entirely.
- **Drop `doc.mutated`; compute preservability lazily.** Once `ownerDocument` is
  gone, a child mutation can't reach the doc to set `mutated`. Don't re-thread a
  doc into mutators — compute `canPreserve(doc) = preserveFormat and
  sourceText.len > 0` at emit time; keep per-node `dirty`. (This is also the §6.3
  `canPreserve` the seed already wanted.)
- **Lay out the target `KdlNode`/`KdlValue` struct sizes explicitly** before
  coding (the owned-string layout will otherwise be designed accidentally).
- Re-document **thread-safety** ("single-thread-owned; `--mm:arc`-safe — no
  ref cycle") in the new `ast.nim` (the note currently lives in `intern.nim`,
  orphaned on its deletion). Note: stale `parseHash` from the interner era is
  invalidated by the rebuild → safe canonical fallback; document it.

### 9.5 Cat-2 codegen determined fixes (several were under-specified as "done")

- **Slot inference is unimplemented — and the current default is silently-wrong.**
  `classify()` has no `else` branch; an *unannotated field is silently dropped*
  from encode AND decode (a D3 violation, and it makes the seed's "zero-annotation
  config" produce an empty round-trip). Add the inference `else`:
  object/`ref`/`seq[object]`→child, else→prop (name-preserving). This must land
  before "strict-everywhere" means anything.
- **Native field defaults need real macro work.** `var v: T` zero-inits; it does
  NOT apply `port: int = 8080`. The macro must read the default expr from
  `IdentDefs[^1]` (the `regularFields` iterator doesn't read it today) and splice
  `v.field = <default>` when the required-slot bit is unset — only erroring when no
  default exists. For `embed[T]` (NimVM): `{.error.}` at macro time if a default
  expr calls a non-`noSideEffect` proc (e.g. `now()`). The design call (native
  defaults, no `kdlDefault` pragma) is right; the implementation is non-trivial.
- **The `mixin kdlDecodeValue` extension point doesn't exist and has a real
  tension.** To decode a custom scalar (`IpAddress` from `"1.2.3.4"`) the extension
  needs the *resolved value* → `kdlDecodeValue(v: var T; val: KdlValue; c):
  Result[void,ParseError]`. That couples Cat-2 to **`KdlValue`** (a value leaf,
  *not* the node tree) — acceptable if `KdlValue` lives in a shared low-level
  module both Cat-2 and Cat-3 import; state it. Also: fix `isOptionType`'s
  `$t[0]=="Option"` string-match → `bindSym"Option"` (breaks under qualified
  imports); add `getTypeImpl` distinct-unwrap before the type switch.
- **`strict-everywhere` × `kdlArgs`:** a `kdlArgs` (variadic) field absorbs all
  trailing args, so its presence must *replace* the strict-unconsumed-arg `else`
  with an append-collector; with no `kdlArgs` field, strict-unconsumed-arg is the
  default. Unknown *children* are currently lenient (skip) while props error —
  unify to strict + add the `{.kdlIgnoreUnknown.}` pragma (not yet declared).
- **Field-path errors:** add `ParseError.fieldPath: seq[string]` (distinct from
  `path` = filename); each child-decode boundary *prepends* its field name on the
  error path (`return r` → enrich-then-return). Empty on success (no alloc).
- **Node-name variant dispatch is hand-waved** — only inline-discriminator is
  built. Sharpen the seed: inline-discriminator = supported; node-name dispatch =
  the *consumer-side* `decodeNode[T]` pattern (no library work); library-level
  sum-type/untagged dispatch = deferred.
- **`ref T` child fields crash** `nodeNameOf` (`nnkRefTy` ≠ `nnkTypeDef`) and emit
  a `var T`-vs-`ref T` mismatch → add a `ckRef` child kind (alloc `new`, decode
  through `[]`). **`uint`/`uint8..64` fields** hit `error()` (unsupported) → add
  them with a negative-literal bounds check. **>64 required fields** silently
  overflow the bitmap → `{.error.}` at macro time.
- **`Parsed[T]` is defined nowhere** — define it (in `spans.nim`), use it for both
  `decodeAll` and `buildDocAll` (currently a bare tuple). `embed[T]` error →
  `{.error: formatError(...).}` (caret), not `doAssert hint`. Document that
  **`encode[T]` is always canonical** (typed-preserve is the Cat-3 `parse →
  decodeNode → mutate → emit` combo, deferred to v0.3 / nkdl#31).

### 9.6 Cat-3 determined fixes + live bugs

- **Live bug:** `prop(n, name)` returns the **first** match; KDL 2.0 is
  **last-wins**. Fix `prop` to return last, *or* guarantee the parser collapses
  dup keys at parse time and document `prop` as unambiguous (the simpler call).
- **Adjudicating `addProp` vs `setProp` (the two DOM reviewers split):** **drop
  `addProp`** — the parser collapses dup keys (last-wins), so a parsed DOM never
  has them; `addProp` only serves raw dup-key output, which is a footgun (call it
  twice thinking "set" → silent last-wins). Ship `setProp` (upsert) only; raw
  dup-key generation is `n.entries`-direct + `markMutated`.
- **Close the dirty-invariant footgun:** make `entries`/`childNodes` **not public
  mutable fields** (raw writes silently skip `dirty` → broken preserve). Expose
  `lent` read accessors + the mutation API; raw access is a `{.dangerous.}`-style
  escape, not a public field. (Illegal-states-unrepresentable, D-principle.)
- `descendants` must be an **iterative DFS** closure iterator (recursive inline
  iterators are illegal in Nim) — spell it out so it isn't reinvented wrong.
- **Slashdash is NOT represented in the DOM (v0.x)** — document that slashdashed
  content is dropped through parse→mutate→encode (matches kdl-rs); full
  slashdash-aware DOM is #284.
- Add **`clone(n)`** (deep-copy a subtree — trivial under owned strings, every
  non-trivial consumer needs it) and a **doc-free `$ ` on `KdlNode`** (natural
  once names are owned). Document NaN-equals-NaN structural `==` and the threading
  model. `find` returns the live ref (mutate through it); removal-of-found needs a
  root re-traverse; `findPath → seq[KdlNode]` filed for later.

### 9.7 RFC-blockers — resolve before/while writing the RFC

1. **Test-porting is *triage*, not a port.** The "676 green" figure is stale, and a
   chunk tests *deleted concepts*: `test_intern.nim` (the interner), ~44 lines of
   `interner.lookup(n.nameHandle)` white-box across `test_ast`/`build_doc`/
   `doc_emit`, and `test_owner_document.nim` (the deleted feature). **Classify every
   test file A (survives) / B (rewrite vs new substrate) / C (delete)** with counts
   before claiming a clean contract.
2. **Conformance adapter** (`conformance/adapters/nkdl.nim`) is in REBUILD (§9.3);
   the conformance gate is dark until it's rewritten — sequence it right after
   `ast.nim` stabilizes.
3. **§11 supersession table + fate of uncommitted work.** The current F.2.5/F.3
   work is uncommitted; the rebuild **cancels F.3 (`ownerDocument`/`adopt`)**, keeps
   F.2.5's intent (tombstones never exist), and **remaps** `decodeNode` after the
   rebuild. The RFC needs a table marking each hardening-RFC item
   surviving / cancelled / remapped, and the hardening RFC needs a "superseded —
   see core-rebuild RFC" header. Decide the fate of the green-but-uncommitted
   branch (commit as a labeled checkpoint to cherry-pick tests from, vs discard).
4. **Perf threshold + arena/blob sketch** — see §9.1.

### 9.8 Required RFC sections (completeness)

- **Interner deletion reopens two filed issues:** Unicode NFC/NFD (nkdl#36) — byte
  equality is now *unconditional*, "nkdl does not normalize; caller's
  responsibility"; and the DoS allocation profile (nkdl#32) — owned-strings/blob
  change the per-identifier alloc count (depth is still capped by
  `MaxParserDepth`). One paragraph each.
- **`embed[T]` is Cat-2-only:** the rebuilt ref-AST DOM is not NimVM-compatible;
  `decodeNode` / any DOM path cannot be embedded. Accepted limitation, state it.
- **`--mm:arc` safety:** confirm no `KdlNode`↔`KdlDoc` cycle under the chosen
  foundation (true for O/B; check for A).
- **Versioning/publish/stability** — defer to post-adoption, but **file the issue**
  now (defer = file now). **CI gap:** proptest + the conformance adapter aren't in
  CI (the adapter rewrite must be locally verified before merge); note it.

---

## 10. Execution plan (clean-branch, measure-first, monotonic green-net)

A 3-agent execution review (port-order DAG, test-triage/green-net, staged build)
produced a consistent plan. The RFC expands the slices; this is the spine.

### 10.1 Module dependency facts (verified against real imports)

- **DAG is acyclic.** Highest blast radius: `ast` (9 direct dependents — REBUILD,
  lands first) and `spans` (12 — but KEEP). `intern` (8 dependents) is the delete
  target.
- **`cursor`'s `import ./intern` is provably dead** (zero symbols used) — drop it;
  that's the entire `cursor` adaptation.
- **New fork (resolved → extract): `tokenAsString` lives in `doc_build`, and
  `derive_decode` imports `doc_build` *only* for it.** It uses only
  `Token`/`TokenStream`/`string` (lexer types). **Extract it to `token_text.nim`
  (or fold into `lexer`)** — this cuts the `derive_decode → doc_build` edge,
  removes the Cat-3-builder-into-every-Cat-2-consumer namespace leak, and lets
  Cat-2 codegen land independent of the `doc_build` rebuild. Determined; do it.

### 10.2 Port order + per-module classification (VERBATIM / ADAPT / REBUILD / DELETE)

1. **Leaves (VERBATIM):** `spec_literals`, `fnv`, `pragmas`, `path` (rename to a
   Cat-2 `typed_path` is doc-only), `spans` (+ define **`Parsed[T]`** here).
2. **`intern`** — staging VERBATIM, then **DELETE** after `ast` lands (under O/B).
3. **`ast` — REBUILD** (the foundation gate): self-contained owned-string nodes,
   `Option[string]` annotation, no `InternedStr`/`ownerDocument`/`adopt`, `==`
   string-compare, parse-metadata **sidecar** on `KdlDoc` (opt-in), hidden
   `entries`/`childNodes` + `lent` read accessors, `clone`, doc-free `$`, `prop`
   last-wins, thread-safety note. **O-vs-B layout is the one true fork — locked by
   the Stage-0 measurement before fields are committed.**
4. **`lexer`, `numlit`** — VERBATIM.
5. **`cursor` (ADAPT: drop dead `intern` import; add `resolveValue` + `depth()` in
   concept), `doc_build` stub + `parser` (ADAPT)** → **FIRST-GREEN-BUILD + the
   Stage-0 bench.**
6. **`hashing` (ADAPT:** owned-string bytes; FNV word-at-a-time/xxh3 gated
   `when not nimvm:`**), `reserved` (VERBATIM/minimal), `emitter` (ADAPT:** drop
   `appendInternedAnno` + the 3 `InternedStr` overloads — then truly AST-agnostic**),
   `doc_build` full (REBUILD).**
7. **`doc_emit` (REBUILD), `grammar` (ADAPT** — a differential oracle, off the
   critical path, adapt late).**
8. **`derive_decode` (REBUILD:** §9.5 codegen fixes**), `derive_encode` (VERBATIM).**
9. **`kdl_block` (VERBATIM), `api` (ADAPT:** `decodeNode(doc,node)`, `Parsed[T]`**),
   `nkdl` (ADAPT:** drop `export intern`**).**
10. **`conformance/adapters/nkdl.nim` — REBUILD** (drop interner; plain-string
    field reads). The corpus + Lean proofs are untouched.

### 10.3 Staged build (each stage = a working, benchable, partially-green checkpoint)

- **Pre-Stage:** commit current green tree as `checkpoint/pre-rebuild-*` (cherry-pick
  source); run the **30-min callgrind isolation** to confirm the 38%/23% split;
  create `benchmarks/fixtures/mixed-names-200.kdl`; do the A/B/C **test triage**.
- **Stage 0 — foundation gate:** `ast2` (prototype **B** first) + minimal parse +
  `stage0_gate.nim`; **callgrind I-refs + allocations + RSS on 3 fixtures; ±20%
  threshold** picks O/B; record `docs/stage0-measurement.md`. *Nothing else
  proceeds until this number exists.*
- **A** new `ast` (lands the §9.4/§9.6-structural fixes) → **B** `doc_build` +
  **conformance-adapter rewrite** (closes the dark window) → **C** `doc_emit`/
  `emitter` + `Parsed[T]` → **D** `derive_common` + **codegen correctness FIRST**
  (the silent-drop `classify` bug, `bindSym`, distinct, `ckRef`, `uint`, 64-field) →
  **G′** Cat-1 `skip`/`ceError` + `resolveValue` (**moved before E** — `decodeAll`
  recovery depends on it) → **E** Cat-2 features (native defaults, `mixin
  kdlDecodeValue`, `decodeNode(doc,node)`, field-path) → **F** Cat-3 surface
  (`descendants`/`find`/conveniences/`clone`, drop `addProp`, relabel `path`) →
  **H** error model (stable codes, severity, caret, did-you-mean) → **I** proptest
  + CI → **J** §9.8 completeness + supersession + cutover. **~90 TDD slices,
  ~3–4 weeks.**

### 10.4 Green-net, conformance gate, CI

- **Monotonic unlock:** first green test is `test_spans.nim` (day one); each ported
  module brings its tests; verification only grows. Test split: **~73% A** (verbatim),
  **~24% B** (mechanical: `interner.lookup(n.nameHandle)`→`n.name`,
  `intern("x")`→`some("x")`, drop `initInterner()`), **~3% C** (`test_intern`,
  `test_owner_document` — delete).
- **Pin characterization tests BEFORE touching `ast`:** byte-exact preserve; the
  **self-containedness proof** (`let n = parse(s).get.node("x"); discard doc; check
  n.name == "x"` — impossible under handles); cross-doc `==`; the parser-as-
  conformance baseline.
- **Conformance dark window (Stage 0→B):** a **compile-only `adapter-compiles` CI
  gate that is *expected-red* and visible** (not silent), flipped to run-and-pass
  at Stage B, and a **hard merge gate**. CI: `test` (blocking) + `adapter-compiles`
  (blocking) + `proptest`+full-corpus (merge gate) + `perfGuard`.

### 10.5 Cutover

F.3 (`ownerDocument`/`adopt`) is **cancelled** (Stage A makes it never exist);
F.2.5's intent is preserved by construction — **nothing to cherry-pick from the
uncommitted work.** The §11 supersession table marks each hardening-RFC item
surviving / cancelled (F.3) / remapped (`decodeNode`); the hardening RFC keeps its
API-surface spec and gets a "superseded — see core-rebuild RFC" header on the F.x
sections. Retire `checkpoint/pre-rebuild-*` after 30 days.
