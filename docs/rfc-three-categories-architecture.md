# RFC: Three-Categories Architecture (v1)

**Status**: Approved, not yet implemented. Drives the v0.x→v1 rewrite.
**Filed**: 2026-05-28 — TBD GitHub milestone after context compaction.
**Supersedes**: nkdl#8 (parametric SeqBuilder), nkdl#10 (pull-based decoder RFC), partially closes nkdl#7 + nkdl#11 by construction.
**Status before this RFC**: nkdl is private; visitor-protocol architecture had latent depth-2+ nested-children bug surfaced by proptest property suite; user decided to redesign instead of patching.

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

## Target architecture: token cursor as foundation

```
                                         ┌──────────────┐
                                         │ User code    │
                                         └───┬──────┬───┘
            ┌─────────────────────────────────┘      │
            │                                        │
   Cat 2: decode[T](source)              Cat 1: streaming events
   Cat 3: parse(source) → KdlDoc                    │
            │                                        │
   ┌────────▼─────────┐                ┌─────────────▼──────────┐
   │ Pull-based       │                │ Cat 1 driver           │
   │ recursive descent│                │ (exposes events)       │
   └────────┬─────────┘                └──────────┬─────────────┘
            │                                    │
            └────────────┬───────────────────────┘
                         │
                ┌────────▼────────┐
                │ KdlCursor        │  ← Nim concept; multiple impls
                │ (grammar-aware)  │     StringCursor, TokenListCursor,
                └────────┬─────────┘     future IncrementalCursor
                         │
                  ┌──────▼──────┐
                  │ Lexer        │
                  └─────────────┘
```

Three consumer modules. One shared cursor primitive. Lexer untouched.

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

## Phasing (filing plan)

**Milestone: Three-Categories Architecture v1**

1. **RFC** (this document, filed as tracking issue with link to docs/rfc-three-categories-architecture.md)
2. **Phase 0: property-test discipline pass** — replace `assumeOk(decode[T](text))` with strict `let v = decode[T](text); ensure v.isOk; let val = v.get`. Exposes all latent bugs. Validates the existing 33-property suite is meaningful.
3. **Phase 1: cursor module** — `src/cursor.nim` defining `KdlCursor` concept, `CursorEvent`, `StringCursor` default impl. Unit tests against synthetic event sequences.
4. **Phase 2: DocBuilder rewrite** — rewrite `src/doc_builder.nim` to ride the cursor. Validation gate: all 18 AST property tests + 668 example tests + 338-file conformance corpus pass unchanged.
5. **Phase 3: pull-based decode codegen** — replace `deriveVisitor` with `deriveDecode`. Cat 2 typed-decode now uses cursor + direct function recursion. Validation gate: strict-mode typed-decode property suite passes (including Tree at arbitrary depth + L1→L2→L3).
6. **Phase 4: Cat 1 productization** — rename `typed_parser.nim` → `streaming_parser.nim`, restructure as cursor consumer, document, expose supporting types in the umbrella, write `docs/streaming-cookbook.md` with 4-5 example visitors.
7. **Phase 5: delete obsolete codegen** — remove deriveVisitor's per-T XVBuilder/XVBuilderSeq emission, `kdlBuildVisitorSeq`/`kdlBuildVisitorAllSeq` wrappers. Net code reduction: ~1200 LOC.
8. **Phase 6: bench gate** — measure against current ~46.9μs/100-Service baseline. ±10% acceptable. Profile if outside.

**Standalone issues (not in the milestone)**:

- Extract `hashNodeFromChildHashes` from `encode.nim` to its own small module (`src/hash.nim` or similar). Decouples `grammar.nim`'s differential oracle from encode internals.
- `path.nim` product direction: commit as a real surface, demote to `.where()` iterator helpers only, or move to `examples/`. Decide before v1.

**Existing issues — disposition**:

- **nkdl#7** (self-recursive seq[Self] compile failure): closed by Phase 3 (cursor-based codegen). Add "fixed by milestone" link when filing.
- **nkdl#8** (parametric SeqBuilder[B]): closed as superseded. Approach was correct direction but token-cursor primitive supersedes the per-T parametric machinery.
- **nkdl#9** (deriveEncode ref-object): keep open. Orthogonal; revisit after milestone. Becomes simpler under cursor architecture because encode is already pull-based — just relax the type check.
- **nkdl#10** (pull-based decoder RFC): closed as superseded by this RFC.
- **nkdl#11** (depth-2+ nested children corruption): closed by Phase 3 (state lives on the call stack, not in struct fields).

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
