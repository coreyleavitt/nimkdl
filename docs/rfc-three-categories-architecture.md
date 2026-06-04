# RFC: Three-Categories Architecture (v1)

> **⚠ Substrate superseded — read this first.** The three-category *layering*
> (Cat 1 streaming cursor / Cat 2 typed-derive / Cat 3 DOM) is canonical and
> still describes the architecture. But the **substrate + codegen details in
> this body are obsolete**: it describes the old interner / `doc.interner` /
> ref-AST model and the `deriveDecode`/`deriveEncode` codegen names. The DOM
> was rebuilt around self-contained owned-string nodes (`src/value.nim` +
> `src/node.nim`, no interner) per **`docs/rfc-core-rebuild.md`**, and the
> public typed API is `decode[T]` / `encode[T]` (pragma vocabulary in
> **`docs/derive-reference.md`**). Where this RFC and rfc-core-rebuild
> disagree on the substrate, rfc-core-rebuild wins.

**Status**: Phases 0-2 landed (cursor + buildDoc + parse swap). Phases 3-6 superseded by a clean-core branch rebuild — see `docs/branch-rebuild-plan.md` for the operational sequencing.
**Filed**: 2026-05-28. Revised 2026-05-29 with IN/OUT symmetry + branch-rebuild strategy.
**Supersedes**: nkdl#8 (parametric SeqBuilder), nkdl#10 (pull-based decoder RFC), partially closes nkdl#7 + nkdl#11 by construction.

## Revision history

- **2026-05-28** — Initial filing. Cursor + three-categories layering for the IN side. Phases land incrementally on main.
- **2026-05-29** — Extended:
  - IN/OUT symmetry: KdlEmitter primitive as the inverse of KdlCursor. All three categories ride on cursor (IN) and emitter (OUT).
  - PBT redesign catalog (P1-P12) covering the new substrate's load-bearing invariants.
  - Branch-rebuild strategy replaces incremental Phase 3-5. Clean substrate; legacy deleted before rebuild starts; validation gate at the end. Operational plan: `docs/branch-rebuild-plan.md`.

---

## Background — the three categories

Mature parser libraries converge on offering three orthogonal consumer surfaces:

- **Cat 1 (streaming/visitor/SAX)**: event-driven API where user supplies state machine via callbacks. Examples: simdjson, Jackson `JsonParser`, System.Text.Json `Utf8JsonReader`, Go `json.Decoder.Token()`. Use cases: LSP servers, validators, format converters, large-file processing. Library walks tokens, fires events; user manages state.
- **Cat 2 (typed-derive)**: user declares a Nim type with pragmas; codegen generates a `decode[T]` function. Examples: serde-derive, encoding/json, Jackson `ObjectMapper`. Library walks tokens, builds typed value via function recursion using the call stack for state.
- **Cat 3 (AST/DOM)**: library parses to a generic tree; user walks it. Examples: `serde_json::Value`, kdl-rs, current nkdl `parse() → KdlDoc`.

nkdl's product position: ship all three, sharing one low-level primitive.

---

## What's wrong with the current architecture

The current `typed_parser.nim` visitor protocol is doing three jobs:

1. It IS the Cat 1 surface (not productized).
2. It's the substrate `parse()` rides on (via DocBuilder) — Cat 3.
3. It's the substrate `decode[T]` codegen rides on (via deriveVisitor) — Cat 2.

The protocol's design is pulled in three different directions. The codegen-generated visitor for Cat 2 (XVBuilder + XVBuilderSeq) has a state-machine bug: single `inChildren: bool` can't represent nested children blocks (nkdl#11), silently corrupting typed values at depth 2+. This affects `decode[T]` (runtime) AND `embed[T]` (compile-time) — the headline pitch.

The root smell: state-machine logic encoded in struct fields, manually managed by codegen. The encoder side (`deriveEncode`) doesn't have this problem because it's already pull-based recursive descent using the call stack for state.

---

## Target architecture: symmetric cursor (IN) + emitter (OUT)

```
                     wire bytes
                  ┌──────┴───────┐
              [lexer]        [byte-writer]
                  │              │
              tokens          tokens
                  │              │
           ┌──────▼─────┐  ┌────▼─────────┐
           │ KdlCursor  │  │ KdlEmitter   │   ← symmetric primitives;
           │ (events    │  │ (events in)  │     Nim concepts; multiple impls
           │  out)      │  │              │
           └───┬────────┘  └────┬─────────┘
               │                │
               │                │
      ┌────────┼────────┐ ┌─────┼─────────┐
      │        │        │ │     │         │
   buildDoc deriveDecode│ │ docEmit deriveEncode
   (Cat 3 IN)(Cat 2 IN)│ │ (Cat3 OUT)(Cat2 OUT)
                       │ │
                Cat 1 IN  Cat 1 OUT
                (events   (events
                 exposed)  pushed by user)
```

**Two foundation primitives, perfectly symmetric.** All three category surfaces
ride on both:

- **Cat 1**: cursor's event stream is exposed publicly (IN); emitter accepts
  push calls from user code (OUT).
- **Cat 2**: `deriveDecode` codegen emits recursive `decode[T]` over cursor
  events (IN); `deriveEncode` codegen emits recursive `encode[T]` pushing
  into emitter (OUT).
- **Cat 3**: `buildDoc` folds cursor events into KdlDoc via explicit stack (IN);
  `docEmit` walks KdlDoc pushing events into emitter (OUT).

Same shape on both sides. The complexity is in two small substrate modules
(cursor + emitter), shared across all three categories. Lexer and byte-writer
are thin layers at the wire boundary.

**Why symmetric?** Without an emitter, every OUT producer (deriveEncode,
docEmit, hypothetical Cat 1 push) duplicates concerns: quoting, escaping,
indentation, preserve-mode byte splicing. The emitter centralizes those. The
inverse of a grammar-aware reader IS a grammar-aware writer; pretending
otherwise leaves the design lopsided.

---

## The cursor (KdlCursor concept)

```nim
type
  CursorEventKind* = enum
    ceNodeBegin     # node header consumed; emits name + optional anno
    ceArg           # positional argument
    ceProp          # name=value property
    ceChildrenBegin # `{` consumed
    ceChildrenEnd   # `}` consumed
    ceNodeEnd       # node terminator (newline / semicolon / EOF)
    ceSlashDash     # next event was slashdash'd; consumer decides whether to honor
    ceEof
    ceError

  CursorEvent* = object
    span*: Span
    case kind*: CursorEventKind
    of ceNodeBegin:
      nodeNameTok*: Token
      nodeAnnoTok*: Option[Token]    # co-located: no side-channel
    of ceArg:
      argIdx*: int
      argTok*: Token
      argAnnoTok*: Option[Token]
    of ceProp:
      propKeyTok*: Token
      propValueTok*: Token
      propAnnoTok*: Option[Token]
    of ceError:
      err*: ParseError
    else: discard

  KdlCursor* = concept c, var mc
    ## Concept satisfied by any cursor impl. Production: StringCursor.
    ## Tests: TokenListCursor (no lexer needed). Future: IncrementalCursor.
    peek(c) is CursorEvent
    advance(mc) is CursorEvent
    skip(mc)                          ## skip current grammar unit (subtree-aware)
    bytes(c, Token) is openArray[char]  ## resolve token payload
    replayFrom(c, int) is auto        ## branch from saved pos; for incremental
    pos(c) is int                     ## current position for checkpointing
```

**Key decisions**:

- **Grammar events as the cursor's output**, not raw tokens. Right abstraction level — high enough that consumers don't re-walk grammar, low enough that Cat 1 just exposes the event stream publicly.
- **Annotations co-located with their event**. `ceNodeBegin` includes optional `nodeAnnoTok`; no `pendingNodeAnno` side-channel. Kills DocBuilder's annotation-slot complexity entirely.
- **Token references in events, NOT openArray**. Avoids the case-object-with-openArray-fields Nim friction. Consumers call `c.bytes(ev.nodeNameTok)` when they need text.
- **`replayFrom` for incremental/LSP**. Cat 4 (LSP) use case is real; the implementation is trivial if events are based on cursor position.
- **Concept-based, not concrete type**. Multiple impls; testability without lexer; monomorphized at instantiation.

**Mitigations for Nim concept rough edges**:

- Clear concept name + doc comment.
- Companion `validateKdlCursor[C](): static[bool]` proc users can call for clearer diagnostic surfaces.
- Wrap any sharp-edged concept instantiation patterns inside the library, not at the user surface.
- Default impl (`StringCursor`) covers production; users rarely instantiate the concept directly.

**Dropped from the proposals**:

- A2's `CursorHooks` (closure-based extension): nice but defer. Adds overhead even when nil. Re-evaluate after v1 ships.
- A4's `Token[I: SomeInterned]` parameterization: over-abstracted. TestCursor uses an empty interner, not a different Token type.
- A3's split into DocumentCursor + NodeCursor: cognitive load without proportional benefit.

---

## How each category rides the cursor

### Cat 1 — Streaming events

The cursor's `advance()` loop IS Cat 1. We expose it publicly as `streaming_parser.nim`:

```nim
proc parseDocument*[C: KdlCursor](c: var C, cb: proc(ev: CursorEvent)) =
  while true:
    let ev = c.advance()
    cb(ev)
    if ev.kind == ceEof: break
```

Or as an iterator. Users supply state via the callback. The visitor protocol's `vcArgs`/`vcProps`/etc. capability flags are NOT preserved — pull-based consumers naturally only pay for what they consume.

### Cat 2 — Typed decode (codegen)

The `kdl:` macro emits one `decode[T]` proc per user type:

```nim
proc kdlDecode*[C: KdlCursor](_: typedesc[Tree], c: var C):
    Result[Tree, ParseError] {.noSideEffect.} =
  var result: Tree
  let header = c.advance()  # ceNodeBegin
  if not bytesEq(c.bytes(header.nodeNameTok), "tree"):
    return err(initError(peTypeMismatch, header.span, "expected 'tree'"))

  # entries loop
  while true:
    case c.peek().kind
    of ceArg:
      let ev = c.advance()
      # decode positional arg into appropriate kdlArg field
    of ceProp:
      let ev = c.advance()
      let key = c.bytes(ev.propKeyTok)
      case bytesEq(key, "label")
      of true: result.label = ?decodeStringValue(c, ev.propValueTok)
      else: discard  # unknown prop: ignore or error per strict mode
    of ceChildrenBegin: discard c.advance(); break
    of ceNodeEnd: discard c.advance(); return ok(result)
    else: discard

  # children block (if entered)
  while c.peek().kind != ceChildrenEnd:
    if c.peek().kind == ceEof: return err(...)
    case bytesEq(c.bytes(c.peek().nodeNameTok), "tree")
    of true:
      result.children.add(?kdlDecode(Tree, c))   # ← direct recursion
    else:
      c.skip()  # unknown child: skip subtree
  discard c.advance()  # ceChildrenEnd
  ok(result)
```

**Self-recursive types work by construction** — function recursion via the system call stack. nkdl#7 + nkdl#11 closed as side effects.

`embed[T]` works: `kdlDecode` is `noSideEffect`, the cursor concept's required ops are `noSideEffect`, Nim VM can execute the whole chain at compile time.

### Cat 3 — AST/DOM (DocBuilder rewrite)

`DocBuilder` becomes a cursor consumer with an explicit node-construction stack:

```nim
proc buildDoc*[C: KdlCursor](c: var C, sourcePath = "<input>"):
    Result[KdlDoc, ParseError] {.noSideEffect.} =
  var doc = newDoc(sourcePath)
  var stack: seq[KdlNode] = @[]

  while true:
    let ev = c.advance()
    case ev.kind
    of ceNodeBegin:
      var node = newNode(c.bytes(ev.nodeNameTok))
      if ev.nodeAnnoTok.isSome:
        node.typeAnnotation = doc.interner.intern(c.bytes(ev.nodeAnnoTok.get))
      node.span = ev.span
      stack.add(node)
    of ceArg:
      var entry = KdlEntry(kind: keArgument, ...)
      stack[^1].entries.add(entry)
    of ceProp:
      var entry = KdlEntry(kind: keProperty, propName: ..., propValue: ...)
      stack[^1].entries.add(entry)
    of ceChildrenBegin, ceChildrenEnd: discard  # tracked via stack depth
    of ceNodeEnd:
      let n = stack.pop()
      if stack.len == 0: doc.nodes.add(n)
      else: stack[^1].children.add(n)
    of ceEof: break
    of ceError: return err(ev.err)
    else: discard

  ok(doc)
```

The annotation side-channel disappears (events carry annotations directly). The visitor protocol's strict event-ordering contract becomes the cursor's responsibility — every event is well-formed.

### Cat 4 — Incremental parser (deferred)

Use `replayFrom(savedPos)` to branch from a saved cursor position. After a source edit, re-lex from the nearest checkpoint, replay the cursor with the new TokenStream. LSP-style. Designed-in but not implemented in v1.

---

## The emitter (KdlEmitter concept) — symmetric inverse of the cursor

The cursor produces grammar events from wire bytes. The emitter accepts grammar
events and produces wire bytes. Both are concepts to allow multiple impls
(default impl writes to a `string` buffer; future impls could write to a stream,
splice into source-with-tombstones for preserve mode, or count for size-only).

```nim
type
  KdlEmitter* = concept e, var me
    push(me, CursorEvent)         ## emit a single event
    pushNodeBegin(me, name: string, anno: Option[string], span: Span)
    pushArg(me, val: KdlValue, anno: Option[string])
    pushProp(me, key: string, val: KdlValue, anno: Option[string])
    pushChildrenBegin(me)
    pushChildrenEnd(me)
    pushNodeEnd(me)
    pushSlashdashBegin(me)
    pushSlashdashEnd(me)
    finish(me) is string          ## commit; return wire bytes
    pos(e) is EmitterCheckpoint   ## save for branching
    seek(me, EmitterCheckpoint)   ## restore (for speculative emit)
```

The `push` overloads sit at the same grammar-event level as the cursor's
`CursorEvent` discriminated union. Higher-level helpers (`pushArg(val, ...)`)
take typed values, do the right quoting/escaping based on value kind. The
emitter owns:

- **Quoting decisions** — when to bareword, when to quote, when to raw-string.
- **Escape sequences** — `\n`, `\"`, `\u{}` rules per KDL v2.
- **Indentation + framing** — how children blocks are visually structured.
- **Annotation formatting** — `(tag)` placement.
- **Preserve-mode splicing** — when a node's `parseHash` matches the original
  source bytes, splice the original directly instead of re-emitting.

That last bullet is the key reason for the emitter: preserve-mode byte-exact
round-trip needs *one* implementation that all OUT producers share, not three.

Default impl: `BufferEmitter` writing to a `string`. The preserve variant
takes a source-bytes + parse-hash table at init time and consults them on
each push.

## How each category rides the emitter

### Cat 1 — User push events

The user assembles their event stream and pushes into the emitter directly:

```nim
var e = newBufferEmitter()
e.pushNodeBegin("config")
e.pushArg(newStringValue("prod"))
e.pushChildrenBegin()
e.pushNodeBegin("server")
e.pushProp("port", newIntValue(8080))
e.pushNodeEnd()
e.pushChildrenEnd()
e.pushNodeEnd()
let bytes = e.finish()
```

The Cat 1 OUT user-API. Useful for transform pipelines that don't want to
build a full KdlDoc.

### Cat 2 — Typed encode (codegen)

`deriveEncode` macro emits one `kdlEncode` proc per user type, pushing into
the emitter:

```nim
proc kdlEncode*[E: KdlEmitter](v: Tree, e: var E) {.noSideEffect.} =
  e.pushNodeBegin("tree")
  e.pushProp("label", newStringValue(v.label))
  if v.children.len > 0:
    e.pushChildrenBegin()
    for child in v.children:
      kdlEncode(child, e)           # ← direct recursion
    e.pushChildrenEnd()
  e.pushNodeEnd()
```

Same self-recursion model as kdlDecode — Nim's call stack handles depth.
`embed[T]` symmetry: `kdlEncode` is `noSideEffect`, the emitter concept
ops are `noSideEffect`, so compile-time encode-to-bytes works for any
embedded value.

### Cat 3 — Doc emit (replaces current encode(doc))

`docEmit` walks a KdlDoc, pushing events into the emitter:

```nim
proc docEmit*[E: KdlEmitter](doc: KdlDoc, e: var E,
                              mode: EmitMode = emCanonical) =
  for n in doc.nodes:
    nodeEmit(n, doc.interner, e, mode)

proc nodeEmit*[E: KdlEmitter](n: KdlNode, interner: Interner,
                              e: var E, mode: EmitMode) =
  e.pushNodeBegin(interner.lookup(n.name), ...)
  for entry in n.entries:
    case entry.kind
    of keArgument: e.pushArg(entry.argValue, ...)
    of keProperty: e.pushProp(interner.lookup(entry.propName),
                              entry.propValue, ...)
  if n.children.len > 0:
    e.pushChildrenBegin()
    for child in n.children:
      nodeEmit(child, interner, e, mode)
    e.pushChildrenEnd()
  e.pushNodeEnd()
```

In `emPreserve` mode, the emitter (not `nodeEmit`) checks parseHashes and
decides whether to splice original bytes or re-emit. The single source of
truth for preserve logic.

---

## Property catalog — the new PBT contracts

The branch rebuild's property tests target the substrate's load-bearing
invariants, not the user-API. Twelve properties across five suites:

### Foundation (cursor + emitter)

- **P1: Cursor–emitter event round-trip.** For any well-formed event sequence E
  (from a grammar-aware generator):
  `emit(E) → bytes → cursor → E' ≡ E (modulo span normalization)`.
  THE foundation invariant. If P1 holds, every higher-level round-trip is
  automatically correct.

- **P2: Source → events → bytes → events idempotence.** For any parseable B:
  `B → cursor → events → emit → B' → cursor → events' ≡ events`.
  Canonical-form idempotence at event level.

- **P3: Cursor safety under arbitrary bytes.** Random byte input never crashes,
  always terminates in `ceEof` or `ceError`. (Already in
  `tests/test_cursor_properties.nim`; preserved.)

### Cat 3 (buildDoc + docEmit)

- **P4: Doc structural round-trip.** For any parseable B:
  `B → buildDoc → KdlDoc → docEmit → B' → buildDoc → KdlDoc'` such that
  `docEqual(KdlDoc, KdlDoc')`.

- **P5: Preserve byte-exact (no mutations).** For any parseable B:
  `B → buildDoc(preserveFormat) → docEmit(emPreserve) → B` (byte-exact).

- **P6: Preserve under arbitrary mutation sequences.** For any parseable B
  plus any op sequence: mutated doc emits + reparses to a structurally-equal
  doc. (Replaces stateful tests in current `test_preserve_properties.nim`.)

### Cat 2 (deriveDecode + deriveEncode)

- **P7: Typed-T encode–decode identity.** For arbitrary T:
  `T → kdlEncode → bytes → kdlDecode → T'` such that `T == T'`. Strict-symmetric
  (per the Phase 0 discipline). Re-activates L1/L2/L3 and self-recursive Tree.

- **P8: Encode determinism.** Same T encodes to same bytes.

### Cross-category (the symmetry tests — only possible on the new architecture)

- **P9: Cat 2 ↔ Cat 3 agreement.** For parseable B containing T-shaped nodes:
  `buildDoc(B) → encode T subtree` ≡ `decode[T](B subtree) → encode T`.
  Catches asymmetries where Cat 2 and Cat 3 disagree on the same input.

- **P10: Cat 1 push consistency.** A hand-written Cat 1 consumer that builds a
  KdlDoc produces the same doc as `buildDoc`. (buildDoc is one specific Cat 1
  consumer; alternates must agree.)

### Safety

- **P11: deriveDecode never crashes.** Arbitrary bytes input: returns Ok or
  Err, never IndexDefect / unhandled exception / infinite loop.

- **P12: Emitter never produces unparseable bytes.** For any event sequence the
  cursor can produce: pushing those events into the emitter produces bytes
  that the cursor accepts.

### New infrastructure required

The substrate-properties (P1, P2) need a **grammar-aware event-sequence
generator** that produces sequences respecting:

- Bracket balance (NodeBegin/End, ChildrenBegin/End, SlashdashBegin/End)
- KDL semantics (at-most-one-real-children, no-entries-after-children, etc.)
- Edge-case biasing (deep nesting, all slashdash positions, all annotation
  positions, every value type)

Estimated ~200-300 LOC. The right tool for testing a grammar-driven substrate;
reusable for fuzz testing, future feature additions, and Cat 4 (LSP) work.

---

## Execution plan: branch-rebuild instead of incremental phases

**Phases 0-2 landed incrementally on main.** Phases 3-6 supersede the
original incremental sequencing — they execute as a branch rebuild because
incremental coexistence has compounding costs (see below).

### What stays on main (proven foundation)

- `src/cursor.nim` — KdlCursor + StringCursor (Phase 1)
- `src/parser.nim` — parse/parseAll already ride buildDoc (Phase 2)
- `src/lexer.nim`, `src/intern.nim`, `src/spans.nim`, `src/ast.nim`, `src/numlit.nim`, `src/reserved.nim`, `src/fnv.nim` — wire + types, untouched
- `tests/test_cursor.nim`, `tests/test_cursor_properties.nim`, `tests/test_build_doc.nim` — substrate tests

### What gets deleted in the rebuild

- `src/typed_parser.nim` — visitor protocol + parseDocumentWith
- `src/doc_builder.nim` — visitor-based DocBuilder (buildDoc in cursor.nim replaces it)
- `src/codegen.nim` — most of it (deriveVisitor + parseInto + decode[T] machinery; ~2000 LOC)
- `src/encode.nim` direct-byte-writer machinery
- `test_visitor_*`, `test_doc_builder.nim`, `test_doc_builder_conformance.nim`, `test_parametric_builders.nim`, `test_typed_parser.nim`, etc.
- Old PBT suites (`test_preserve_properties.nim`, `test_typed_decode_properties.nim`) — replaced by new property catalog

### What gets rebuilt on the branch

- `src/emitter.nim` (NEW) — KdlEmitter concept + BufferEmitter impl
- `src/encode.nim` (NEW, smaller) — `docEmit` + value-formatting helpers driving the emitter
- `src/codegen.nim` (NEW, smaller) — `deriveDecode` + `deriveEncode` both pushing through cursor/emitter; the `kdl:` macro orchestrates
- `tests/test_substrate_properties.nim` (NEW) — P1, P2
- `tests/test_cat3_properties.nim` (NEW) — P4, P5, P6
- `tests/test_cat2_properties.nim` (NEW) — P7, P8, re-activated L1/L2/L3
- `tests/test_crosscat_properties.nim` (NEW) — P9, P10
- `tests/test_safety_properties.nim` (NEW) — P11, P12

### Why branch-rebuild instead of incremental on main

Five conditions favor branch-rebuild over incremental for nkdl:

1. **Pre-1.0, private, no external users.** No compat constraint.
2. **Strong test gate.** 558+ unit + property suites + 338 conformance fixtures catch regressions immediately.
3. **The new substrate is design-stable.** Cursor + buildDoc are complete and proven by Phases 1-2.
4. **Legacy code is 100% parallel.** Nothing in typed_parser.nim or deriveVisitor is load-bearing for anything except itself.
5. **Codebase is small.** ~10K LOC of src/; a focused rebuild is tractable.

Incremental coexistence costs (avoided by the branch): every new piece on
main gets subtly shaped by what legacy expects. The emitter design would be
constrained by what `encode(doc)` currently looks like. deriveDecode would
be constrained by `kdlBuildVisitor`'s mixin contract. Phase 5's "delete the
legacy" big-bang would arrive late, scarier, with the new code grown into
the legacy's shape.

### Operational plan

See `docs/branch-rebuild-plan.md` for the sequencing (delete order, build
order, per-cycle validation, where to resume mid-session).

### Standalone issues (not in the milestone)

- Extract `hashNodeFromChildHashes` from `encode.nim` to its own small module
  (`src/hash.nim` or similar). Decouples `grammar.nim`'s differential oracle
  from encode internals.
- `path.nim` product direction: commit as a real surface, demote to
  `.where()` iterator helpers only, or move to `examples/`. Decide before v1.

### Existing issues — disposition

- **#7** (self-recursive seq[Self]): closed in Phase 3 by construction (call-stack recursion).
- **#8** (parametric SeqBuilder[B]): closed as superseded.
- **#9** (deriveEncode ref-object): subsumed into branch rebuild (deriveEncode is rewritten).
- **#10** (pull-based decoder RFC): superseded by this RFC.
- **#11** (depth-2+ nested children): closed in Phase 3 by construction.
- **#16, #17, #18** (Phase 3 deriveDecode, Phase 4 Cat 1 productization, Phase 5 delete obsolete): superseded by the branch-rebuild plan; closed with link to `docs/branch-rebuild-plan.md`.
- **#19** (Phase 6 bench gate): kept as the final validator at the end of the branch work.

---

## Open design questions for implementation

These didn't get resolved in the design exploration; flag during implementation:

1. **Token allocation strategy in `CursorEvent`**: copy by value or use a side-table reference? For 9-kind events with at most 3 Token fields, by-value is ~80 bytes per event. Stack-allocated, no heap. Should be fine. Validate on bench.

2. **Slashdash handling**: should `ceSlashDash` be a separate event emitted BEFORE the slashdash'd event, or should the slashdash'd event carry a `slashdashed: bool` flag? Latter is simpler; consumers ignore the flag if they don't care. Probably go with the flag approach.

3. **`peek()` vs lookahead**: should the cursor expose multi-token lookahead? KDL's grammar probably needs only 1-token lookahead at the event level, but we should confirm during Phase 1.

4. **Error recovery in `advance()`**: when the cursor hits a lex/parse error, does it emit `ceError` + try to recover at the next node boundary, or does it require the consumer to call `c.skipToRecovery()` explicitly? Convention should match `decodeAll` semantics — accumulating mode at the cursor layer would let Cat 1, 2, 3 share recovery.

5. **`replayFrom` semantics with multi-error accumulation**: if the cursor is in accumulating mode and the consumer replays from a saved position, do prior errors stay in the buffer or get discarded? Probably stay (the consumer can prune if needed).

6. **Cat 1's interaction with `embed[T]`**: streaming consumers writing visitors don't go through compile-time embed. Confirm that the visitor protocol's public-API shape doesn't accidentally constrain the cursor's compile-time eligibility for Cat 2.

---

## Why this is best-in-class

- **Mirrors mature library pattern** (Jackson, System.Text.Json, etc.) — proven design space.
- **Self-recursion + arbitrary nesting** works by construction. Not a patch; the call stack IS the substrate.
- **Each category has its own consumer module** sized to its concern. No multi-master pressure on the foundation.
- **Concept-based cursor** opens future implementation strategies (incremental, file-backed, mock) without touching the consumer code.
- **Symmetric with encode**: `deriveEncode` is already pull-based recursive descent. After this milestone, the encode/decode story is symmetric — both walk over typed values using function recursion, both compile-time-eligible for `embed[T]`.
- **Code reduction**: ~1200 LOC removed (visitor protocol + per-T XVBuilder emission). Codegen complexity drops substantially.

---

## What this RFC does NOT decide

- The exact `CursorEvent` field types — defer to Phase 1 prototype.
- Whether `StringCursor` is a value type or `ref object` — defer.
- The exact error-recovery API at the cursor layer — defer to Phase 1.
- Cat 1's public API surface naming + cookbook content — defer to Phase 4.
- Perf optimizations (event-pool reuse, etc.) — defer to Phase 6 bench results.

Each phase opens its own design surface; this RFC commits to the layering, not the leaves.

---

## References

- Three-categories framework: introduced in nkdl session 2026-05-28 conversation log
- Visitor protocol's current implementation: `src/typed_parser.nim` (~600 LOC)
- DocBuilder current implementation: `src/doc_builder.nim` (~250 LOC)
- Codegen's per-T XVBuilder emission: `src/codegen.nim` lines 2107-2900 (~800 LOC)
- Encoder side (already pull-based, the reference shape): `src/encode.nim` + `deriveEncode` in `src/codegen.nim`
- Inspiration: Jackson's `JsonParser` + `ObjectMapper`; System.Text.Json's `Utf8JsonReader` + `JsonSerializer`; serde-derive's `Deserialize`.
