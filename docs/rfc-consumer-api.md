# RFC: Consumer API hardening — typed↔DOM bridge + source/error ergonomics

**Status:** READY FOR `/tdd` (2026-06-03) — architect rounds 1 + 2 complete; all
forks resolved by the user → **MAXIMAL** (true source spans on node-decode via a
per-node `span: Span` field + self-sufficient `ParseError`). Un-shelves the
*API-surface* of `docs/rfc-api-v0.2-hardening.md` (§4.1/§5/§6.1/§6.3) and builds the
per-node span the core-rebuild RFC deferred as §5.5 (shared with #31 byte-preserve).
Architect round 2 applied (2026-06-03): span storage resolved (**on-node `span: Span`
field**, not a doc-side Table — rejected on correctness grounds: structural `==` vs
identity `hash`); annotated-node start-offset specified; `{.raises:[].}` moved to D0;
stage order corrected (B1 before N2, C1 before N2); `rebased`/enrichment contract
specified; `embed`/`embedFile` naming split; `peIOError` placement confirmed. §9.3
fork resolved by the user: doc-less fallback stays a `decodeNode[T]` **overload**.
**No open forks remain.**

**Scope:** `src/api.nim`, `src/node.nim`, `src/node_build.nim`, `src/node_emit.nim`,
`src/spans.nim`, `src/parser.nim`, `src/nkdl.nim`, README + `docs/derive-reference.md`.
**No change to the S0–S10 derive vocabulary or its codegen.**

**Framing principle (settled):** S0–S10 is best-in-class; **we hold the line.** This
RFC adds the consumer surface and does not re-open/fork/re-derive decode semantics.
**A second decoder is rejected** (§6) — node-decode feeds the *one* decoder the
node's original source bytes.

---

## 1. Summary

Adds the missing **typed↔DOM bridge** (`decodeNode`/`decodeChild`/`coerce`), source
attribution (`sourcePath`/`decodeFile`), self-sufficient errors (`$err`, eager
line/col on `ParseError`), `{.raises: [].}`, and the symmetric `encode(node)` —
reusing the one decoder so all of S0–S10 works through it. The node-decode path
slices the node's **original source** (via a new per-node span) and decodes that, so
errors carry **true source line/col**, not synthetic offsets.

## 2. Motivation

Heterogeneous-top-level config is the canonical KDL use case and is exactly what
nkdl can't express typed today — blocking the first real consumer (amoxtli). serde/
knus/kdl-rs/pydantic all expose node/value typed decode with real diagnostics.

## 3. The gaps (verified against landed src/)

| ID | Gap |
|---|---|
| A | No node→T decode (`decodeNode`/`decodeChild`); `KdlNode` carries no span |
| C | `decode[T]` has no `sourcePath`; `decodeAll` returns bare tuple not `Parsed[T]`; no `decodeFile` |
| B | No usable `$err`; no eager line/col (`ParseError` has no `line`/`col`/`sourcePath` fields) |
| H | No `{.raises: [].}` on the public surface |
| D | `embed[T]` uses `doAssert` (not `{.error.}`); no `embedFile[T]`; stale `.get` in docs; `encode[T]` returns `Result[string, ParseError]` not bare string |
| E | No single-node `encode(node: KdlNode): string` |
| V | No public `KdlValue → T` coercion (`kdlDecodeValue` is a hook, not a public entry) |
| S | **No per-node source span** (§5.5 sidecar deferred) — the infra node-decode-with-real-errors needs |

## 4. Design

### 4.1 Per-node source span — the §5.5 sidecar (gap S) ← the enabling infra

`KdlNode` is doc-free (no `ownerDocument`, core-rebuild §3 axiom). `KdlDoc` already
retains `sourceText`. To give node-decode **true source spans**, add a **lean
`span: Span` value field directly on `KdlNode`** (§9.1 resolved):

```nim
KdlNode* = ref object
  name*: string
  typeAnnotation*: Option[string]
  entries*: seq[KdlEntry]
  childNodes*: seq[KdlNode]
  dirty*: bool
  span*: Span    ## NEW — [offset, length) into the owning doc's sourceText.
                 ## length==0 means no source (hand-built node).
```

**Why on-node, not a doc-side `Table[KdlNode, Span]` (§9.1 resolved):**
`KdlNode.==` is **structural**, but Nim `Table[K, V]` requires `a == b ⟹ hash(a) == hash(b)`. The default `ref` hash is pointer identity, which disagrees with structural `==` whenever two distinct refs compare equal — a silent correctness defect (wrong lookup results, not a loud error). A workaround with a `cast[int](node)` key would require a custom wrapper type and is pure indirection. An on-node `span: Span` is **8 bytes of plain integers, zero pointers, no ref cycle** — the rebuild's axiom was against `ownerDocument: KdlDoc` (a reference back-pointer creating an ORC cycle), not against plain value fields. Hand-built nodes have `span.length == 0` (zero-initialized), the unambiguous "no source" sentinel; a real parsed node always has `length ≥ 1`. No `retainSpans` flag is needed.

**Span recording in `node_build`:** `CursorEvent.span` at `ceNodeBegin` is the
**name-token span** — the node start for bare-identifier nodes, but for **annotated**
nodes (`(tag) name ...`) the real start is the `(` paren, which the lexer emits as a
token immediately before the annotation identifier. Start offset:
```nim
let startOff =
  if ev.nodeAnnoTok != -1:
    int(c.stream[].tokens[ev.nodeAnnoTok - 1].span.offsetRaw)  # '(' paren token
  else:
    ev.span.offset  # name-token offset = node start for plain nodes
```
End offset comes from `ceNodeEnd`: `ev.span.offset`. `ceNodeEnd` emits a **zero-length
point span** positioned just *before* the terminator (newline/semicolon/EOF/`}`), so its
`offset` is already the exclusive byte past the node content — there is no `length` to add.
The resulting node span covers the **full node text including its children block** (the
`{...}` if present) — required by the S1 property test (§8).

```nim
of ceNodeBegin:
  stack.add(KdlNode(name: name, typeAnnotation: typeAnno,
                    entries: @[], childNodes: @[],
                    span: initSpan(startOff, 0)))  # length filled at ceNodeEnd

of ceNodeEnd:
  if stack.len == 0: continue
  var n = stack.pop()
  let endOff = ev.span.offset            # zero-length point span before terminator
  n.span = initSpan(n.span.offset, endOff - n.span.offset)
  ...
```

A hand-built node has `span` zero-initialized → `span.length == 0` → `decodeNode`
falls back to re-emit (§4.2).

**#31 sharing:** #31 (typed byte-preserve) needs per-node span AND `parseHash`,
`headLen`, entry-level spans, etc. (core-rebuild §5.5 full list). S1 here adds only
the `span: Span` field. #31 extends `KdlNode` with a separate `meta: ref NodeMeta`
(nil unless `preserveFormat`) — orthogonal to `span`. S1 does not compete with #31;
#31 does not re-derive the span field.

### 4.2 The bridge — `decodeNode` / `decodeChild` (gap A) ← centerpiece

```nim
proc decodeNode*[T](doc: KdlDoc, node: KdlNode): Result[T, ParseError]   ## real source spans
proc decodeNode*[T](node: KdlNode): Result[T, ParseError]                ## hand-built / doc-less; re-emit
proc decodeChild*[T](doc: KdlDoc, parent: KdlNode, childName: string): Result[T, ParseError]
proc decodeOr*[T](doc: KdlDoc, node: KdlNode, fallback: T): T            ## value or fallback, never errs
```

> **Post-review amendment (R2):** `decodeOr` (slice N3) and the later
> review-follow-up `DocView` (+ `view`/`.nodes`/`.decode`/`.child`) were **CUT**
> after round-2 review. `decodeOr` is subsumed by `Result.valueOr`
> (`decodeNode[T](doc, n).valueOr(fb)` — strictly more general); `DocView` was
> doc-capturing sugar longer than the free `decodeNode[T](doc, n)` and collided
> with `KdlDoc.nodes`. The shipped node-decode surface is `decodeNode` (both
> overloads) + `decodeChild` + the scalar twins `decodeProp`/`decodeArg`. The
> blessed heterogeneous-dispatch idiom is the plain `for n in doc.nodes:
> case n.name` loop.

**Distinct name `decodeNode`** (round-1 design — not a `decode` overload; different
error-attribution warrants a distinct entry). Takes the **doc** because `KdlNode` is
doc-free, so the source + span live on the doc, not the node — a clean,
intentional consequence of the self-contained-node design (we are NOT re-adding
`ownerDocument`).

**Implementation — source-slice + rebase (the maximal path):**
```nim
proc decodeNode*[T](doc: KdlDoc, node: KdlNode): Result[T, ParseError] =
  when T is seq:
    {.error: "decodeNode[T] expects a single node; decode the element type.".}
  let span = node.span
  if span.length == 0:
    return decodeNode[T](node)    # hand-built fallback (§9.3)
  let slice = doc.sourceText[span.offset ..< span.offset + span.length]
  # Use the internal no-enrich variant — errors have raw slice-local offsets.
  let r = decodeInternal[T](slice, doc.sourcePath)
  if r.isErr:
    # 1. Rebase: add span.offset to make the error offset absolute in doc.sourceText.
    let absErr = r.getErr.rebased(span.offset)
    # 2. Enrich: compute line/col against the ABSOLUTE offset using the doc's LineMap.
    return err[T, ParseError](absErr.enriched(doc.sourceText, doc.sourcePath))
  ok[T, ParseError](r.get)
```
- **Reuses the one decoder** — feeds it the node's *original* bytes. Single source of
  truth; every S0–S10 pragma works unchanged.
- **`rebased` before `enriched`:** this order is critical. If B1 boundary enrichment
  ran inside `decodeInternal` (against the slice's line map), the line/col would be
  slice-local (wrong). `decodeInternal` is the internal variant that skips enrichment;
  `enriched` runs once at the public `decodeNode` boundary after rebasing, so line/col
  are computed from the absolute offset in the full doc source — correct.
- **No re-emit ⇒ the round-trip hazards depth flagged (annotation requoting,
  Option/null materialization, scalar round-trip) DO NOT ARISE** on this path — the
  bytes are verbatim original. Those hazards now apply only to the re-emit
  fallback path (hand-built nodes, §9.3), which §8 still pins.
- **Name check stays real:** the decoder checks `{.kdlNode.}` vs the node name (the
  slice has the real name) — `decodeNode[Daemon](doc, n)` requires `n.name ==
  "daemon"`; a stray name is a genuine, useful error. (Corrects draft-1's
  "mismatch is not an error".)

Usage (amoxtli, typed, with **real** `config.kdl:14:5:` errors):
```nim
let doc = parse(body, "config.kdl").get
for n in doc.nodes:
  case n.name
  of "daemon":      cfg.daemon = decodeNode[Daemon](doc, n).tryGet
  of "permissions": cfg.perms  = decodeNode[Permissions](doc, n).tryGet
  ...
```

### 4.3 Source attribution (gap C)

```nim
proc decode*[T](src: string, sourcePath = "<input>"): Result[T, ParseError]
proc decodeAll*[T](src: string, sourcePath = "<input>"): Parsed[T]   ## was a bare tuple
proc decodeFile*[T](path: string): Result[T, ParseError]
```
- `decodeAll → Parsed[T]` (type exists in spans; avoids a later break).
- `decodeFile` I/O error → new **`peIOError`** code (distinguishable from bad KDL;
  keeps the single `Result[T, ParseError]` currency).

### 4.4 Self-sufficient errors — rich `ParseError` (gap B)

`ParseError` gains eager location so errors are **values that outlive the source**:
```nim
ParseError* = object
  code*: ParseErrorCode
  span*: Span
  line*, col*: int           ## NEW — eager, filled at the parse/decode boundary
  sourcePath*: string        ## NEW
  hint*: string
  fieldPath*: seq[string]
func `$`*(err: ParseError): string   ## "config.kdl:14:5: expected int (daemon.server.listen)"
```
- **Two-tier construction:** `initError` makes a source-less error (`line=col=0`);
  `enriched(err, sourceText, sourcePath)` (new internal func) fills `line`/`col`/
  `sourcePath` once at the outermost public entry point. Error-path-only cost;
  the existing `lineColOf` family is reused. No new `lineCol` name.
- **`decodeNode` enrichment contract (critical):** `decodeNode` calls `rebased` first
  (makes the error offset absolute in the doc source), then `enriched` — so line/col
  are computed from the absolute offset, not the slice-local one. All other public
  entry points (`decode`, `parse`, `parseNodes`, `decodeFile`) call `enriched` once
  at return, against their own source. `decodeInternal` (internal) does not enrich.
- `$err` is fully self-sufficient (no source re-pass). `formatError(err, src)` stays
  for the full caret diagnostic.
- **`Span` stays offset-only** (its 8-byte design is correct); line/col live on the
  *error*, not the span.

### 4.5 `{.raises: [].}` (gap H) — decode surface at D0, encode at H1

`{.raises:[].}` is a correctness property, not a finish coat, so it is asserted as
early as it is **provable** — but Nim's `raises` check is **transitive**, so the
invariant can only be asserted over code whose whole transitive callee set is already
clean. That splits the public surface:

- **Decode surface — at D0 (`{.raises:[].}` now).** `decode`/`decodeAll`/`decodeFile`/
  `embed` (and the later `decodeNode`/`decodeChild`/`coerce`) sit on the lexer + cursor
  + `kdlDecode` path, which is **already `raises:[]`-clean** (verified). These get
  `{.raises:[].}` from D0 onward so every decode-side slice (S1, B1, C1, N2, N3, V1, …)
  is compile-checked inline. This is the entire node-decode + error-quality surface the
  RFC is about — exactly where the invariant earns its keep.
- **`encode[T]` — at H1.** `encode[T]` → `kdlEncode` (derive-generated, no pragmas) →
  the emitter `pushArg*` family transitively infers `raises:[Exception]`. It is left
  **honestly unconstrained** (inferred raises, **no `CatchableError`/`Exception` escape
  hatch**) until H1 triages the emit chain, then folded under `{.raises:[].}`. (The
  round-2 "whole-module `{.push raises:[].}` at D0" framing assumed non-transitively;
  corrected here after D0 surfaced the emitter blocker.)

H1 as a slice does the compile-triage of the underlying `emitter`/`derive_encode`/
`node_build` modules feeding the encode surface (convert genuine raisers to
`tkError`/Result; Nim OOM Defects are untracked and fine; budget 30–60 min), then
brings `encode[T]`/`encode(node)` under `{.raises:[].}`.
`decodeFile` is the one effectful entry — it catches `IOError` and converts to
`peIOError` at the boundary, keeping the whole public surface `{.raises:[].}`.

### 4.6 `encode(node)` (gap E) + `coerce` (gap V) + `embed`/`encode[T]` cleanup (gap D)

```nim
proc encode*(node: KdlNode): string                   ## canonical, one node (N1)
proc coerce*[T](val: KdlValue): Result[T, ParseError]  ## KdlValue → T via the scalar machinery
```
- Mark `emitNode`/`emitDoc` `func` so `encode(node)` (hence the re-emit fallback) is
  `{.noSideEffect.}`/VM-safe.
- `coerce[T](val)` — value leg of the bridge (source→T, node→T, value→T); named
  `coerce` not `decode` to avoid a third `decode` dispatch axis; routes through the
  `kdlDecodeValue`/built-in scalar machinery.
- **`embed[T]` / `embedFile[T]` split (resolved):** The existing `embed[T](src: static[string])`
  takes **KDL source content** — unchanged. A new `embedFile[T](path: static[string])`
  expands to `embed[T](staticRead(path), path)` via a macro (compile-time staticRead).
  Two distinct names, zero ambiguity: content vs path. The old design of "embed detects
  if the string is a path" was unworkable — a path and KDL source are both strings.
  Replace `embed`'s internal `doAssert` with `{.error: formatError(...).}` for a
  caret diagnostic on compile-time decode failure. Fix stale `.get` in docs (slice D0).
- `encode[T](v)` → **bare `string`** (the current `Result[string, ParseError]` is
  wrong — encode is structurally total; the "future validation" rationale in api.nim
  does not justify a Result when no error can occur). Aligns with `encode(node)`.

## 5. Best-in-class checklist (settled)

- **In scope:** §5.5 per-node span (S); `decodeNode`/`decodeChild` (A) (`decodeOr` CUT — see §4.2 amendment);
  `sourcePath`+`decodeFile`+`Parsed[T]`+`peIOError` (C); rich `ParseError`+`$err`
  (B); `{.raises:[].}` (H); `encode(node)` (E); `coerce` (V); embed + `encode[T]`→bare
  (D); heterogeneous-dispatch doc pattern.
- **Already covered:** multi-error decode, field-path errors, native defaults, S0–S10,
  DOM read/mutate/encode, `newKdl*`.
- **Explicitly out:** a registry/sum-type dispatch idiom (`case n.name` + `decodeNode`
  is the correct minimalism); `kdlCatchAll` (#40); full typed byte-preserve (#31 — but
  this RFC builds the §5.5 span half it shares); any S0–S10 change.

## 6. Architectural resolution: no second decoder

(b) DOM-walk decoder — **rejected** (re-derives the vocabulary; divergence liability;
not genuinely better than one source of truth). The chosen path is the **source-slice
+ rebase** form of (a): feed the one decoder the node's original bytes, rebase the
error. It reuses S0–S10 entirely, gives real spans, and (unlike re-emit) introduces
no canonicalization round-trip. Re-emit (c) survives only as the hand-built-node
fallback where no source exists.

## 7. Stages → slices

| Slice | Title | Risk |
|---|---|---|
| D0 | Fix stale docs; `{.raises:[].}` on the **decode surface** (encode deferred to H1 — transitive emitter raisers) | low |
| S1 | Add `span: Span` to `KdlNode`; record in `node_build` with annotated-node start-offset | **high** |
| N1 | `encode(node: KdlNode): string` + `func` the emit chain; `encode[T]`→bare string | low |
| B1 | Rich `ParseError` (add `line*,col*,sourcePath*`); `initError` unchanged; `enriched` + `rebased` funcs; `$err` | **high** |
| C1 | `sourcePath` on `decode`/`decodeAll`; `decodeAll → Parsed[T]`; `peIOError` in `ParseErrorCode` | med |
| N2 | `decodeNode[T](doc, node)` source-slice + `rebased` + `enriched` (seq-guard, name-check) | high |
| N2f | `decodeNode[T](node)` re-emit fallback (overload; hazard doc-comment per §9.3) | med |
| N3 | `decodeChild[T]` + ~~`decodeOr[T]`~~ (CUT R2 — use `Result.valueOr`; see §4.2) | low |
| V1 | `coerce[T](KdlValue)` | low |
| C2 | `decodeFile[T]` | low |
| D1 | `embedFile[T]` macro; `embed[T]` `{.error.}` on failure | med |
| H1 | raises-triage of emitter/derive_encode chain; bring `encode[T]`/`encode(node)` under `{.raises:[].}` | med |
| Doc | README + derive-reference: bridge API + heterogeneous-dispatch example | low |

Order: **D0** → **S1** → N1 → **B1** → **C1** → **N2** → N2f → N3 → V1 → C2 → D1 → H1 → Doc.

**Ordering rationale:**
- `{.push raises:[].}` at D0: correctness invariant from the start, not a finish coat.
- B1 before N2: `decodeNode` calls `enriched`, which needs B1's new `ParseError` fields
  (`line`, `col`, `sourcePath`). Shipping N2 before B1 means `decodeNode` returns errors
  with `line=0, col=0` — broken user-visible state. B1 is a hard prerequisite for N2.
- C1 before N2: `decodeNode` internally calls `decode[T](slice, sourcePath)`. The
  `sourcePath` param on `decode` is C1. C1 must land before (or merged into) N2.

## 8. Property-test extensions

- **S1:** for any parsed node (where `node.span.length > 0`),
  `doc.sourceText[node.span.offset ..< node.span.offset + node.span.length]`
  re-parses to a node structurally equal to `node` (the span is exact). For annotated
  nodes, `node.span.offset` points at the `(` paren, not the annotation identifier.
- **N2 cross-check:** `decodeNode[T](doc, doc.nodes[i]) == decode[T](sliceOf(i))` and
  agrees with whole-source decode of a single-node doc.
- **N2 error rebasing:** a type-mismatch in node `i` of a multi-node source yields an
  error whose `line`/`col` point at the **original** file position (not slice-local).
- **N2f fallback round-trip** (re-emit path): annotations, Option/none, kdlScalar all
  round-trip through the hand-built re-emit fallback (the depth-flagged hazards, now
  confined to this path).
- **B1:** `$err` on a known error renders `path:line:col: hint (fieldpath)` with no
  source argument.
- **H1:** a `{.push raises:[].}` module compiles against the whole surface.

## 9. Sub-decisions (architect round 2)

1. **§9.1 — span storage: on-node `span: Span` field (resolved).** Doc-side
   `Table[KdlNode, Span]` rejected on correctness grounds: `KdlNode.==` is structural
   but Nim Table requires `a == b ⟹ hash(a) == hash(b)`, and the default `ref` hash
   is pointer identity — these disagree whenever two distinct refs compare equal. A
   `cast[int](node)` workaround is pure indirection. On-node `span: Span` is 8 bytes
   of plain integers, no back-pointer, no ORC cycle (`ownerDocument` was the cycle —
   a reference; `span` is a value). `length == 0` is the unambiguous hand-built
   sentinel. **Decision: add `span: Span` to `KdlNode`. No `retainSpans` flag.**

2. **§9.2 — node identity for the sidecar: dissolved.** On-node field dissolves the
   sidecar entirely. No identity question.

3. **Rebasing correctness across nested children (confirmed + enrichment contract
   specified).** Single rebase suffices: all token offsets within the full-node slice
   are relative to the slice start (not a sub-slice). `rebased(span.offset)` makes
   the error offset absolute; `enriched(sourceText, sourcePath)` then computes
   line/col from the absolute offset. **Enrichment contract: `decodeInternal`
   (internal) does NOT enrich; `decodeNode` enriches after rebasing. All other public
   entry points enrich once at return.** This is the only order that yields correct
   line/col for `decodeNode` errors.

4. **`embed`/`embedFile` split (resolved, gap D).** The current `embed[T](src)` takes
   content. New `embedFile[T](path)` macro expands to `embed[T](staticRead(path), path)`.
   Two distinct names; no ambiguity. `embed` failure → `{.error: formatError(...).}`.

5. **`{.raises:[].}` split D0/H1 (resolved at implementation, gap H).** `raises` is
   transitive in Nim, so the invariant is asserted only where provable: the **decode
   surface** gets `{.raises:[].}` at D0 (its callee set is already clean); `encode[T]`
   stays honestly unconstrained (no escape hatch) until **H1** triages the emitter
   chain and folds it under. The round-2 "whole-module push at D0" was non-transitive
   wishful thinking — corrected after D0 hit the `encode[T] → kdlEncode → pushArg*`
   blocker. User-confirmed sequencing.

6. **`peIOError` in `ParseErrorCode` (resolved).** Single `Result[T, ParseError]`
   currency; `err.code == peIOError` distinguishes I/O from parse errors. Appended as
   the next stable integer value per the enum contract.

### §9.3 Doc-less fallback naming — RESOLVED: keep the overload

`decodeNode[T](node)` (re-emit fallback, hand-built nodes) stays an **overload** of
`decodeNode[T](doc, node)` — one name per concept, maximally ergonomic. Considered and
rejected: a distinct `decodeHandBuilt[T]` name (explicit barrier against accidentally
omitting `doc`). The overload wins on ergonomics; the degradation is mitigated by
documentation + tests rather than the type system:

- **N2f doc-comment must state the hazard loudly:** the doc-less overload re-emits the
  node and decodes the result, so `kdlScalar` hooks, annotation requoting, and
  Option/null materialization may differ from the source-slice path. Use the
  `(doc, node)` form whenever a parsed doc is in hand; reserve the bare form for nodes
  built programmatically (no source exists).
- The §8 N2f round-trip property tests pin exactly these hazards, so the path stays
  honest even though it isn't named at the call site.

## 10. Pre-work

- S1 is ready to implement. Verify the annotated-node paren offset (`ev.nodeAnnoTok - 1`
  token index) against a real annotated-node lexer output before S1 begins.
- Stage order: D0 → S1 → N1 → B1 → C1 → N2 → N2f → N3 → V1 → C2 → D1 → H1 → Doc.
- B1 blast radius: `initError` call sites are **unchanged** (two-tier design). Enrichment
  added at ~5 public boundary chokepoints. `ParseError` gains 3 fields. In-repo ABI
  break only (no published versioned ABI yet).
- H1 triage estimate: 30–60 min. Emitter is already all-`func`; main risk is the lexer.
- **RFC is ready for `/tdd`.** §9.3 resolved (overload kept); no open forks remain.
