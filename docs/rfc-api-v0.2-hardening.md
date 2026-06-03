# RFC: nkdl v0.2 — consumer-driven API hardening

**Status:** Draft — phases proposed; the three apparent "decisions" are
**determined** under the best-in-class lens (see §10). Residual open items are
naming + one retention-opt-in detail.
**Date:** 2026-06-02
**Inputs:** `docs/CONSUMER-FEEDBACK-amoxtli.md` (first external consumer) + a
four-axis first-principles audit of the public surface (API shape, decode/codegen
architecture, error/diagnostics surface, test-coverage shape).
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
- **Doc-scoped identity for handles** kills C0-d at the *type* level (an
  `InternedStr`/`NodeId` that knows its interner can't be used against another).

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
- **Cross-doc safety:** a per-doc identity (`docId`) makes a foreign-handle use a
  debug-build assert (zero-cost in release) — the C0-d footgun becomes catchable
  (grafted from the arena design).

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
proc decodeNode*[T](node: KdlNode, doc: KdlDoc): Result[T, ParseError]

## Sugar: decode the (first) named child of `parent` into `T`.
proc decodeChild*[T](parent: KdlNode, doc: KdlDoc, name: string): Result[T, ParseError]
```

- No `source` parameter: cursor-seek (§5.2) reads the doc's *retained token
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
2. **`src/parser.nim` / `KdlDoc` — opt-in token retention.** Add
   `parse*(source; sourcePath; preserveFormat; retainTokens = false)`. When
   `retainTokens`, move the `TokenStream` into the returned `KdlDoc`
   (`doc.tokens: TokenStream`); otherwise it is freed as today (**G-perf-3**: docs
   that never node-decode pay nothing). `decodeNode` asserts/errs with a clear
   message if called on a doc parsed without `retainTokens`.
   *(Retention model is the one residual naming/shape choice — see §10.)*
3. **`src/cursor.nim` — seed a cursor at a token index.** `StringCursor` already
   has `tokIdx` + `seek`; expose an internal
   `initStringCursorAt(stream: ptr TokenStream, source, tokIdx: int, mode): StringCursor`
   (or reuse `initStringCursor` + `seek` to the node's `firstTok`). No new lexing.
4. **`src/api.nim` — `decodeNode[T]`:** seed a cursor at `node.firstTok` over
   `doc.tokens` (+ the doc's source view, retained alongside the stream for token
   string resolution), `var v: T`, `kdlDecode(v, cursor)`, return `ok(v)`/`err`.
   Error spans are already in original-source coordinates — **no rebasing needed**
   (another correctness win over span-slice). Attach `doc.sourcePath`.
5. **`src/api.nim` — `decodeChild[T]`** = `parent.child(doc, name)` →
   `decodeNode[T]` (`none` ⇒ `err(peTypeMissingRequired, …)`).
6. **Item G:** `decodeNode` resolves the generated `kdlDecode` via the existing
   `mixin` (same module). Document `decodeNode` as *the* supported node entry; do
   not advertise the generated `kdlDecode` as public.
7. **Re-export** `decodeNode`/`decodeChild` from `src/nkdl.nim`; README API table
   under Cat-2; document that node-decode requires `parse(…, retainTokens = true)`.

### 5.4 Tests (the real-consumer shapes — also serve Phase 3)

New `tests/test_decode_node.nim`:

- **Heterogeneous multi-section doc** — the amoxtli `applyDoc` shape:
  parse `daemon { … } provider { … } permissions { … }` once, walk `doc.nodes`,
  `case doc.resolveName(n)` → `decodeNode[Daemon]` / `decodeNode[Provider]` /
  `decodeNode[Permissions]`; assert each populated field + that an unknown
  top-level node is skipped (forward-compat).
- **Single-node extract** — the `permission_hook` shape:
  `doc.node("hook").get` → `decodeNode[Hook]`; assert fields.
- **`decodeChild[T]`** sugar — `parent` with a named child decodes; missing child
  ⇒ `err`.
- **Error rebasing** — a malformed value *inside* the third section yields an
  error whose `span.offset` points into the *original* source (line/col correct
  once Phase 2 lands), not into the slice.
- **Nested children** — a section with its own `kdlChild` seq round-trips through
  `decodeNode` (slice includes children).

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
   ParseError* = object
     code*: ParseErrorCode
     span*: Span
     hint*: string
     line*, col*: int32     ## 1-based; 0 = "not resolved"
     path*: string          ## sourcePath; "" = unknown
   ```
   (+ ~16 bytes to a struct that already holds a `string`; on the success path the
   `Result`'s error variant is default — no refcount traffic — so **G-perf-1**
   holds. Confirm with the bench gate.)
2. **Single construction choke point** — route *all* error creation through one
   helper that takes source + path and fills line/col once:
   `func makeError*(code, span, hint, source: string, path: string): ParseError`
   (internal). The lexer/cursor/decoder error sites call it. (They already have
   source + path in scope; `decodeNode` supplies the *rebased* span + original
   source so coordinates are correct — §5.3 step 1.)
3. **`$ParseError`** and **`formatError*(err: ParseError): string`** (no-source
   overload) render `path:line:col: <codeMessage>  — hint` and, when the caller
   *does* still hold source, the existing caret/underline form via the
   source-taking overload (keep it; it's the rich renderer).
4. Keep `buildLineMap`/`lineColOf` public for consumers who want bulk
   offset→line/col, but the **default** error path no longer requires them.

### 6.2 `embed` surfaces the formatted error (item E follow-on)

- **`src/api.nim:125`** — replace `doAssert r.isOk, …hint…` with a CT failure that
  prints `formatError(r.getErr)` (the full `path:line:col: message — hint`), so a
  malformed embed shows the caret diagnostic, not a bare `AssertionDefect`.

### 6.3 Close the raise leaks (item H; principle D2)

### DECISION D-3 is *not* required here — this is investigation, then either
annotate or document. But the audit found concrete suspects, so:

1. **Verify against P3** (`tests/test_safety_properties.nim`, "cursor never
   crashes on arbitrary bytes", task #358). Either the unguarded accesses are
   *unreachable* given the lexer's trailing-EOF guarantee, or **P3 has a coverage
   gap**. Do not assume either way (no-invariant-dismissal).
   - Audit suspects to prove safe or guard: `tok(c)` template (`cursor.nim:123`)
     and `c.stream[].tokens[c.tokIdx + 1]` at `cursor.nim:523, 577` (entry
     context, currently unguarded); `errorPayloads[errIdx]` trust
     (`cursor.nim:305`); `doc_build.nim:257+` token-index trust.
2. If reachable: add the missing bound/guard (cheap, off the hot path's measured
   inner loop) **and** a pinned regression input. If proven unreachable: add a
   comment citing the invariant + the P3 case that covers it.
3. Annotate the public entries `{.raises: [].}` where the compiler accepts it.
   Where the VM/`noSideEffect` path makes `raises: []` infeasible, **document the
   exact residual** in the proc doc (D2's escape hatch) rather than leaving it
   implicit — and remove amoxtli's defensive `except Exception` justification.
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
- **Why this and not the reverted hot-fix:** the standalone hot-fix duplicated
  `bareName` into both files (Phase 0 note), deepening the duplication that *was*
  the bug. D4 says fix the cause (the duplication), not the symptom twice.
- **Tests:** the extraction itself is behavior-preserving for existing suites;
  the D-fix is exercised by the consumer-shape regression tests in 7.3
  (`field* {.kdlArg/kdlProp.}` + exported variant discriminator `case kind*
  {.kdlArg.}`, both directions) — these go **red against the pre-fix `fieldInfo`
  and green after**, which is the point.

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

- **Preserve for typed path.** Typed users can't round-trip byte-lossless today
  (`decode[T]` discards the parsed doc/spans). Build the right model — `decode`
  optionally returns the backing `KdlDoc` (or a typed preserve handle) so
  `encode(doc, emPreserve)` works. No documented hole; no compat reason to defer.

- **Naming** (`Parsed` vs `Decoded`; `{.kdlNoEncode.}`): cosmetic, pick at impl.

### 8.2 Fail-loud the footguns (Cluster 6; principle D3)

- **Cross-doc interner handle (worst):** `addArg`/`setProp`/`addChild` that accept
  a `KdlValue`/`KdlNode` carrying a *foreign* interner handle currently encode
  silently-wrong. Add a debug-build assertion (or auto-`migrateValue`) at the
  mutation boundary; at minimum, a checked path in `-d:release` off, hard error on.
- **`emPreserve` without `sourceText`:** today silently emits canonical. Make it
  either an explicit `err`/`raise` or require the caller to pass `emPretty`
  knowingly; add a `canPreserve(doc): bool` query.
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
  (chosen baseline) vs the doc always owning the stream it was built from. The flag
  is the G-perf-3-respecting default (non-node-decode docs pay nothing); revisit
  only if "must remember to pass the flag" proves a real ergonomic wart, in which
  case a `decode`-aware parse overload subsumes it.

Everything else follows from the principles in §2.

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
  fast-paths; `docId` cross-doc guard.
- **F.1** `KdlNode`→`ref`, `KdlDoc`→`ref`; node reads return the node (`nil` =
  absent); delete `has*`, `Option[KdlNode]`, sentinel-node, `probeKdlNodeCopy`.
- **F.2** mutation-through-`ref` (drop `var KdlNode`/`var KdlDoc` threading).
- **F.3** `docId` per-doc identity → debug-build cross-doc-handle assert (C0-d).
- **F.4** `argRef`/`propRef: ptr KdlValue` zero-copy fast-paths (keep
  `Option[KdlValue]` owning default — 1.1 stands).
- **F.5** **perf gate (no omission):** refresh cross-impl benches — `decode[T]`/
  `encode[T]` vs **knus** (must hold parity; DOM-free, so expected), and
  `parse()`→DOM vs **kdl-rs** (DOM + preserve). If `ref`+slab-pool can't reach
  kdl-rs parity on DOM build, switch to the **arena** (contiguous) fallback.
  Publish all axes incl. any we trail. No "nobody does this at speed" excuse.
- ⚠ **1.x node/mutation ticks and the node accessors below are PROVISIONAL until F lands.**

**1 — Surface coherence** (`src/ast.nim` + `src/api.nim`) — Cluster 5 (value-leaf parts only until F)
- **1.1** `arg(n, idx)` → `Option[KdlValue]`  ✓ *(done; survives F — POD value leaf)*
- **1.2** add `args(n): seq[KdlValue]`  ✓ *(done; survives F)*
- **1.3** ~~remove `hasArg`~~ → **resolved by F**: `has*` is removed *because* F's
  read model makes presence free, not as a standalone deletion (see §2.5)
- **1.4** `removeChild` → `int` (count); confirm `removeArg` stays `bool`  *(mutation API — may move under F)*
- **1.5** `addProp` (append) split out from `setProp` (upsert)  *(mutation API — may move under F)*
- **1.6** `encode[T]` → bare `string` (delete the always-`Ok` `Result`; ripple call sites)  *(independent of F)*

**2 — Unblockers** (Phase 0)
- **2.1** `sourcePath` on `decode`/`decodeAll`/`embed`
- **2.2** `embed` doc fixes (drop `.get` ×2) + CHANGELOG note *(docs)*
- **2.3** document `decodeAll[T]` seq constraint *(docs)*

**3 — Codegen single-source + item D** (Phase 3.1) — Cluster 4
- **3.1** extract `src/derive_common.nim`; both derive files import it *(refactor)*
- **3.2** fix D in the unified `fieldInfo` (`bareName` peel) + consumer-shape
  regression tests (red against pre-fix, green after)

**4 — Node decode, cursor-seek** (Phase 1 + Phase 3.3) — Cluster 1
- **4.1** `KdlNode` carries `(firstTok, lastTok)`; DOM builder records it
- **4.2** `parse(retainTokens = true)` + move `TokenStream` onto the doc
- **4.3** seed a `StringCursor` at a token index (`initStringCursorAt` / seek)
- **4.4** `decodeNode[T]` + `decodeChild[T]`
- **4.5** consumer-shape suite: heterogeneous multi-section, single-node extract,
  original-source error coords, nested children

**5 — Self-describing error contract** (Phase 2) — Clusters 2 + 3
- **5.1** `ParseError` carries `line/col/path` (eager-on-error); one construction
  choke point
- **5.2** `$ParseError` / `formatError(err)` render with no source re-pass
- **5.3** `embed` surfaces the formatted error (not `doAssert`)
- **5.4** raise-leak audit vs P3 → guard or prove unreachable; `{.raises: [].}`
  or documented residual

**6 — Decode-only + fail-loud footguns** (Phase 3.2 + Phase 4.2) — Clusters 4, 6
- **6.1** `{.kdlNoEncode.}` / `{.kdlNoDecode.}` pragmas honored by the `kdl:` block
- **6.2** cross-doc interner-handle guard at the mutation boundary
- **6.3** `emPreserve`-without-source → loud; add `canPreserve(doc): bool`
- **6.4** `kvBigInt` > 128-bit → loud error

**7 — Finish surface + preserve** (Phase 4.1 remainder)
- **7.1** accumulating returns → named `Parsed[T]` type (`decodeAll`/`parseAll`)
- **7.2** typed byte-preserve model (`decode` returns the backing `KdlDoc`)
- **7.3** README "API shape doctrine" section

Open calls deferred to their slice: keep-two-vs-one decode entries (affects **7.1**
framing), pragma/type naming. The ordering goal is "best end state, nothing built
twice" — not "minimize disruption," because there's no one to disrupt.
