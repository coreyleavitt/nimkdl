# RFC: nkdl v0.2 — consumer-driven API hardening

> **SUPERSEDED (2026-06-03) → see [`rfc-core-rebuild.md`](rfc-core-rebuild.md).**
> Its substrate phases (F.0–F.6, the `ownerDocument`/`adopt`/ref-vs-arena material)
> hit a +61% parse regression from the doc↔node ORC cycle and were **cancelled**;
> the core was re-founded on self-contained owned-string nodes. That rebuild has
> **LANDED** — the interned core (`ast`/`intern`/`doc_build`/`doc_emit`) is deleted,
> the self-contained core is live, full suite green (conformance 338/338, byte-exact
> preserve 243/0). This RFC's surviving **API surface** (Parsed[T], strict-default
> decode, field-path errors, the codegen-fix list) is folded into
> `rfc-core-rebuild.md` §8/§10/§13 — read that for the live spec. Kept here for the
> R1 review record + the disposition table in `rfc-core-rebuild.md` §13.

**Status:** SUPERSEDED — Draft, phases proposed and **depth-reviewed (R1)**. The core mechanism
forks are **determined** (§10); a 5-agent depth/breadth review then corrected the
substrate (`ptr`→`ref` on soundness), designed the nested-node cursor fence, fixed
the error-construction model, and surfaced ~30 determined fixes (folded in). The 4
apparent scope forks it raised all **resolved to determined** under the best-in-class
lens (§10); the only genuine residue is two filed v0.3 issues (fix-its, DoS bounds).
**Date:** 2026-06-02
**Inputs:** `docs/CONSUMER-FEEDBACK-amoxtli.md` (first external consumer); a
four-axis first-principles audit (API shape, decode/codegen, error/diagnostics,
test-coverage); and an **R1 depth review** by 5 parallel agents (data-model/lifetime,
API-coherence, typed-codegen, error/proof-bridge, completeness meta-critic).
**Related:** `docs/rfc-conformance-assurance.md`, `docs/rfc-three-categories.md`.

---

## 1. Diagnosis — why a "good, ergonomic" API had ~10 holes on first contact

The holes are not independent. They are two faces of one root cause.

### 1.1 The library was validated against itself, not against a consumer

Every audit axis converged here. nkdl's tests exercise the library's **own happy
path**: types declared through the `kdl:` block, whole-source symmetric
encode+decode, homogeneous top-level node lists, self-recursive trees. A real
consumer (amoxtli) does **none** of those:

- hand-declares types with explicit `*` exports and explicit `deriveDecode(T)`,
- decodes **heterogeneous, multi-section** files by walking nodes and dispatching
  by name,
- uses **decode-only** variant schemas (never encoded back),
- renders **line/col diagnostics** for user-authored KDL.

All four shapes have **zero test coverage**. The export-marker bug (item D) was
not a fluke — it is the *signature* of the disease: the field path a real
consumer writes (`field* {.pragma.}`) was never run, because the `kdl:` block —
the only tested declaration path — emits fields *without* `*`.

### 1.2 The clean-core rebuild optimized one axis and amputated the others

The rebuild collapsed typed decode onto a single streaming-cursor path
(deleting the DOM→typed "AST-walk" codegen) and compacted `Span` to
offset/length (dropping stored line/col). Both were defensible perf/simplicity
wins **in isolation** — and both removed exactly what a config consumer needs
(node-level decode; self-describing errors). The first real consumer fell
straight into the holes the rebuild dug.

### 1.3 The through-line

This is the **same meta-problem as the conformance/proof discussion**: we
validate the parser against the *spec*, but we validated the typed-codegen *API*
against the author's own usage. "Ergonomic" was a self-assessment that never met
an adversary. The structural fix (Phase 3) is therefore not just "add tests" — it
is to make a **demanding consumer's usage shapes a permanent, first-class part of
the test suite**, so this class of hole cannot reappear.

---

## 2. Design principles & guardrails

**Non-goal: backwards compatibility.** nkdl has **no real consumers** — amoxtli
hit a hard wall and has not adopted. So API preservation, deprecation windows,
additive-only overloads, and "absorb the breaks once" batching are all explicitly
out of scope. We design for the **ideal end state** and change any signature,
return shape, type, or default freely. Carry zero compromises for compatibility.
The only things that gate a change are the principles below, not existing callers.

The redesign is governed by an explicit doctrine the original surface lacked.

**D1 — Errors are self-sufficient values.** A `ParseError` must render a complete
human diagnostic *on its own* (`$err` → `file:line:col: message`) with no need to
re-pass source. The `Result[T, E]` contract is only honored if `E` is honored.

**D2 — The no-raise boundary is real.** Public entry points
(`parse`/`parseAll`/`decode`/`decodeAll`/`encode`/`embed`) either carry
`{.raises: [].}` or document *precisely* what they can raise. A parser whose
contract is "errors are values" must not panic out of a `Result`.

**D3 — Fail loud, never silently wrong.** Where the library cannot do the right
thing, it errors — it does not silently degrade (canonical-instead-of-preserve,
foreign-interner-handle, truncated big-int) and call it done.

**D4 — One source of truth for cross-cutting logic.** `fieldInfo`, pragma
parsing, and field iteration exist **once**, shared by encode and decode. A bug
fixed in one is fixed in both by construction (this is why item D was a
double-bug).

**D5 — Design the interface for the ideal, not for the current implementation's
convenience.** Choose the signature the best end-state wants
(`decodeNode[T](node, doc)`), then build the implementation to match it — not the
reverse. (There are no callers to preserve, so this is unconstrained; the only
discipline is D6 — don't reach the clean interface via a second path that has to
be differentially validated.)

**D6 — Consistent by construction, not by differential test.** Never introduce a
second computation of the same thing (a second tokenizer, a second decoder) that
must be *proven equivalent* to the first. Reuse the one tokenizer and the one
decoder so alternate entry points agree with the main path **structurally**, not
by a test we hope is exhaustive. This is the single-tokenizer/single-decoder rule;
it is what kills span-slice node-decode (a redundant tokenization) and the
revived-DOM-decoder (a redundant decoder) in favor of cursor-seek (§5).

**Perf guardrails** (these are hard constraints on the designs below, not
aspirations):

- **G-perf-1:** the benchmarked hot paths — `parse` and streaming `decode[T]` —
  must not regress. Every item below lands on a *new* surface, the *error* path,
  or compile time. Verify with the existing `tests/bench` gate before/after.
- **G-perf-2 (the line/col trap):** never build a `LineMap` on the *success*
  path. Line/col is computed lazily, once, at `ParseError` *construction* time
  (errors are rare), never per-parse.
- **G-perf-3:** node-level decode must not force token-stream/source retention on
  docs that never call it. Retention, if any, is opt-in.

---

## 2.5 Cluster 0 — the value & read-access substrate (the round-1 audit gap)

**This is the foundation; everything else sits on it.** The first audit was
breadth-first on the *API surface* (shape, codegen, errors, tests) — **no agent
had a memory/ownership/aliasing lens**, so it caught the surface symptom (`arg`'s
`kvNull` sentinel) and missed the substrate. A second, memory-model audit found:

- **C0-a — Reads copy, by value.** `child`/`node`→`Option[KdlNode]` deep-copy the
  subtree's `entries`/`children` seqs (ORC value semantics); `arg`/`prop` copy the
  owned `kvString`. Cost on every read, and the result is **detached**.
- **C0-b — Lossy + false-independent reads (footgun).** Mutating a read-returned
  node does **not** propagate to the doc; the copy's relationship to the doc is
  silent and confusing. The `var KdlNode` mutation API cannot enforce that the
  node being mutated lives in the doc.
- **C0-c — Non-POD values for no reason.** `KdlValue.kvString` is an owned
  `string` while names/keys/annotations are `InternedStr`. Interning values too
  makes `KdlValue` POD (cheap copies, dedup, one uniform ownership model).
- **C0-d — Unguarded cross-doc handles (Critical).** A value/node carrying doc-A's
  `InternedStr` inserted into doc-B encodes silently-wrong; `migrateValue` is a
  manual escape hatch that doesn't cover node names / child handles. (This is
  Cluster 6's footgun, but its *root* is the ownership model, not a stray check.)
- **C0-e — `lookup` always allocates** (`resolveName`, `namedProperties`): no
  zero-copy read path for interned strings.

**Determined direction (first-principles):**
- **Intern all strings → POD `KdlValue`.** Values already couple to the doc via
  `typeAnnotation`; finishing the job makes copies trivial and dedups. (Open: a
  hybrid for very large unique blobs — measure first.)
- **Reads return non-copying access, not value copies.** This makes presence free
  (so `has*` is genuinely redundant — the real resolution of the 1.3 question),
  removes the lossy/stale footgun, and makes mutation coherent.
- **`ownerDocument` on nodes** (W3C-DOM model) kills C0-d *by construction* — a
  node resolves against its own interner, so accessors drop the `doc` param and a
  foreign pairing is unrepresentable; cross-doc insert auto-adopts. (Supersedes the
  earlier "doc-scoped handle / debug assert" sketch — see the decision below.)

**The read/mutation mechanism — DECIDED via the F.0 `/architect` round (4 designs:
arena+handles, borrow/`lent`, ergonomic-`ptr`, `ref`-AST).** Outcome:

- **Value model: keep the owned `string` in `KdlValue.kvString` (do NOT intern
  values).** The interner's SBO is tuned for short *repeating identifiers*;
  feeding it one-off values defeats dedup and forces heap entries, and interning
  would break `newStringValue` as a doc-free constructor. Values aren't the copy
  problem — nodes are. (Overrides the arena design's POD pitch; 3 of 4 agreed.)
- **`lent` is eliminated** — the borrow agent proved Nim only honors `lent` for
  *direct indexed* returns, silently copying through search/dispatch. Pure-borrow
  is not viable.
- **Node reads: `ref`-AST primary** (`KdlNode`→`ref`, `KdlDoc`→`ref`; reads return
  the node, `nil` = absent; mutation-through-`ref` drops `var`-threading; `has*`,
  `Option[KdlNode]`, sentinels, and **`probeKdlNodeCopy` all delete themselves**).
  This is consistent-by-construction (D6) and idiomatic. **Arena (contiguous flat
  store + `NodeId` handles) is the named fallback** — structurally closest to
  kdl-rs's contiguous `Vec` layout, hence the more perf-defensible model if the
  DOM-build benchmark (below) can't be met by `ref`+pool.
- **Value reads keep `Option[KdlValue]` (1.1) as the owning default**, plus
  `argRef`/`propRef: ptr KdlValue` zero-copy fast-paths (grafted from the
  ergonomic design). Both preserve missing-vs-`#null`.
- **`ownerDocument` — the C0-d resolution (revised; supersedes the docId-assert
  sketch).** Now that `ref`-AST makes nodes heap objects, every `KdlNode` carries a
  back-reference to its owning doc — exactly the **W3C DOM `ownerDocument`** model
  (cross-doc moves there go through `adoptNode`). This *dissolves* the cross-doc
  footgun instead of detecting it, and it deletes the `doc` parameter from the
  entire node-accessor surface:
  - A node resolves its interned strings against **its own** interner — you can no
    longer pair a node with a foreign doc, because accessors no longer *take* a doc.
    `n.name`, `n.child("x")`, `n.prop("x")`, `n.children`, `n.children("x")`,
    `n.arg(i)` — no more `doc` threading. (The old `n.child(doc, "x")` /
    `doc.resolveName(n)` threading was a smell that only existed because value
    nodes couldn't hold their doc.)
  - **Cross-doc insert auto-adopts:** `addChild(parent, c)` where
    `c.ownerDocument != parent.ownerDocument` re-homes `c` into `parent`'s doc.
    This is the W3C `adoptNode` operation and it is **O(subtree)**, not O(1): every
    node in `c`'s subtree must have each of its interned fields (node `name`, every
    property key, every `typeAnnotation`) **re-interned** from the source doc's
    interner into the destination's, and its `ownerDocument` repointed. The cost is
    disclosed, not hidden; it is paid once at insert, off every read path.
  - **Values made self-contained — concretely:** `KdlValue.typeAnnotation` is the
    one interned field on a bare value. "Portable" means: on cross-doc value insert
    (`addArg`/`setProp` with a foreign value), the destination mutator re-interns
    the annotation into its own interner — the same adopt step, scoped to one field.
    A lone `KdlValue` in flight between docs is therefore re-homed at the boundary,
    never compared raw. C0-d is then **gone**, not guarded — no `docId`, no assert.
  - **Owner back-ref type — DETERMINED `ref KdlDoc` (the `ptr` lean was unsound).**
    The depth review (data-model + meta-critic, independently) showed `ptr KdlDoc`
    is **not** a measurable engineering trade — it is a **memory-safety defect**:
    ORC does not trace `ptr` fields, so a `KdlDoc` can be collected while nodes
    derived from it are still live, leaving every accessor dereferencing a dangling
    pointer (use-after-free). `InternedStr` handles do *not* have this problem
    (they are integers; a stale handle mis-resolves, it does not crash) — the
    analogy that justified `ptr` was false. The owner is therefore `ref KdlDoc`: it
    keeps the doc alive exactly as long as any of its nodes are reachable, which is
    the correct lifetime. The resulting doc↔node reference cycle is handled by ORC's
    cycle collector by design (W3C DOM, Roslyn, roxmltree all use a managed
    back-reference, never a raw pointer, for exactly this reason). The F.5 bench
    already locked `ref`-AST on perf; the cycle-scan cost rides on that same gate
    and was within it.

**Perf contract (no omission — we measure against real comparators, not our own
old numbers):**
- The benchmarked **typed/cursor paths are DOM-free** (`decode[T]`/`encode[T]` are
  cursor↔struct since #299; lex/cursor are token-based) → the substrate rework
  **cannot touch them**; they stay at **knus-parity** (refreshed).
- DOM **reads** get *faster* under `ref` (the value-copy `child().get` was a perf
  *bug* — that's why `probeKdlNodeCopy` exists).
- DOM **build** (`parse()`→tree) is the one real cost of `ref` nodes. It is
  **gated on a refreshed head-to-head vs kdl-rs** (which does exactly this, with
  format preservation). `ref`+slab-pool must reach parity; if it can't, fall back
  to the contiguous **arena**. "Nobody parses to a DOM at speed" is **not** an
  available excuse — kdl-rs is precisely that comparator. Every axis, including
  any we trail, is published.
- The current cross-impl numbers are **stale (pre-rebuild)**; no competitiveness
  claim is made until the refresh lands.

**Consequence:** `§8.1`'s "absence→`Option`" and the `1.x` accessor cycles are
**provisional** until C0's read model is chosen. The value accessors already
built (`1.1 arg→Option[KdlValue]`, `1.2 args`) largely survive once values are POD
(a POD `Option` is cheap, and args are read-leaves); the **node** accessors
(`child`/`node`/`children`/`nodes`) and the mutation API are what C0 reshapes.

---

## 3. Phase overview

Phases are ordered so each leaves the tree green and the migration progressively
unblocked. Phase 3 may run in parallel with 1–2 (different files).

| Phase | Theme | Clusters | amoxtli items | Blocks migration? | Risk |
|------:|-------|----------|---------------|-------------------|------|
| **0** | No-fork unblockers | — | C, E | partial | trivial |
| **1** | Node/DOM typed decode (cursor-seek) | 1 | **A**, G | **yes** | medium |
| **2** | Self-describing error contract | 2 + 3 | B, H, C(resid) | no (ugly w/o) | medium |
| **3** | Codegen single-source + close the test blind spot | 4 | D(general), F | no | low–medium |
| **4** | Hardening: asymmetry + footguns | 5 + 6 | — | no | low (breaking) |

---

## 4. Phase 0 — No-fork unblockers (land immediately)

Small, low-risk, no design decision. Two trivial items (C, E).

> **Item D is NOT here.** A standalone hot-fix that added a `bareName` helper to
> *both* `derive_decode.nim` and `derive_encode.nim` was written and then
> **reverted** — duplicating the peel into the two files would have deepened the
> very `fieldInfo` duplication that *made D a double-bug*, violating D4. The fix
> belongs in the unified `fieldInfo` and lands in **Phase 3.1**, once.

### 4.1 — `sourcePath` on `decode`/`decodeAll`/`embed` (item C)

- **Change:** add `sourcePath = "<input>"` to the three typed entry points,
  mirroring `parse`:
  - `src/api.nim:38` `proc decode*[T](src: string; sourcePath = "<input>"): Result[T, ParseError]`
  - `src/api.nim:89` `proc decodeAll*[T](src: string; sourcePath = "<input>"): tuple[value: T, errors: seq[ParseError]]`
  - `src/api.nim:125` `proc embed*[T](src: static[string]; sourcePath: static[string] = "<input>"): T`
- **Plumb:** thread `sourcePath` into the internal `lex`/cursor construction so it
  reaches the `KdlDoc`/error path; it becomes the filename Phase 2 attaches to
  `ParseError`.
- **Tests:** `tests/test_api.nim` — a decode error from a named source carries the
  filename (assert once Phase 2 lands; until then assert the param compiles and is
  accepted).
- **Acceptance:** the three entries accept `sourcePath` (default kept purely for
  call-site ergonomics, not compatibility).

### 4.2 — Fix stale `embed` docs + changelog (item E)

- **Change:** drop the `.get` from the two doc examples that show `embed[T](…).get`
  on a value of type `T` (which won't compile):
  - `README.md:45`
  - `src/nkdl.nim:33`
- **Add:** a one-line migration note (CHANGELOG, create `CHANGELOG.md` if absent):
  *"v0.2: `embed[T]` returns `T` (was `Result[T, ParseError]`); malformed input
  now fails the build. Drop `.isOk`/`.get`."*
- **Acceptance:** docs compile if extracted as examples; changelog records the
  breaking change.

### 4.3 — Document the `decodeAll[T]` seq constraint

- **Change:** the `when not (T is seq)` guard at `src/api.nim:~98` emits a compile
  error but the constraint is undocumented. Add it to the proc doc and the README
  API table (`README.md:52`): *"`decodeAll[T]` requires `T` to be a `seq` — it
  decodes every top-level node and collects per-node errors."*
- **Acceptance:** README + proc doc state the constraint.

**Phase 0 exit:** suite green; amoxtli C, E closed (D moves to Phase 3.1, F/B/A
follow); the `sourcePath` plumbing is in place to feed Phase 2.

---

## 5. Phase 1 — Node/DOM typed decode (the migration unblock)

**Cluster 1 · amoxtli A (CRITICAL) + G.** This is the blocker. The canonical
config pattern — *parse once → walk top-level nodes → dispatch by name → decode
each node into its own type* — is currently inexpressible: `decode[T]` runs a
cursor from the **start of source** and only expresses "one node of type `T`"
(`decode[T]`) or "many nodes of one type `T`" (`decode[seq[T]]`). A doc whose
top-level nodes are **different** types has no typed path.

### 5.1 Target interface (stable — D5)

```nim
## Decode a single, already-parsed node into `T`.
proc decodeNode*[T](node: KdlNode): Result[T, ParseError]

## Sugar: decode the (first) named child of `parent` into `T`.
proc decodeChild*[T](parent: KdlNode, name: string): Result[T, ParseError]
```

- **No `doc` parameter — F.3 ordering is load-bearing.** Phase 1 is built **after
  F.3** (see §11), so these inherit the `ownerDocument` surface: the node knows its
  doc, the token stream and source hang off `node.ownerDocument`, and there is no
  `doc` to thread. The earlier draft's `decodeNode[T](node, doc)` violated D5 (it is
  *not* the end-state signature — §2.5's F.3 deletes `doc` from the whole accessor
  surface) and is struck. Implementing Phase 1 before F.3 would build the wrong
  signature and re-derive it — the exact built-twice trap §1 warns against.
- No `source` parameter either: cursor-seek (§5.2) reads the doc's *retained token
  stream*, so node-decode needs neither the source string nor a re-lex. (`source`
  threading was an artifact of the rejected span-slice impl.)
- Returns the *same* `Result[T, ParseError]` as `decode[T]` — symmetric error
  handling, no new shape.

### 5.2 Mechanism — DETERMINED: cursor-seek (not opinion-based)

The interface (5.1) admits three implementations; under the best-in-class lens
(principle **D6**) only one is correct — this is *not* a free design choice.

| Mechanism | One tokenizer? | One decoder? | Consistent by construction? |
|-----------|:--------------:|:------------:|:---------------------------:|
| span-slice → reparse | ✗ (re-lexes the node's bytes) | ✓ | **✗ — must prove substring-lex ≡ in-context-lex for every node shape/boundary** |
| revive DOM→typed codegen | ✓ | ✗ (second decoder) | ✗ — must prove the DOM decoder ≡ the streaming decoder |
| **cursor-seek** | **✓** | **✓** | **✓ — same tokens, same decoder, just a different start index** |

**cursor-seek is the only option that reuses both the one tokenizer and the one
(concrete, fast) `kdlDecode`.** span-slice's re-lex is a *redundant tokenization
that must be differentially validated* (real failure surface: does `KdlNode.span`
include the node's `(type)` annotation? its terminator? a node whose in-context
lex differs from its in-isolation lex silently decodes wrong) — exactly the
class of bug D6 exists to forbid. Reviving the DOM decoder reintroduces the
second-decoder duplication #299 removed. cursor-seek is consistent with the main
path *structurally*, with nothing to prove.

It is also cheap: `StringCursor` already supports `pos`/`seek`/checkpoints
(audit-confirmed), and the decoder is concrete-on-`StringCursor`, so there is **no
genericity/indirection tax** — we run the *exact* generated decoder, just seeded
at the node's first token. The only honest cost is retention (below), made opt-in
per **G-perf-3**.

### 5.3 Steps (cursor-seek)

1. **`src/ast.nim` — `KdlNode` carries its token range.** Add
   `firstTok*, lastTok*: int32` to `KdlNode` (the half-open token-index span the
   node occupies). The DOM builder (`doc_build.nim`) already consumes
   `CursorEvent`s that carry token indices (`nodeNameTok`, …); record the node's
   first/last token as it builds each node. (Spans on `KdlNode`/`KdlValue` stay
   byte-based for diagnostics; the token range is the decode handle.)
2. **`src/parser.nim` / `KdlDoc` — opt-in *token-stream* retention only.** Source
   is **already** retained unconditionally (`doc.sourceText` is set in
   `doc_build.nim` for both `buildDoc` and `buildDocAccumulating` — meta-critic A3);
   the earlier "source retention" framing was based on a false premise. So the only
   thing to gate is the `TokenStream`. Add
   `parse*(source; sourcePath; preserveFormat; retainTokens = false)`; when
   `retainTokens`, move the `TokenStream` onto `doc.tokens`; otherwise free it as
   today (**G-perf-3**). `decodeNode` asserts/errs with a clear message if called on
   a doc parsed without `retainTokens`.
   - **`decodeNode` is DOM-parse-only — state it explicitly.** It requires a
     `KdlDoc` produced by `parse()`. The streaming `decode[T]`/`decodeAll[T]` paths
     never build a `KdlDoc` and never retain tokens, so node-decode is structurally
     unavailable on their output. A consumer who wants node-decode parses with
     `parse(retainTokens = true)`, not `decodeAll`. (This is the honest limitation
     meta-critic B3 flags; it is recorded, not hidden.)
   *(The flag-vs-always-retain shape remains the one residual choice — see §10,
   updated to note the flag is near-redundant with the consumer's own call.)*
3. **`src/cursor.nim` — seed a *fenced* cursor at a token range (DETERMINED — the
   nested-node correctness fix).** A naïve `seek(firstTok)` with the default initial
   state (`csTopLevel`, `depth = 0`) is **wrong for a node that lives inside a `{…}`
   block**: the cursor would run past `lastTok`, hit the *parent's* closing `}`,
   `dec depth → -1`, corrupt `nodeFrames`, and consume sibling tokens (meta-critic
   A1 — the first amoxtli case, `daemon { port 8080 }`, has children and trips this
   immediately). The fix has two parts, both determined:
   - **Balanced span invariant.** `(firstTok, lastTok)` must be the node's *own*
     balanced token range — it includes the node's own children braces but **not**
     the parent's. A well-formed node's token span is brace-balanced by
     construction, so seeding at `csTopLevel, depth = 0` is correct: the cursor
     opens and closes only braces it owns. The DOM builder must record the range to
     satisfy this (assert balance in debug).
   - **Fence at `lastTok`.** `initStringCursorAt(stream, source, firstTok, lastTok,
     mode)` carries an upper fence: the cursor treats `lastTok` as its terminal
     boundary and never advances past it, so it can never read a parent-context
     token even if a span were mis-recorded. The fence is the structural guarantee;
     the balance invariant is why `depth = 0` is the right seed. No new lexing.
   This keeps `decodeChild` (a *nested* node by definition) expressible — the
   alternative "top-level-only `decodeNode`" was rejected because it would gut the
   committed `decodeChild` surface (honor-the-spec).
4. **`src/api.nim` — `decodeNode[T]`:** resolve `doc = node.ownerDocument` (F.3),
   seed a fenced cursor at `[node.firstTok, node.lastTok]` over `doc.tokens` (+
   `doc.sourceText`, already retained unconditionally — see step 2), `var v: T`,
   `kdlDecode(v, cursor)`, return `ok(v)`/`err`. Error spans are already in
   original-source coordinates — **no rebasing needed** (another correctness win
   over span-slice; the word "rebased" in the Phase 2 draft was a stale span-slice
   carry-over — struck in §6.1). Attach `doc.sourcePath`.
5. **`src/api.nim` — `decodeChild[T]`** = `parent.child(name)` → `decodeNode[T]`
   (`nil` ⇒ `err(peTypeMissingRequired, …)`).
6. **Item G:** `decodeNode` resolves the generated `kdlDecode` via the existing
   `mixin` (same module). Document `decodeNode` as *the* supported node entry; do
   not advertise the generated `kdlDecode` as public.
7. **Re-export** `decodeNode`/`decodeChild` from `src/nkdl.nim`; README API table
   under Cat-2; document that node-decode requires `parse(…, retainTokens = true)`.

### 5.4 Tests (the real-consumer shapes — also serve Phase 3)

New `tests/test_decode_node.nim`:

- **Heterogeneous multi-section doc** — the amoxtli `applyDoc` shape:
  parse `daemon { … } provider { … } permissions { … }` once, walk `doc.nodes`,
  `case n.name` (F.3 — no `doc` thread) → `decodeNode[Daemon]` /
  `decodeNode[Provider]` / `decodeNode[Permissions]`; assert each populated field +
  that an unknown top-level node is skipped (forward-compat).
- **Single-node extract** — the `permission_hook` shape:
  `doc.node("hook")` (`nil`-check) → `decodeNode[Hook]`; assert fields.
- **`decodeChild[T]`** sugar — `parent` with a *nested* named child decodes
  (exercises the fenced cursor, step 3); missing child ⇒ `err`.
- **Original-source error coords** — a malformed value *inside* the third section
  yields an error whose `span.offset` points into the *original* source (line/col
  correct once Phase 2 lands); no rebasing, no slice.
- **Nested children (the fence regression)** — a section with its own `kdlChild`
  seq round-trips through `decodeNode`; a sibling node *after* the decoded one is
  untouched (proves the fence halts at `lastTok` and never bleeds into siblings —
  the meta-critic A1 case).

### 5.5 Acceptance

- The 9-section heterogeneous config shape decodes by walk+dispatch with **no
  consumer-side source re-slicing**.
- `permission_hook` single-node extract is a one-call `decodeNode`.
- Error spans from `decodeNode` are in original-source coordinates.
- `parse` + streaming `decode[T]` benchmarks unchanged (**G-perf-1**).

---

## 6. Phase 2 — The self-describing error contract

**Clusters 2 + 3 · amoxtli B, H, residual C.** Combined because they are one
thing: the consumer-facing *error contract*. Today `ParseError` is
`{code, span(offset,length), hint}` — it cannot render a human diagnostic without
the caller re-passing source **and** filename, and the public entry points can
still panic a `Defect` out of the `Result`.

### 6.1 Self-describing `ParseError` (item B; principle D1)

### Mechanism — DETERMINED: eager-on-error (not opinion-based)

A `ParseError` must be a **self-contained value** — serializable, with no lifetime
coupling to the source string. That single requirement decides it:

- **eager-on-error [chosen]** — at `ParseError` *construction*, compute
  `(line, col)` from source and store them on the error, plus `path`. The error is
  then a pure value; `$err` / `formatError(err)` need no source. Per **G-perf-2**
  this touches only the error path; the success path never builds a `LineMap`, and
  a multi-error `parseAll` builds **one** shared `LineMap` and feeds every error.
- *(lazy/ref — rejected)* — hanging a `LineMap`/`ref`/closure-over-source off the
  error breaks value semantics, keeps source alive past the parse, makes the error
  un-serializable, and complicates `noSideEffect`/VM use. There is no axis on which
  it wins: the supposed upside (skip line/col when unrendered) is nil because
  errors are rare and the `LineMap` is built once per batch regardless.

**Steps (eager-on-error):**

1. **`src/spans.nim`** — extend `ParseError`:
   ```nim
   ParseSeverity* = enum sevError, sevWarning, sevNote
   ParseError* = object
     code*: ParseErrorCode
     span*: Span
     hint*: string
     line*, col*: int32                 ## 1-based; 0 = "not resolved"
     path*: string                      ## sourcePath; "" = unknown
     severity*: ParseSeverity           ## default sevError (zero-breaking)
     relatedSpans*: seq[(Span, string)] ## secondary labels; empty = absent
   ```
   (+ ~16 bytes to a struct that already holds a `string`; on the success path the
   `Result`'s error variant is default — no refcount traffic — so **G-perf-1**
   holds. Confirm with the bench gate.)
   - **`severity` + `relatedSpans` are added now, not deferred (R1 / error/proof
     A-5).** Best-in-class error models carry both; since this struct + every
     construction site are being rewritten here, adding the fields is near-free now
     and ~165 re-touches later ("nothing built twice"). `severity` defaults to
     `sevError` (existing call sites unchanged); KDL's warning-grade conditions
     (deprecated syntax, unknown reserved types) finally have a representation.
     `relatedSpans` starts empty and is populated opportunistically, highest-value
     first (e.g. unbalanced-brace errors label the *opening* brace). **Fix-it
     suggestions are the one piece deferred to v0.3** (they need a
     machine-applicable-edit model + a consumer).
2. **Two-tier construction — the "single choke point" claim was false (error/proof
   A-1).** The draft signature `makeError*(code, span, hint, source, path: string)`
   was itself a type error (`code` is `ParseErrorCode`, `span` is `Span`, not
   `string`) **and** ~106 of ~165 `initError` call sites — all of `reserved.nim`'s
   validators (`validateReserved(tag, v)` takes neither source nor path),
   `numlit.nim`, etc. — **have no source in scope** to compute line/col from. A
   single source-taking choke point is therefore unimplementable. The correct model
   (rustc / miette: error values are span-bearing, location-resolution is a separate
   layer) is **tiered**:
   - `func initError*(code: ParseErrorCode, span: Span, hint: string): ParseError`
     — the source-less constructor. `line = col = 0` ("not resolved"); `path = ""`.
     The 106 deep validator sites keep calling this unchanged.
   - `func makeError*(code: ParseErrorCode, span: Span, hint: string,
     source: string, path: string): ParseError` — for the lexer/cursor/decoder
     sites that *do* hold source; fills `line`/`col` eagerly.
   - **Enrichment at the boundary.** Errors that surface with `line == 0` get their
     line/col filled once at the outermost point that holds source (the
     `parse`/`decode` return path builds the one shared `LineMap` per batch, **G-perf-2**,
     and resolves any unresolved spans). `$err` renders `<unknown>:?:?:` only if a
     span was never resolvable — a visible, honest fallback, never a crash.
   - `decodeNode` supplies the span (already in original-source coordinates —
     cursor-seek reuses the same token stream; **no rebasing** — the word "rebased"
     here was a stale span-slice carry-over, struck) plus `doc.sourceText` and
     `doc.sourcePath`.
3. **`$ParseError`** and **`formatError*(err: ParseError): string`** (no-source
   overload) render `path:line:col: <codeMessage>  — hint` and, when the caller
   *does* still hold source, the existing caret/underline form via the
   source-taking overload (keep it; it's the rich renderer).
4. Keep `buildLineMap`/`lineColOf` public for consumers who want bulk
   offset→line/col, but the **default** error path no longer requires them.

### 6.2 `embed` surfaces the formatted error (item E follow-on)

- **`src/api.nim:125`** — replace `doAssert r.isOk, …hint…` with a CT failure that
  renders the **caret diagnostic**, not just the `.hint`. At compile time the
  source *is* available — it is the `static[string]` argument — so call the
  source-taking renderer: `{.error: formatError(r.getErr, src, sourcePath).}`,
  giving `path:line:col:` + the underlined offending line in the build error. The
  current `doAssert` prints only `.hint` (the least informative field), so a
  malformed embedded config gives no location (error/proof A-6).
- **Strike the stale doc comment** at `api.nim:130-138`: it still says "the wrapped
  Result's `.get` raises", but `embed[T]` now returns bare `T` — there is no `.get`.
  The comment is a lie that will mislead a future reader (error/proof A-6).

### 6.3 Close the raise leaks (item H; principle D2)

### DECISION D-3 is *not* required here — this is investigation, then either
annotate or document. But the audit found concrete suspects, so:

0. **Put P3 in the default suite first (error/proof A-7).** P3
   (`tests/test_safety_properties.nim`) is gated behind `NKDL_PROPTEST=1` and is
   **not** in the default `nimble test` run — so the primary verification tool for
   D2 isn't in CI. Add it (or a stripped non-proptest variant exercising the same
   paths) to the default task before relying on it as the safety authority.
1. **Verify against P3** (task #358). Either the unguarded accesses are
   *unreachable* given the lexer's trailing-EOF guarantee, or **P3 has a coverage
   gap**. Do not assume either way (no-invariant-dismissal).
   - Audit suspects to prove safe or guard: `tok(c)` template (`cursor.nim:123`)
     and `c.stream[].tokens[c.tokIdx + 1]` at `cursor.nim:523, 577` (entry
     context, currently unguarded); `errorPayloads[errIdx]` trust
     (`cursor.nim:305`); `doc_build.nim:257+` token-index trust.
2. If reachable: add the missing bound/guard (cheap, off the hot path's measured
   inner loop) **and** a pinned regression input. If proven unreachable: the comment
   must cite a **structural argument** ("the lexer guarantees `tokens[^1].kind ==
   tkEof`, so for any `tok.kind != tkEof` the `+1` lookahead is in bounds"), **not**
   merely "P3 covers it" — a property test is not a proof of an invariant, and
   citing it as one is the exact differential-test-we-hope-is-exhaustive that D6
   forbids (meta-critic D2). P3 stays as the empirical backstop; the structural
   argument is the authority.
3. Annotate the public entries `{.raises: [].}` where the compiler accepts it.
   - **Caveat — the mixin chain (error/proof B-2).** `{.raises: [].}` on
     `decode[T]`/`decodeAll[T]` is **not** independently achievable: they call the
     user-generated `kdlDecode` mixin, so the annotation only holds if every
     generated `kdlDecode` also carries it. Options: (a) annotate only the
     non-generic entries (`parse`/`parseAll`) where the compiler can prove it, and
     document the typed entries' residual; or (b) have the derive macro emit
     `{.raises: [].}` on generated `kdlDecode` and propagate. Decide at the slice;
     do not claim a blanket `raises: []` the mixin can't honor.
   - Where the VM/`noSideEffect` path makes `raises: []` infeasible, **document the
     exact residual** in the proc doc (D2's escape hatch) rather than leaving it
     implicit — and remove amoxtli's defensive `except Exception` justification.
     (`{.noSideEffect.}` does **not** imply `{.raises: [].}` — they are orthogonal;
     the English "never raises" comment in `lexer.nim:30` is not a compiler-checked
     guarantee.)
4. **`embed`/CT path:** `doAssert` at CT is acceptable (build-time, loud) — that
   is not a runtime raise leak; document it as such.

### 6.4 Tests

- `tests/test_errors.nim`: `$err` and `formatError(err)` render
  `file:line:col: message — hint` **without** re-passing source, for a
  representative error of each code; line/col match a hand-computed fixture.
- Error from `decode[T](src, "cfg.kdl")` carries `path == "cfg.kdl"` and correct
  line/col (closes B + residual C together).
- `decodeNode` error (Phase 1) renders original-source line/col after rebasing.
- Property/fuzz: re-run P3; add any newly-pinned crash input.

### 6.5 Acceptance

- A `ParseError` renders a complete diagnostic standalone (D1).
- Public entries are `{.raises: [].}` or carry a precise documented residual (D2).
- P3 re-verified; no unguarded index can panic out of a `Result`.
- Success-path parse/decode benchmarks unchanged (**G-perf-1/2**).

### 6.6 Bridge the error contract to the assurance stack (error/proof A-3/A-4/A-9)

The Phase 2 work redesigns the error surface, but nothing in
`docs/rfc-conformance-assurance.md` or the Lean track currently tests *errors* —
the whole five-tier stack targets **acceptance** (what parses and to what value).
The word "error" doesn't appear in that RFC. Three determined closures:

- **Add a diagnostic-corpus tier.** Each must-reject fixture in
  `conformance/negative.nim` gains an expected `ParseErrorCode` **and** an expected
  `(line, col)`; the adapter asserts both. This makes error attribution a
  first-class tested contract (rustc UI-test model) without needing formal proof.
  Keep the *portable* corpus spec-clean (KDL 2.0 specifies rejection, not error
  codes) by putting code/location assertions in nkdl's own test layer, not the
  cross-impl corpus — error/proof B-3.
- **`ParseErrorCode` stability contract (A-4 / meta-critic B5).** The enum is
  ordinal-by-declaration-order today; inserting a code shifts every later ordinal
  and breaks any consumer that serializes or `int`-compares codes. Either assign
  **explicit integer values** to every variant, or **document that ordinals are not
  stable** and consumers must switch on the named variant. The v1.5 error-catalog
  issue (milpa #14 analog / nkdl error catalog) is the home for the stable table.
- **Amend the proof's claims: "complete", not "sound" (A-9).** `Full.lean` proves
  only `parse (renderForest f) = some f` (accepted inputs round-trip) — there is
  **no** rejection-soundness theorem (`¬forestWF f → parse (render f) = none`). So
  the recognizer is proven *complete*, not *correct*. Fix the overstatement in
  `proofs/lean/README.md` and `rfc-conformance-assurance.md` (which currently say
  "sound and complete"); file the soundness theorem as a research-grade,
  non-v0.2-blocking issue. Also note the latent coherence risk: the corpus derives
  from `conformance/model.nim`, the proof from `Full.lean`, and the two model the
  `Value` type differently (the Lean model lacks `kvBigInt`/`kvNull`/annotation
  interning) — nothing mechanically keeps them aligned. File an issue to track
  model convergence before the corpus grows into the float/structural groups.

---

## 7. Phase 3 — Codegen single-source + close the test blind spot

**Cluster 4 · amoxtli D(general), F.** This phase fixes the *root cause* from §1,
not a symptom. Can run in parallel with Phases 1–2 (disjoint files).

### 7.1 Extract one shared macro-helper module + fix item D there, once (D4)

This is where item D actually gets fixed — in the *unified* `fieldInfo`, so the
peel lands once for encode and decode by construction.

- **Create `src/derive_common.nim`** and move the byte-identical helpers currently
  duplicated across `derive_encode.nim` and `derive_decode.nim`: `fieldInfo`,
  `pragmaHead`, `hasPragma`, `pragmaArg`, `regularFields`, `objectRecList`,
  `findRecCase`. Both derive files `import ./derive_common` and delete their copies.
- **Fix item D in the unified `fieldInfo`:** add a `bareName(n: NimNode): string`
  (`if n.kind == nnkPostfix: $n[1] else: $n`) and apply it in *both* `fieldInfo`
  branches — the `nnkPragmaExpr` branch (`field* {.pragma.}`, where the postfix is
  `fieldNameNode[0]`) and the bare branch (`field*`). Because `fieldInfo` now
  exists once, this strips the `*` export marker for encode **and** decode with no
  possibility of asymmetric drift — the structural cause of D, removed.
- **The unified `fieldInfo` must also harden the AST shapes the current one crashes
  or mis-handles (typed-codegen A10).** These are latent `doAssert nil != nil`
  crashes and silent mis-dispatches that the *single* helper now fixes once:
  - **`distinct` newtypes** (`type Port = distinct int`): resolve through
    `getTypeImpl`/`getImpl` to the underlying primitive instead of string-matching
    `"Port"` and falling into the `else: error(...)`. Newtype-wrapped config fields
    are common and must work.
  - **Aliased `Option[T]`**: detect Option via the resolved type, not a literal
    `$t[0] == "Option"` head-string compare (which breaks under a qualified/aliased
    import). Use `getTypeImpl`.
  - **Inheritance** (`type Sub = object of Base`): `objectRecList` must recurse into
    the parent's fields (the body holds `nnkOfInherit`, not a flat `recList`) — today
    it `doAssert`s and dies with a confusing message.
  - **Tuples** (`nnkTupleTy`) and **`ref T` field/elem types**: handle or emit a
    *clear* compile-time error, never the bare `doAssert nil != nil` crash.
- **Honor `{.kdlSkip.}` (typed-codegen A2).** The pragma is declared in
  `pragmas.nim` but silently ignored by both `classify` and `dispatchField`. Add
  `if hasPragma(pragmas, "kdlSkip"): return` as the **first** check in each (before
  the `kdlArg`/`kdlProp`/`kdlChild` chain), so a skipped field is never encoded,
  never decoded, never required, and a `{.kdlSkip, kdlProp.}` combination can't
  half-fire. Document the decode-side fill (field keeps Nim's zero/default).
- **Why this and not the reverted hot-fix:** the standalone hot-fix duplicated
  `bareName` into both files (Phase 0 note), deepening the duplication that *was*
  the bug. D4 says fix the cause (the duplication), not the symptom twice.
- **Tests:** the extraction itself is behavior-preserving for existing suites;
  the D-fix is exercised by the consumer-shape regression tests in 7.3
  (`field* {.kdlArg/kdlProp.}` + exported variant discriminator `case kind*
  {.kdlArg.}`, both directions) — these go **red against the pre-fix `fieldInfo`
  and green after**, which is the point.

### 7.1.1 Decode codegen correctness (depth-review-surfaced; all DETERMINED)

The typed-codegen review found correctness holes in the generated decoder that are
independent of the `fieldInfo` extraction and each fail loud or fix a silent wrong:

- **`ckOption` for `Option[T]` children (A3).** Decode's `ChildKind` lacks
  `ckOption`, so an `Option[Item]` child (a *very* common config shape — optional
  subsection) is treated as `ckSingle`: it generates a `kdlDecode(Option[Item])`
  call that doesn't exist (opaque compile error) **and** claims a required slot
  (spurious `peTypeMissingRequired`). Encode already handles it → real asymmetry.
  Add `ckOption` to decode's `ChildKind`; detect via `isOptionType` before
  defaulting to `ckSingle`; treat as non-required (slot = -1); wrap the decoded
  inner in `some(...)`.
- **Name the missing field (A4).** `peTypeMissingRequired` currently renders
  `"missing required field"` with no name. At macro time, inline a `const` array of
  required field names in bit-order; on the failed-bitmap check, find the first zero
  bit and emit `"missing required field: <name>"`. Zero runtime cost on success.
- **`{.error.}` past 64 required fields (A5).** `claimSlot()` silently stops
  recording at bit 64 (`if result < 64`), so fields 65+ become silently optional.
  Emit a compile-time `{.error.}` — a detectable condition must fail loud (D3), not
  silently skip validation.
- **Duplicate property keys (A7).** KDL allows repeated props; the decoder
  silently last-write-wins, and the required bitmap is set on first sight, so a
  consumer can't tell "exactly one" from "two, last won". Per D3, add a seen-props
  bitset parallel to the required mask and emit `peTypeDuplicateField` on the second
  hit. (Matches knus.)
- **Strict-by-default for unknown fields, with `{.kdlIgnoreUnknown.}` opt-out (R1,
  determined — A7/B4).** Today the decoder is *inconsistent*: an unknown **prop**
  errors (`peTypeUnknownField`) but an unknown **child** is silently skipped. Unify
  to **both error** by default — nkdl's domain is human-authored config, where a
  typo'd key silently dropped is the silent-wrong D3 forbids, and strict gives typo
  detection. A type-level `{.kdlIgnoreUnknown.}` pragma opts into lenient
  (forward-compat/additive-schema) for the consumer who wants serde's default.
- **`decodeAll` recovery must not stall (error/proof A-8).** The recovery loop's
  `else: discard` branch (when the failed node isn't a `ceNodeBegin`) does nothing,
  leaving the cursor at the checkpoint so the outer loop re-decodes the same
  position → duplicate errors / potential non-termination. Make `else` consume at
  least one event (`discard c.advance`) — better, skip to the next top-level
  boundary. `Parsed[T].isComplete` (§8.1) is false whenever recovery was imperfect.

### 7.2 Decode-only / encode-only blocks (item F)

### Mechanism — DETERMINED: per-type pragma, bidirectional default (not opinion-based)

Directionality (encode vs decode) is a **per-type property**, not a per-block one
— a config module legitimately mixes decode-only parsed types with round-tripped
ones. That fixes the granularity, and fail-loud (D3) fixes the rest:

- **(a) `{.kdlNoEncode.}` / `{.kdlNoDecode.}` per-type pragmas [chosen]** —
  correct granularity (per-type), explicit (the type *declares* its
  directionality), composes with the block, fails loud (calling `encode` on a
  decode-only type is a clear error), and lets amoxtli's `Trigger`/`Policy`
  variants live *in* the block instead of on the hand-declared path that tripped D.
- *(b) `kdl(decodeOnly = true):` block flag — rejected:* wrong granularity,
  couples unrelated types.
- *(c) dead-code-friendly emit — rejected:* makes the encoder *silently not
  exist*, so calling `encode` yields a confusing "undeclared" error — violates D3.

Bidirectional-by-default with per-type opt-out is also the right *ergonomics*: no
ceremony for the common round-trip case, one pragma for the exception.

**Steps:** `kdl_block.nim:82-83` currently force-emits *both* `deriveEncode(T)` +
`deriveDecode(T)`; gate each on the absence of the corresponding
`{.kdlNoEncode.}`/`{.kdlNoDecode.}` pragma (read via the shared `hasPragma` from
3.1). Add the two pragmas to `src/pragmas.nim`.

### 7.2.1 Typed-layer expressiveness (R1, determined — typed A8/A9/B3)

- **Variadic positional args — `kdlArgs` pragma (A8).** `tags "a" "b" "c"` is a core
  KDL shape the typed layer can't express today: `seq[T]` as `{.kdlArg.}` hits the
  `else: error(...)` branch with a stale message. A best-in-class typed KDL layer
  must express variadic positionals (knus `arguments`, serde variadic). Add a
  `kdlArgs` (plural) pragma mapping a `seq[T]` field to "all remaining positional
  args", with branches in `classify`/`emitTypedDecode` and the encode side.
- **Fix `nodeNameOf` casing, then expose it as `rename_all` (A9/B3).** `nodeNameOf`
  already lowercases the whole type name (`HTTPServer`→`"httpserver"`) — implicit
  casing that's simply *wrong*. Fix the fallback to a correct PascalCase→kebab/snake
  transform (serde `to_snake_case` algorithm). Once a correct transform exists, a
  type-level `{.kdlRenameAll: "kebab-case".}` is just its explicit override; add it.
  (`{.kdlNode: "..."}` remains the per-type escape; `{.kdlRename.}` the per-field.)

### 7.3 Make real-consumer usage shapes a permanent test fixture (THE fix for §1)

This is the highest-leverage item in the whole RFC. Create
**`tests/test_consumer_shapes.nim`** — a suite that mirrors how a demanding
consumer (not the library author) uses nkdl, and keep it green forever:

1. **Hand-declared, `*`-exported, pragma'd types** — both directions: plain
   `field* {.kdlArg/kdlProp.}` **and** exported variant discriminator
   `case kind* {.kdlArg.}`. (Phase 0's regression tests fold in here.)
2. **Heterogeneous multi-section decode** — parse-once, walk, dispatch by name,
   `decodeNode[T]` per section (shares Phase 1's `test_decode_node.nim`).
3. **Decode-only variant schemas** — a `{.kdlNoDecode.}`-free, `{.kdlNoEncode.}`
   variant case-object that is `deriveDecode`'d but never encoded; assert it
   compiles *without* dragging in the encoder.
4. **Diagnostics** — render `file:line:col` from a decode error with no source
   re-pass (shares Phase 2's `test_errors.nim`).
5. **Exception safety** — feed adversarial bytes to `decode`/`parse` and assert a
   `Result` err, never a raised `Defect` (shares P3).
- **Mark this suite in `nkdl.nimble`'s `test` task** and in the contributor docs
  as *the consumer-contract suite* — changes that break it are API regressions.

### 7.4 Acceptance

- One `derive_common` module; zero duplicated macro helpers; derive suites green.
- `kdl:` block supports decode-only / encode-only types via pragma.
- `test_consumer_shapes.nim` exists, is wired into `nimble test`, and codifies the
  four previously-untested real-consumer shapes.

---

## 8. Phase 4 — Hardening: surface coherence + fail-loud footguns

**Clusters 5 + 6.** Surface coherence + fail-loud footguns. With no consumers,
"breaking" carries no cost — so this is not a batched-for-disruption sweep; each
item lands wherever it's cheapest, and the *doctrine* it codifies (§8.1) is
settled **up front** so Phases 1–2 build on the coherent surface rather than
retrofitting it (see §11). Listed as one phase only for grouping.

### 8.1 Surface-coherence doctrine (Cluster 5)

These conventions are **settled by principle** (not preference) and are decided
*up front* — Phases 1–2 conform to them from birth (see §11 step 0). The one
genuine judgment call and the naming are flagged.

- **Absence → `Option`. [DETERMINED for VALUE leaves; PROVISIONAL for NODES — see
  Cluster 0]** `arg(n, idx)` → `Option[KdlValue]` is right (the `kvNull` sentinel
  destroys the missing-vs-`#null` distinction; values become cheap POD copies under
  C0). `args(n): seq[KdlValue]` likewise. **But `child`/`node`/`children`/`nodes`
  returning `Option[KdlNode]`/`seq[KdlNode]` by value is exactly the C0-a/C0-b copy
  + lossy-read substrate problem — their return discipline is decided by Cluster 0's
  read-model pass, not here.** `has*` is removed *because* C0's read model makes
  presence free, not for minimalism.
  - **`hasArg` survived F.1 and must be deleted explicitly (API/typed A2).** It is
    a *value*-leaf predicate, so the node read-model rationale above doesn't reach
    it — but `arg(n, idx)` already returns `Option[KdlValue]`, so `hasArg` is
    exactly the redundant presence check the Option doctrine forbids (no `Option`
    idiom ships a parallel `hasValue`). Delete `ast.nim:488` and the test that
    exercises it (`tests/test_accessors.nim`'s `hasArg` cases). This is a concrete
    deletion, not "resolved by the read model" — the model never touched it.

- **`encode` is total. [DETERMINED — make illegal states unrepresentable]**
  `encode[T]` returns a bare **`string`**, not `Result` — the field types *are* the
  validation, every well-typed value renders to valid KDL, and KDL itself does not
  validate type-annotation semantics (`(u8)256` is syntactically valid KDL, not
  encode's to police). Delete the always-`Ok` `Result` (a smell). This makes
  `encode[T]` and `encode(doc)` **both** bare `string` — dissolving the audit's
  encode asymmetry. Validity that *is* representable as a Nim type stays at the
  boundary (field types; smart mutators reject foreign handles — §8.2); a field
  type the encoder can't render is a **compile-time** error, never a runtime one.

- **Fail-fast vs accumulate.** Fail-fast `xxx` → `Result[T, E]` **[DETERMINED —
  errors-as-values]**. The accumulating `xxxAll` returns a **named `Parsed[T]`
  type** (`.value`, `.errors`, `.isComplete`) — *not* a bare `tuple`
  **[DETERMINED — ergonomics: discoverable fields + helper methods]**. `embed` →
  bare `T` stays the one intentional build-time (CT-loud) exception.
  - *Genuine open call:* keep **two** entries (`decode` + `decodeAll`) vs **one**
    accumulating entry with a fail-fast adapter. Both defensible; accumulate is the
    general primitive, fail-fast the convenience. Leaning keep-two; not forced.

- **Mutation return shapes. [DETERMINED — return the most-informative free result]**
  `removeChild` → **`int` (count)**: count dominates bool (caller derives `> 0`).
  `removeArg` → **`bool`** is *correct*, not inconsistent — it removes at most one
  (by index), natural cardinality 0/1. Add `addProp` (append) so `setProp`
  (upsert) stops conflating insert+update.

- **Preserve for typed path — RE-SIZED: this is a subsystem, not a finish bullet
  (meta-critic A5).** Typed users can't round-trip byte-lossless today (`decode[T]`
  is cursor→struct, builds no `KdlDoc`, retains no source/spans). "`decode` returns
  the backing `KdlDoc`" hides that there is *no* `KdlDoc` on that path — delivering
  it means routing typed decode through `parse(preserveFormat = true)` → `KdlDoc` →
  `decodeNode[T]` (a different pipeline), or designing a brand-new "typed preserve
  handle" type with its own mutation-tracking model. Either is **v0.3-scale** with
  its own design and tests. **Action: file a v0.3 issue now** (defer-=-file-now);
  do **not** carry it as a one-line §11 tick. The honest v0.2 story is: byte-preserve
  is a Cat-3 (`KdlDoc`) capability; typed consumers who need it parse to a doc and
  use `decodeNode`, which *does* sit on a preserve-capable doc.

- **State the absence-shape split as policy (API A4).** Node accessors return
  `nil` for absence; value accessors return `Option`. This is internally consistent
  (refs are nullable, `KdlValue` is not, and wrapping a nullable ref in `Option` is
  redundant) but callers must learn two idioms (`c != nil` vs `p.isSome`) — so it is
  **named in the doctrine**, not left to fall out of two separate decisions.
- **Property iteration parity (API A6).** Post-F.3, `properties(n)` yields
  `(name: string, value: KdlValue)` directly (the doc-threaded `namedProperties`
  dissolves), and add a materialized `props(n): seq[...]` companion to `args(n)` so
  the value-read family is symmetric (`arg`/`args` ↔ `prop`/`props`).
- **Naming** (`Parsed` vs `Decoded`; `{.kdlNoEncode.}`): cosmetic, pick at impl.

### 8.1.1 Dimensions the R1 review found un-audited — tracked, not silently dropped

The depth review flagged whole surfaces the original four-axis audit never covered.
None block v0.2; each gets a filed issue so the omission is explicit (no silent cap):

- **Cat-1 streaming-cursor public surface (meta-critic B1)** — `StringCursor`,
  `CursorEvent`, `advance`/`peek`/`skip`/`seek`/`Checkpoint` are public via
  `import nkdl/cursor` with no doctrine and no consumer-contract tests. File an
  issue to give Cat-1 the same `test_consumer_shapes` treatment as Cat-2.
- **`path` DSL (meta-critic B6)** — `where`/`first`/`only`/`path{}` ship with the
  single-predicate-single-chain limitation undocumented and untested. File.
- **Unicode normalization / interner collation (meta-critic B2)** — the interner
  does byte-equality, so NFC vs NFD identifiers compare unequal. Decide and document
  whether that's intended (likely yes — KDL doesn't mandate NFC) vs a bug. File.
- **`KdlValue`/`KdlNode` as typed passthrough fields (typed B2)** — currently a
  confusing compile error. Decide: allow (DOM coupling) vs reject-and-document
  (keep the typed layer DOM-free). Leaning reject-and-document; file to confirm.

### 8.2 Fail-loud the footguns (Cluster 6; principle D3)

- **Cross-doc interner handle — DISSOLVED by F.3, not guarded.** The "add a
  debug assertion" sketch is superseded: F.3's `ownerDocument` + auto-adopt
  (§2.5) re-homes any foreign `KdlValue`/`KdlNode` at the mutation boundary, so
  `addArg`/`setProp`/`addChild` can no longer carry a foreign handle into a doc.
  There is nothing left to assert — the state is unrepresentable. `migrateValue`
  becomes the internal adopt primitive (and is deprecated as a public API — API
  A11). Keep a debug `assert` only as a tripwire on the adopt path itself.
- **Cross-doc error attribution after adopt (error/proof A-10).** A node adopted
  from doc-A into doc-B will, on a later `decodeNode` error, report doc-B's
  `sourcePath` — even though its bytes came from a different file. This is
  **semantically correct** (the adopted node is now interpreted in B's context) and
  is the chosen behavior; **write it down** in the F.3 adopt spec rather than
  leaving it an unstated implication. (A multi-file assembler that needs
  origin-tracking is a v0.3 concern, filed separately.)
- **DELETE the `removed*` tombstone subsystem — it is vestigial (data-model Issue 3
  + B; verified).** `MutationState.removedChildren`/`removedEntries` and
  `KdlDoc.removedNodes` are *written but never read* anywhere in `src/`+`tests/`
  (confirmed: only a doc-comment references them). Byte-exact preserve does **not**
  use them — it works via the **dirty-flag + subtree-canonical fallback**
  (`doc_emit.nim:88,151`): `removeChild` etc. set `mutState.dirty = true`
  (`ast.nim:774-776`), and the dirty subtree re-emits canonical, so the removed
  child disappears correctly. The tombstones are a superseded earlier approach
  (#305) that the dirty-flag caching (#306) replaced. Post-F.1 they hold **strong
  `seq[KdlNode]` refs**, so the moment F.3 auto-adopt lands a node would be
  tombstoned-in-A *and* live-in-B — cross-doc coupling for zero benefit. Root-cause
  fix is **deletion** (not convert-to-`Span` — that's reshaping dead code). Also fix
  the **stale doc-comments** on `removeChild`/`replaceChild` claiming "tombstoned so
  the preserving encoder can skip its source bytes" — the encoder re-canonicalizes
  the dirty subtree; it never reads them. **Sequencing: this is a pre-F.3 cleanup**
  (do it before F.3 so auto-adopt can't weaponize the refs). Collapse
  `MutationState`-as-`ref`-on-a-`ref`-node (Issue 4) in the same pass — inline the
  fields onto the now-`ref` `KdlNode`; the 48-byte rationale died with the value→ref
  flip.
- **Best-in-class preserve refinements are real features, separate from the
  tombstone deletion.** Two known upgrade axes, both designed fresh (purpose-built
  span tracking, **not** the deleted node-ref tombstones): (a) **finer-grained
  intra-node splice** — today preserve is *subtree-granular* (mutating one entry
  re-canonicalizes the whole node, so untouched siblings lose original formatting);
  the upgrade splices untouched entries verbatim and re-renders only the changed
  one; (b) **slashdash (`/-`) byte-exact preservation** under mutation — the
  `byte-exact slashdash-preserving DocBuilder variant`, **#284**. Both kept on the
  roadmap as the best-in-class-preserve work the user wants.
- **`emPreserve` without `sourceText` (API A13 — high-traffic):** today silently
  emits canonical, and `parse()`'s **default** is `preserveFormat = false`, so the
  first "round-trip my config" consumer gets silent canonical output. Add
  `canPreserve*(doc): bool = doc.preserveFormat and doc.sourceText.len > 0 and not
  doc.mutated`; make `encode(doc, emPreserve)` fail loud (assert in debug / dedicated
  error) when `not canPreserve(doc)` instead of degrading silently.
- **`kvBigInt` >128-bit:** today truncates silently. Error at the
  construction/parse boundary until true bigint (filed v0.3) lands.
- **`setArg` out-of-range:** already returns `bool`; document that `false` means
  no-op so callers stop assuming success.

### 8.3 Acceptance

- A written "API shape doctrine" section in the README; every entry point
  conforms or documents its exception.
- Each Cluster-6 footgun errors (or asserts in debug) instead of silently
  producing wrong output.

---

## 9. Traceability — amoxtli items → cluster → phase

| amoxtli | Issue | Cluster | Phase | Status |
|---------|-------|--------:|------:|--------|
| **A** | no node-based decode | 1 | 1 | designed (cursor-seek, settled) |
| **B** | `ParseError` not self-describing | 2 | 2 | designed (eager-on-error, settled) |
| **C** | `decode`/`embed` dropped `sourcePath` | 2 | 0 + 2 | Phase 0.1 |
| **D** | exported pragma'd fields mishandled | 4 | 3 | hot-fix reverted; fixed in 3.1 (unified `fieldInfo`) |
| **E** | `embed` return-type + stale `.get` docs | — | 0 | Phase 0.2 |
| **F** | `kdl:` block force-emits encode | 4 | 3 | designed (per-type pragma, settled) |
| **G** | no public node-decode surface | 1 | 1 | folds into A |
| **H** | not `{.raises: [].}` | 3 | 2 | Phase 6.3 (investigate) |

Plus audit-surfaced items not in amoxtli's report: surface asymmetries (Cluster 5
→ Phase 4), silent-wrong footguns incl. cross-doc interner handles (Cluster 6 →
Phase 4), `fieldInfo` & ~7-helper duplication (Cluster 4 → Phase 3.1).

---

## 10. Determined design choices (not opinion-based)

Applying the §2 principles consistently, the three apparent forks each have a
single correct answer — they are settled, not awaiting a preference:

- **D-1 (Phase 1) — cursor-seek.** The only mechanism with one tokenizer **and**
  one decoder, consistent with the main path by construction (**D6**). span-slice
  introduces a redundant tokenization that must be differentially validated;
  reviving the DOM decoder reintroduces the duplication #299 removed. See §5.2.
- **D-2 (Phase 2) — eager-on-error.** A `ParseError` must be a self-contained
  value; lazy/ref breaks value semantics with no compensating upside. See §6.1.
- **D-4 (Phase 3) — per-type `{.kdlNoEncode.}`/`{.kdlNoDecode.}`.** Directionality
  is per-type (granularity), the type declares it (explicit), and it fails loud
  (D3). See §7.2.

### Residual genuinely-open items (small)

These are naming / minor shape, not architecture:

- **Naming:** `{.kdlNoEncode.}` vs `{.kdlDecodeOnly.}` (and the decode twin).
- **Token-retention shape (Phase 1 step 2):** a `parse(retainTokens = true)` flag
  (chosen baseline) vs the doc always owning the stream it was built from. The depth
  review (meta-critic D3) notes the flag is **near-redundant** with the consumer's
  own call choice — only a caller who will `decodeNode` sets it, and only they pay —
  so the flag adds ceremony for no benefit to anyone else. Still leaning keep-the-flag
  (you can't know at parse time whether `decodeNode` will be called later), but this
  is now a closer call; revisit if it reads as a wart.

### Apparent forks the review raised — all resolved to determined (R1)

The review surfaced four items as possible scope forks. Applied rigorously, the
best-in-class lens collapses every one — they are recorded here as **determined**,
with the counterargument that loses, so the resolution is auditable:

1. **Diagnostic ambition — DETERMINED: add `severity` + `relatedSpans` now; defer
   only fix-its (error/proof A-5).** Best-in-class error models (miette, ariadne,
   Lean 4 `MessageData`, rustc) all carry severity + labeled secondary spans. The
   decisive factor is **"nothing built twice"**: Phase 2 is rewriting `ParseError`
   and every construction site *now*, so `severity: ParseSeverity` (default
   `sevError`, zero-breaking) and `relatedSpans: seq[(Span, string)]` (empty =
   absent) cost almost nothing here and ~165 re-touches later. *Counter (loses):*
   "ship minimal, add when an LSP needs it" — but deferral is strictly more
   expensive given the struct is open on the table. Only **machine-applicable
   fix-its** genuinely need their own model + a consumer → filed v0.3.
2. **Adversarial-input bounds — DETERMINED: file now, design separately (meta-critic
   B4).** That a best-in-class parser bounds resources is settled
   (`MaxParserDepth = 256` exists). But resource-safety is a **different axis** from
   this RFC's API contract, needs its own threat model, and has **no untrusted
   consumer today** (amoxtli hasn't adopted). **defer-=-file-now** resolves the only
   real question (this RFC vs sibling). *Counter (loses):* "defense-in-depth now" —
   but half-designed watermarks are worse than a proper pass, and there's no urgency.
3. **Typed expressiveness — DETERMINED: do both (typed A8/A9/B3).** Variadic
   `seq[T]` as `kdlArg` (`tags "a" "b" "c"`) is a **core KDL shape** the typed layer
   can't express (knus/serde both do) → add a `kdlArgs` pragma. `rename_all` looked
   soft until noticing `nodeNameOf` **already** casing-folds, just *wrong*
   (`HTTPServer`→`httpserver`, typed A9); fixing the fallback to correct kebab/snake
   is a bug fix, and `rename_all` is then just its explicit override. *Counter
   (loses):* "explicit-only, no magic" — but the magic already exists and is broken;
   the choice is correct-casing vs broken-casing, not magic vs none.
4. **Strict-vs-lenient default — DETERMINED: strict + `{.kdlIgnoreUnknown.}`
   opt-out (typed A7/B4).** serde defaults *lenient* — but its domain is
   machine-to-machine wire formats. **nkdl's domain is human-authored config**,
   where a typo'd `prot=8080` silently dropped is exactly the silent-wrong D3
   forbids; strict gives typo detection. The current behavior is also *inconsistent*
   (unknown props error, unknown children skip) and must be unified regardless.
   *Counter (loses):* serde's lenient gold standard — domain mismatch; config is
   authored by humans who mistype.

Genuinely deferred residue (filed as v0.3 issues, **not** open questions): fix-it
suggestions (item 1), the standalone DoS-bounds design (item 2). Everything else
follows from the principles in §2.

---

## 11. Execution checklist (the spine to instruct against)

A flat, execution-ordered list of TDD-sized slices with **stable IDs** — instruct
by ID ("do 1.1", "next", "skip to 4"). Each leaf is one RED→GREEN cycle unless
marked *(refactor)* / *(docs)*. IDs are numeric to avoid collision with the
clean-core rebuild's `A1`/`B1`… stage letters. The `Phase n` thematic groupings
(§4–§8) still hold; this is just the order they're built in. Doctrine first
(breakage is free, so we make the surface coherent before features build on it).

**0 — Doctrine** *(settled, §8.1, no code)* ✓

**F — Value & read-access substrate** *(Cluster 0 — THE FOUNDATION, built before the
node-touching parts of 1/3.2/4)*
- **F.0** `/architect` round — **DONE.** Decision (see §2.5): `ref`-AST primary,
  arena fallback; keep owned-string values; `Option[KdlValue]` + `ptr` value
  fast-paths. *(The original F.0 `docId` cross-doc guard is superseded by F.3's
  `ownerDocument` — and the F.3 owner is `ref KdlDoc`, not `ptr`; see the
  soundness correction in §2.5.)*
- **F.1** ✓ `KdlNode`→`ref`, `KdlDoc`→`ref`; node reads return the node (`nil` =
  absent); deleted `has*`(node)/`Option[KdlNode]`/sentinel/`probeKdlNodeCopy`; plus
  the `nodes`/`children` arity-overload encapsulation. (commit `092b78b`)
- **F.2** ✓ **folded into F.1** — mutation-through-`ref` is intrinsic to the flip;
  all `var KdlNode`/`var KdlDoc` threading dropped, proven by the mutate-through tracer.
- **F.2.5** **pre-F.3 cleanup of F.1 fallout** *(blocking F.3)* — delete the
  vestigial `removed*` tombstone subsystem (verified zero readers; preserve runs on
  the dirty flag, not these) so F.3 auto-adopt can't weaponize the strong refs; fix
  the stale `removeChild`/`replaceChild` doc-comments; inline `MutationState` onto
  the ref node. Sweep in the other F.1-independent warts here too: `encode[T]`→bare
  `string` (1.6), delete `hasArg` + its test (1.3). (§8.2)
- **F.3** **`ownerDocument` on nodes** (W3C-DOM model): node carries
  **`ref KdlDoc`** (not `ptr` — `ptr` is unsound under ORC, see §2.5);
  **drop `doc` from the entire node-accessor surface** (`n.name`/`n.child("x")`/
  `n.prop("x")`/`n.children("x")`/`n.arg(i)`); cross-doc insert auto-adopts
  (O(subtree) re-intern, §2.5); make `KdlValue.typeAnnotation` portable
  (re-interned at the mutation boundary). Dissolves C0-d by construction (no
  `docId`, no assert). Re-derives the F.1 node accessors (drops their `doc` param)
  — a refinement, not a redo.
  - **F.3a — `n.name` returns `string` (the field-vs-accessor collision).** Today
    `n.name` is a public `InternedStr` field. After F.3 it must read as a `string`
    without a `doc` param. Resolution (Python `ast.Name.id` model): rename the raw
    field `nameHandle*: InternedStr` and add `func name*(n: KdlNode): string =
    n.ownerDocument.interner.lookup(n.nameHandle)`. Same for `typeAnnotation`. This
    also retires `resolveName(doc, n)` / `typeAnnotationOf(doc, n)` — whose
    **doc-first** parameter order was the opposite of every other accessor — by
    dissolving them, not renaming them.
  - **F.3b — `==` becomes cross-doc-correct.** Post-F.3 every node/value knows its
    `ownerDocument`, so `==` resolves each side's interned fields through its own
    interner instead of comparing raw `InternedStr` handles (which is silently
    wrong across docs — the current documented-but-unchecked footgun, violating D3).
    `nodeEqual`/`valueEqual` collapse into `==`; the cross-doc trap is gone.
- **F.4** `argRef`/`propRef: ptr KdlValue` zero-copy fast-paths (keep
  `Option[KdlValue]` owning default — 1.1 stands). *(This `ptr` is a **transient
  borrow** into a live node's `entries` — sound as long as it doesn't outlive a
  structural mutation of that node; document that contract. It is **not** the F.3
  owner-backref `ptr` that was rejected — that one is **stored**, this one is
  ephemeral.)* **F.4 also resolves API A10:** `setTypeAnnotation(v: var KdlValue,…)`
  silently mutates a *copy* when the caller got `v` from `arg()`/`prop()` (which
  return owning `Option` copies); `argRef`/`propRef` give the in-place handle so the
  in-place mutators act on the real backing value. Until F.4, mark those value
  mutators' copy-footgun in their doc comments.
- **F.5** **perf gate (no omission):**
  - ✓ **internal regression gate PASSED** — DOM `parse()` is ~13% *faster* under
    `ref` (min-of-5 wall-clock, WSL2/podman: value ~129 µs → ref ~112 µs; `pop`/`add`
    move pointers, not value copies); `decode[T]` parity (DOM-free). **Arena fallback
    NOT needed; ref-AST locked.**
  - ☐ **cross-impl competitiveness refresh** (standing): `parse()`→DOM vs **kdl-rs**,
    `decode[T]` vs **knus** (`benchmarks/comparisons/`). Publish all axes incl. any we
    trail. No competitiveness claim until run.
- ⚠ **1.x node/mutation ticks and the node accessors below are PROVISIONAL until F lands.**

**1 — Surface coherence** (`src/ast.nim` + `src/api.nim`) — Cluster 5 (value-leaf parts only until F)
- **1.1** `arg(n, idx)` → `Option[KdlValue]`  ✓ *(done; survives F — POD value leaf)*
- **1.2** add `args(n): seq[KdlValue]`  ✓ *(done; survives F)*
- **1.3** **delete `hasArg`** (`ast.nim:488` + its `test_accessors.nim` cases) —
  `arg(n,idx)` returns `Option`, so `hasArg` is the redundant presence check the
  Option doctrine forbids. (NOT "resolved by F" — the node read-model never touched
  this value-leaf predicate; it survived F.1 and needs an explicit removal. §8.1.)
- **1.4** `removeChild` → `int` (count); confirm `removeArg` stays `bool`  *(mutation API — may move under F)*
- **1.5** `addProp` (append) split out from `setProp` (upsert)  *(mutation API — may move under F)*
- **1.6** `encode[T]` → bare `string` (delete the always-`Ok` `Result`; ripple call sites)  *(independent of F; cross-confirmed by two depth agents)*
- **1.7** value-mutator copy-footgun: `setTypeAnnotation(var KdlValue,…)` mutates a
  copy if `v` came from `arg()`/`prop()` — doc-comment the trap now; **fully fixed
  by F.4** `argRef`/`propRef`. (API A10)

**2 — Unblockers** (Phase 0)
- **2.1** `sourcePath` on `decode`/`decodeAll`/`embed`
- **2.2** `embed` doc fixes (drop `.get` ×2) + CHANGELOG note *(docs)*
- **2.3** document `decodeAll[T]` seq constraint *(docs)*

**3 — Codegen single-source + item D** (Phase 3.1) — Cluster 4
- **3.1** extract `src/derive_common.nim`; both derive files import it *(refactor)*;
  the unified `fieldInfo` also hardens distinct / aliased-Option / inheritance /
  tuple / ref-T AST shapes (§7.1, typed A10) and honors `{.kdlSkip.}` (A2)
- **3.2** fix D in the unified `fieldInfo` (`bareName` peel) + consumer-shape
  regression tests (red against pre-fix, green after)
- **3.3** decode codegen correctness (§7.1.1): `ckOption` children (A3); name the
  missing field in `peTypeMissingRequired` (A4); `{.error.}` past 64 required
  fields (A5); duplicate-prop → `peTypeDuplicateField` (A7); unknown-field strict +
  `{.kdlIgnoreUnknown.}` opt-out (unify props+children, A7/B4); `decodeAll` recovery
  `else`-branch must advance, not stall (A-8)
- **3.4** typed expressiveness (§7.2.1): `kdlArgs` variadic-positional pragma (A8);
  fix `nodeNameOf` casing + `{.kdlRenameAll.}` knob (A9/B3)

**4 — Node decode, cursor-seek** (Phase 1 + Phase 3.3 — built AFTER F.3 so the
signatures take no `doc`) — Cluster 1
- **4.1** `KdlNode` carries `(firstTok, lastTok)` as a **balanced** token range;
  DOM builder records it (assert balance in debug)
- **4.2** `parse(retainTokens = true)` moves the `TokenStream` onto the doc
  (source already retained); `decodeNode` is DOM-parse-only (§5.3 step 2)
- **4.3** **fenced** cursor seed `initStringCursorAt(stream, source, firstTok,
  lastTok, mode)` — halts at `lastTok`; depth=0 seed correct given balanced span
  (§5.3 step 3 — the nested-node fix)
- **4.4** `decodeNode[T](node)` + `decodeChild[T](parent, name)` (no `doc` — F.3)
- **4.5** consumer-shape suite: heterogeneous multi-section, single-node extract,
  original-source error coords, **nested children + sibling-after untouched** (the
  fence regression, meta-critic A1)

**5 — Self-describing error contract** (Phase 2) — Clusters 2 + 3
- **5.1** `ParseError` carries `line/col/path` + `severity` (default `sevError`) +
  `relatedSpans` (R1 — best-in-class fields added during the one struct rewrite);
  **two-tier construction** (`initError` source-less + `makeError` source-bearing +
  boundary enrichment of unresolved spans) — NOT a single source-taking choke point
  (§6.1, error/proof A-1/A-5)
- **5.2** `$ParseError` / `formatError(err)` render with no source re-pass
- **5.3** `embed` surfaces the formatted **caret** error via `{.error:
  formatError(getErr, src, path).}` (static source is available at CT); strike stale
  `.get` doc comment (§6.2)
- **5.4** put P3 in the **default** suite (A-7); raise-leak audit → guard or prove
  unreachable with a **structural** argument (not "P3 covers it"); `{.raises: [].}`
  where the compiler proves it, mind the `kdlDecode` mixin chain (B-2), document residual
- **5.5** assurance bridge (§6.6): diagnostic-corpus tier (expected code + line/col
  on `negative.nim`); `ParseErrorCode` stability (explicit ints or documented);
  amend Lean/conformance claims to "complete, not sound"; file model-convergence issue

**6 — Decode-only + fail-loud footguns** (Phase 3.2 + Phase 4.2) — Clusters 4, 6
- **6.1** `{.kdlNoEncode.}` / `{.kdlNoDecode.}` pragmas honored by the `kdl:` block
- **6.2** cross-doc handle is **dissolved by F.3 auto-adopt** (not guarded); deprecate
  public `migrateValue`. *(Tombstone deletion + `MutationState` inline moved up to
  **F.2.5** — they're a pre-F.3 hazard, not a Phase-4 footgun. §8.2, data-model 3/4/B.)*
  Best-in-class preserve refinements (finer-grained intra-node splice; slashdash
  byte-exact, **#284**) are separate roadmap features, not blocked by the deletion.
- **6.3** `emPreserve`-without-source → loud; add `canPreserve(doc): bool` (the
  `parse()` default `preserveFormat=false` makes this high-traffic — API A13)
- **6.4** `kvBigInt` > 128-bit → loud error
- **6.5** document cross-doc error attribution after adopt = destination-path
  semantics (error/proof A-10)

**7 — Finish surface + preserve** (Phase 4.1 remainder)
- **7.1** accumulating returns → named `Parsed[T]` type (`.value`/`.errors`/
  `.isComplete`), converging `decodeAll` (was `(value,errors)`) and `parseAll` (was
  `(doc,errors)`) onto one shape. **Land this in Phase 0** alongside `sourcePath`, so
  Phase 0's `decodeAll` doesn't ship a tuple that 7.1 then re-breaks (meta-critic C2)
- **7.2** ~~typed byte-preserve model~~ → **RE-SIZED to a v0.3 issue** (meta-critic
  A5): there is no `KdlDoc` on the `decode[T]` path; delivering preserve means a new
  pipeline/handle type. File the issue; do not carry as a v0.2 tick. (§8.1)
- **7.3** README "API shape doctrine" section

**8 — Filed deferrals** *(defer-=-file-now: open the GH issues during planning, not
when reached)* — each is determined-to-defer, not an open question:
- **8.1** v0.3: typed byte-preserve subsystem (§8.1, was 7.2) — **nkdl#31**
- **8.2** v0.3: adversarial-input resource bounds + threat model (B4) — **nkdl#32**
- **8.3** v0.3: machine-applicable fix-it suggestions on `ParseError` (A-5) — **nkdl#33**
- **8.4** Cat-1 streaming-cursor consumer-contract suite + doctrine (B1) — **nkdl#34**
- **8.5** `path` DSL hardening + documented predicate limits (B6) — **nkdl#35**
- **8.6** Unicode NFC/NFD interner-collation decision + doc (B2) — **nkdl#36**
- **8.7** `KdlValue`/`KdlNode` typed-passthrough fields: reject-and-document (typed
  B2) — **nkdl#37**
- **8.8** research: Lean rejection-soundness theorem; `model.nim`↔`Full.lean`
  convergence (A-9) — **nkdl#38**

Open calls deferred to their slice: keep-two-vs-one decode entries (affects **7.1**
framing), pragma/type naming. The ordering goal is "best end state, nothing built
twice" — not "minimize disruption," because there's no one to disrupt.
