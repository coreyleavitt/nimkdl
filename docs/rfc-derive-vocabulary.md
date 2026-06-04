# RFC: Cat-2 derive-vocabulary completion

**Status:** **IMPLEMENTED (2026-06-03)** — all 17 slices (S0a–S10 + S-doc) landed
on `core-rebuild`, full + gated property suites green. Architect rounds 1 + 2
applied; all forks resolved (S0.5 `kdlScalar` hook = corrected KdlValue
interchange, §8). Pragma reference: `docs/derive-reference.md`. Seeded
from the gap audit after the core-rebuild RFC landed: `docs/rfc-core-rebuild.md`
§8.3/§8.5/§8.7 specify a derive vocabulary only partially built. The core rebuild +
§8.7 dispatch hardening are done + green on `core-rebuild`; this RFC finishes the
*vocabulary*.

**Scope:** `src/derive_decode.nim`, `src/derive_encode.nim`, `src/pragmas.nim`,
`src/kdl_block.nim`, a new `src/derive_common.nim`, and (S0.5) exposing a
`tokenToKdlValue` helper. No other substrate change.

**Non-goals (explicit):**
- **KQL** — won't-fix; the typed-path DSL is the better answer.
- **SSO / Stage-0** — data-gated substrate perf, tracked separately.
- **Versioning / publish / stability policy** — process, not code.
- **Typed byte-preserve** — #31, a v0.3 subsystem.
- **Unknown-field capture (`kdlCatchAll`)** — deferred + filed **#40**.
- **Binary/blob fields** — via `{.kdlScalar.}` + a user codec until #31.
- **Container/coverage gaps** — `seq[seq[T]]`, `Table[K,V]`, `tuple` fields,
  `range`/`Natural`/`Positive` bounds, `char`. These hit `emitTypedDecode`'s
  `else` → a loud macro `{.error.}` today (verified), directing the user to
  `{.kdlScalar.}`. Out of scope here; a `range`-bounds slice is noted in §6.
- **Conformance corpus entries** — the corpus is KDL-grammar-level + impl-
  independent; derive-layer behavior is exercised by unit + property tests only.

---

## 1. Summary

Implemented so far: `kdlNode`, `kdlArg`, `kdlProp`, `kdlChild`, `kdlSkip`,
`kdlRename`, `kdlReserved`, `kdlScalar`. This RFC adds the rest of §8.3/§8.5/§8.7,
the deferred pragmas (`kdlAlias`, directional skip, `kdlFlatten`, untagged
variants), and inherited defaults. The first slices (S0a–S0c) extract the
duplicated helpers into `derive_common.nim` and stabilize the internal shapes the
later slices need.

**Full post-RFC pragma surface (mental model):**
- *Type-level:* `kdlNode`, `kdlRenameAll`, `kdlIgnoreUnknown`, `kdlEncodeOnly`,
  `kdlDecodeOnly`.
- *Field-level:* `kdlArg`, `kdlVariadic`, `kdlProp`, `kdlChild`, `kdlScalar`,
  `kdlRename`, `kdlAlias`, `kdlReserved`, `kdlSkip`, `kdlSkipEncode`,
  `kdlSkipDecode`, `kdlFlatten`.

The directional control split (round 2): **type-level = generation direction**
(`kdlEncodeOnly`/`kdlDecodeOnly`, positive intent, can only annotate a type);
**field-level = field exclusion** (`kdlSkip`/`kdlSkipEncode`/`kdlSkipDecode`).
Distinct names, no same-name-two-meanings.

## 2. Motivation

Half-built vocabulary is worse than none. These are table-stakes for a derive
macro and cheap on the clean substrate. Filed during this RFC
([[feedback_defer_file_now]]): `kdlCatchAll` extension-bag → **#40**.

## 3. Current gap inventory (verified)

| RFC ref | Item | Built? |
|---|---|---|
| §8.7 | `derive_common.nim` dedup | ❌ |
| §8.3 | `kdlVariadic` (variadic positional args) | ❌ |
| §8.3 | `kdlRenameAll(convention)` + `nodeNameOf` casing | ❌ |
| §8.3 | type-level `kdlEncodeOnly`/`kdlDecodeOnly` | ❌ |
| §8.3 | type-level `kdlIgnoreUnknown` | ❌ |
| §8.5 | native field defaults | ❌ |
| §8.3 | `kdlAlias` | ❌ (deferred) |
| §8.3 | directional skip (field) | ❌ (deferred) |
| §8.3 | `kdlFlatten` | ❌ (deferred) |
| §8.6 | untagged variants | ❌ (deferred) |
| §8.5 | inherited-field defaults | ❌ (noted limit) |

## 3.5 Cross-cutting decisions

### 3.5.1 Naming scheme

Type-level direction = `kdlEncodeOnly` / `kdlDecodeOnly` (suppress the *other*
direction's proc generation). Field-level exclusion = `kdlSkip` (both),
`kdlSkipEncode`, `kdlSkipDecode`.

### 3.5.2 Conventions — typed enum (with identity)

```nim
type KdlNamingConvention* = enum
  kcVerbatim,           ## field name unchanged (identity / documents intent)
  kcKebabCase,          ## maxRetries → max-retries
  kcCamelCase,          ## max_retries → maxRetries   (lower first letter)
  kcSnakeCase,          ## maxRetries → max_retries
  kcPascalCase,         ## max_retries → MaxRetries   (upper first letter)
  kcScreamingSnakeCase  ## maxRetries → MAX_RETRIES
```

`kc` prefix matches the codebase's 2-letter enum convention (`kv`, `pe`, `tk`,
`ck`, …). A garbage convention is unrepresentable — no runtime failure mode.

### 3.5.3 Naming precedence + composition (canonical)

`kdlRename` sets the exact wire key (no convention). `kdlRenameAll` applies the
convention to the Nim field name. `kdlAlias` strings are **exact wire-key
literals** — never convention-transformed. `kdlRenameAll` affects field keys only,
not the node name (`kdlNode`/`nodeNameOf`).

| Set | Canonical encode key | Accepted decode keys |
|---|---|---|
| nothing | field name | {field name} |
| `kdlRenameAll` | convention(field name) | {convention(field name)} |
| `kdlRename` | explicit | {explicit} |
| `kdlRename` + `kdlAlias` | explicit | {explicit} ∪ aliases |
| `kdlRenameAll` + `kdlAlias` | convention(field name) | {convention(field name)} ∪ aliases |

The single resolver is **`wireKeyOf(fieldName, pragmas, convention): string`** in
`derive_common` (added in S2b): `kdlRename` wins over `kdlRenameAll`; pure; unit-
tested. Classify resolves all canonical keys first, then adds aliases, then checks
the union for global uniqueness.

### 3.5.4 Duplicate keys — last-wins (Cat-2 ↔ Cat-3 parity)

A repeated prop key, or a second `ckSingle` child of the same type, is last-wins
(matches the Cat-3 DOM). Falls out of the `or`-bitmap; documented + tested.

### 3.5.5 Error policy

Prefer macro-time `{.error.}` for statically-detectable misuse (no new code). New
*runtime* `ParseError` producers get a semantic code past `peOther` + a bijection-
lint update ([[error_catalog_discipline]]): S9 → **`peTypeNoVariantMatch`**;
S5 missing-required keeps `peTypeMissingRequired` but names the field. Everything
else in S1–S8 (wrong pragma target, arg/flatten conflicts, >64 slots, flatten-on-
variant) → macro `{.error.}`.

#### 3.5.5.1 Macro error-message format

`{construct} on {field/type}: {constraint violated}. {fix hint}`. Pinned examples
(implementers must match this quality):
- `{.kdlVariadic.} requires a seq[T] field; 'port' has type 'int'.`
- `{.kdlArg.} on a seq field 'tags' consumes only one argument. Did you mean {.kdlVariadic.}?`
- `{.kdlFlatten.} cannot apply to a variant field; 'Config' has a case discriminator.`
- `{.kdlSkipEncode.} on positional-arg field 'weight' would shift arg indices and corrupt round-trips. Use {.kdlSkip.}.`
- `{.kdlScalar.} on 'color: Color' needs 'kdlDecodeValue(val: KdlValue): Result[Color, string]' in scope before the kdl: block.`
- `Type 'Config' exceeds 64 required/defaulted slots (got N). Split it or {.kdlFlatten.} an inner object.`

### 3.5.6 `distinct` types

All slices inherit `baseTypeName`'s behavior: a `distinct T` field errors at
compile time unless a `{.kdlScalar.}` hook is supplied. The S2 case engine operates
on the field *name* string, so `distinct` field types are unaffected by renaming.

### 3.5.7 Documentation deliverable

Every slice updates the `pragmas.nim` doc comment(s) for the pragma(s) it adds (an
acceptance criterion, not optional). The final slice ships a complete pragma
reference (consolidated doc comments + a `docs/derive-reference.md` table).

## 4. Design (per slice)

### S0a — `derive_common.nim` pure move (characterization slice)

Move the ~12 duplicated helpers (`nodeNameOf`, `fieldInfo`, `regularFields`,
`findRecCase`, `objectRecList`, `pragmaHead`, `hasPragma`, `pragmaArg`,
`isOptionType`, `innerOfOption`, `isEnumType`, `baseTypeName`) into
`src/derive_common.nim`; both derive files import it. **Zero behavior change — no
RED test exists for a pure move.** Protocol (per `/characterize`): full + gated
property suites green *before* and *identical after*; the suite is the
characterization oracle.

### S0b — internal shape stabilization

- **`regularFields` → 4-tuple** `(name, typ, pragmas, default: NimNode)` (default =
  `IdentDefs[^1]` or `newEmptyNode()`). Existing sites destructure `(…, _)`.
- **Field tuples (`ArgField`/`PropField`/`ChildField`) gain `pathExpr: NimNode`**
  (the LHS access) **and `requiresUncheckedAssign: bool`** (true only for the
  variant discriminator field — round-2 depth: a discriminator write outside its
  branch is illegal and must stay wrapped in `{.cast(uncheckedAssign).}` at every
  emit site, not just the current argCase site).
- **`classify` gains `baseExpr: NimNode = nil`** (round-2 feasibility — `vSym` *is*
  in scope at classify time, so `pathExpr` is buildable, but S8's compound paths
  need a prefix): `pathExpr = newDotExpr(baseExpr ?? vSym, ident(name))`. S0b uses
  the nil/`vSym` default; S8 passes the parent path.
- RED: `regularFields` yields the default node when present; a discriminator field
  carries `requiresUncheckedAssign = true`.

### S0c — the two latent encode bugs (natural RED tests)

- **Canonicalize `isOptionType` to the `eqIdent` form**; delete encode's
  `$t[0] == "Option"` (mishandles qualified `std/options.Option`). RED: a
  qualified-`Option` field decodes/encodes correctly.
- **Encode `dispatchField` gets the inference else-branch** decode already has
  (today encode silently drops a no-pragma field). RED: a no-pragma primitive
  field round-trips symmetrically; seq-of-primitives → macro error.

### S1 — `kdlVariadic` (variadic positional args)

Field pragma `kdlVariadic` on a `seq[T]`: collects all positional args beyond the
fixed `kdlArg` fields. Routed to a dedicated `variadicField: Option[ArgField]` (not
into `argFields`); excluded from the required bitmap.

- **Decode:** the `argCase` `else` becomes "if a variadic field exists, decode the
  element + `add`; else the existing too-many-args error."
- **Encode (required invariant):** two-pass — all fixed `kdlArg` fields in
  declaration order **first**, then the variadic elements.
- **Macro errors:** `>1` variadic; non-seq; object/child-shaped element type;
  loud `kdlArg`-on-seq → "did you mean `kdlVariadic`?" and inverse.

### S2a — `nodeNameOf` acronym-aware casing fix (BREAKING)

Replace the lowercase-everything fallback (`HTTPServer → httpserver`) with
acronym-aware word-split → kebab (`HTTPServer → http-server`,
`MyService → my-service`). **Breaking** for kdl-block types without an explicit
`kdlNode` whose Nim name has uppercase runs — pre-1.0/zero-consumers, so we take
the correct behavior. **Pre-work:** audit `tests/`+fixtures for such names; add
`kdlNode` or update expected names. `BREAKING CHANGE:` commit footer. The
`splitWords`+join engine lives in `derive_common` (reused by S2b); pure, macro-time.

**Oracle:** `HTTPServer→http-server`, `MyService→my-service`, `Service→service`,
`IOError→io-error`.

### S2b — `kdlRenameAll(KdlNamingConvention)`

Type-level `{.kdlRenameAll: kcKebabCase.}` applies the convention (via `wireKeyOf`)
to every field's canonical key for decode (`bytesEqLit` literal) + encode, unless
`kdlRename` is set. Applied at macro time to the field *name*, not matched against
wire bytes. **`wireKeyOf` is added here** (§3.5.3 contract) + unit-tested.

### S3 — type-level `kdlEncodeOnly` / `kdlDecodeOnly`

The `kdl:` block reads these off the type pragma list and skips the corresponding
derive emission. A `{.kdlDecodeOnly.}` type has no `kdlEncode`. **Footgun doc:** a
`{.kdlDecodeOnly.}`-only type (no decode) used as a `{.kdlChild.}` makes the
parent's encode fail to compile (missing overload) — intentional, documented.

### S4 — strict unknown-children + `kdlIgnoreUnknown`

Round-2 correction: unknown children are silently skipped today; only unknown
*props* error. Two steps:
- **Step 1 (strict):** the child-dispatch's **`ceNodeBegin` if-elif final else**
  (the named-node-unmatched branch — NOT the separate, already-correct slashdash
  branch) returns `peTypeUnknownField`. Audit tests for any relying on silent
  child-skip.
- **Step 2:** type-level `kdlIgnoreUnknown` threads `ignoreUnknown: bool` into the
  prop **and** child builders, flipping both `else`s to `skip()`.

### S5 — native field defaults

Collect, during slot allocation, a **`defaultedFields: seq[tuple[slot: int,
pathExpr: NimNode, defaultExpr: NimNode]]`** (round-2 feasibility: index by *slot*,
not declaration order — optional fields get slot −1 and would misalign a
declaration-indexed array). Post-decode:

```nim
if (seenSym and requiredMask) != requiredMask:
  return err(initError(peTypeMissingRequired, span,
             "missing required field '" & <firstUnsetRequiredWireKey> & "'"))
for f in defaultedFields:
  if (seenSym and (1'u64 shl f.slot)) == 0:
    <f.pathExpr> = <f.defaultExpr>
```

- **Variant branch fields are excluded from `defaultedFields`** (round-2 depth:
  assigning an inactive branch's field corrupts the object); branch-field defaults,
  if any, apply inside the per-branch path.
- **Name the missing field by its WIRE key** (post-`kdlRenameAll`) via `wireKeyOf`
  (round-2 breadth). `claimSlot` gains `required: bool` so defaulted fields claim a
  slot without entering `requiredMask`.
- **embed[T]/VM:** `{.error.}` if a default expr is a `Call`/`Command` whose head
  lacks `{.noSideEffect.}`.

### S6 — `kdlAlias`

Field pragma `{.kdlAlias: "colour", "old".}`: extra decode-only exact-literal keys;
encode uses canonical. `PropField` gains `aliases: seq[string]`; classify validates
the canonical∪alias union (§3.5.3).

- **FNV-hash interaction:** any field with ≥1 alias sets `useHash = false` for the
  **whole type** (the hash table is one-key→one-field and alias-blind). On a wide
  type this degrades prop lookup O(1)→O(n); acceptable; a full-hash-table fix
  (alias keys in the table) is later work (**#41**). **AC:** a >8-field type
  *with* an alias round-trips (exercises the if-elif fallback).

### S7 — directional skip (field-level)

`{.kdlSkipDecode.}` → not read (keeps default; composes with S5).
`{.kdlSkipEncode.}` → not written. **Macro error:** `kdlSkipEncode` on a `kdlArg`
field (shifts arg indices → silent corruption). `kdlSkipDecode` on a `kdlArg` is
fine (counter still advances; field keeps its default).

### S8a — `kdlFlatten` decode

`{.kdlFlatten.}` splices a nested object's args/props/children into the parent
namespace. Classify recurses (passing `baseExpr` = the flat field's path) so sub-
fields get compound `pathExpr`s.

- **Arg-index:** flattened arg sub-fields take contiguous `argIdx` slots in
  declaration order, computed against the parent's pre-counted fixed-arg total.
- **Collision detection on WIRE keys** (post-rename, via `wireKeyOf`), not Nim
  names → macro error on collision.
- **64-slot bound:** shared counter; overflow = the `claimSlot` error naming flatten.
- **Depth guard:** thread `flattenDepth`; `>8` → error; detect self-flatten.
- **Macro error:** `kdlFlatten` on a `RecCase`-bearing type (variant) — discriminator
  ordering unresolved; out of scope.

### S8b — `kdlFlatten` encode + interaction matrix

Encode emits flattened entries inline (compound `pathExpr` + value-typed pushes).
**AC — pin the cross-pragma matrix** (round-2 breadth): `kdlRenameAll`×flatten,
`kdlAlias`×`kdlRenameAll`, `kdlSkipDecode`×flatten, `kdlVariadic`+flatten on one
parent, `kdlIgnoreUnknown`×flatten (unknown = parent namespace), `Option[FlatObj]`
flatten (whole sub-tree absent → None).

### S9 — untagged variants (optional; concrete gate) — **IMPLEMENTED**

Try each `of`-branch in declaration order (cursor `pos`/`seek` rewind);
first full decode wins; encode emits the active branch; no-match →
`peTypeNoVariantMatch`.

- **Trigger:** type-level `{.kdlUntagged.}` pragma on a `case` object. Distinguishes
  the untagged path from the existing discriminator-driven (tagged) variant decode.
- **Gate (macro-time, countable):** implemented — supported iff Σ(branch field
  counts) ≤ 20 **and** no branch has a `ckSeq` (seq child) or nested variant; a
  violating type is a macro `{.error.}` directing the user to add an explicit
  discriminator.
- **Mechanism:** the single-node decode-body construction was factored into a
  `buildNodeBody` closure (called once for plain/tagged, once per branch for
  untagged with branch fields treated as required top-level fields). Each branch
  attempt is wrapped in a labelled `block`; a `rewriteReturnsToBreak` AST pass
  lifts the skeleton's `return <Result>` exits into `attemptRes = …; break <label>`
  so the wrapper can inspect the Result, `seek` back, and try the next branch
  rather than returning from the whole proc. The discriminator is force-assigned
  per attempt under `{.cast(uncheckedAssign).}` (it is not on the wire). Encode
  reuses the existing tagged `case v.disc` dispatch but skips emitting the
  discriminator field for `{.kdlUntagged.}` types.
- **VM-safety AC:** verified — `pos`/`seek` are side-effect-free (Nim infers
  `noSideEffect`; they touch only their params) and VM-evaluable, so the emitted
  `{.noSideEffect.}` decoder compiles AND a `{.kdlUntagged.}` type decodes inside
  `embed[T]` at compile time (proven by `tests/test_embed.nim`). S9 types are NOT
  `embed[T]`-incompatible — the escape-hatch defer was not needed.
- **Error code:** new `peTypeNoVariantMatch = 18` (appended past `peOther`;
  bijection lint in `tests/test_error_codes.nim` updated; bound is now 0..18).
- **Tests:** `tests/test_derive_decode.nim` (S9 suite: per-branch decode, no-match,
  empty-node, two gate macro-errors), `tests/test_derive_encode.nim` (S9 suite:
  per-branch encode without discriminator + round-trip), `tests/test_embed.nim`
  (compile-time VM proof).

### S10 — inherited-field defaults

`nnkOfInherit`: add an **`allFields(typeSym)`** iterator to `derive_common` that
walks the `objTy[1]` inheritance chain base-first, delegating to `regularFields`
per level. Classify uses it. Decision: handle if clean; else a clear compile error
(never silent drop).

## 5. Stages → slices

| Slice | Title | Risk |
|---|---|---|
| S0a | `derive_common` pure move (characterization) | low |
| S0b | shape stabilization (4-tuple, pathExpr, uncheckedAssign, baseExpr) | low–med |
| S0c | encode bug fixes (isOptionType, inference else) | low |
| S0.5 | `kdlScalar` hook → KdlValue interchange (see §8) | **high** |
| S1 | `kdlVariadic` | low |
| S2a | `nodeNameOf` acronym casing (BREAKING) | med |
| S2b | `kdlRenameAll` + `wireKeyOf` | med |
| S3 | `kdlEncodeOnly`/`kdlDecodeOnly` | low |
| S4 | strict children + `kdlIgnoreUnknown` | med |
| S5 | native defaults (slot-indexed; named missing) | **high** |
| S6 | `kdlAlias` (forces if-elif) | med |
| S7 | directional skip (+ kdlArg guard) | low |
| S8a | `kdlFlatten` decode | high |
| S8b | `kdlFlatten` encode + interaction matrix | high |
| S9 | untagged variants (gated) — **IMPLEMENTED** (gate met; VM-safe; not deferred) | high |
| S10 | inherited defaults (`allFields`) | med |
| S-doc | consolidated pragma reference | low |

Order: S0a→S0b→S0c→S0.5 first (foundation + scalar path), then S1…; S2a before
S2b; S5 before S6/S7/S8 (it sets the slot machinery the others build on); S8a
before S8b.

## 6. Risks + open items

- **S5 slot indexing** — the single highest-leverage correctness point; the
  slot-aligned `defaultedFields` model (§4 S5) is mandatory — downstream slot users
  (S6/S7/S8) inherit it.
- **S0.5** — high; `KdlValue` is span-free (§8); needs `tokenToKdlValue` exposed.
- **S6 alias × wide type** — whole-type O(n) fallback, documented; full fix later.
- **S8 flatten** — top complexity; mitigated by `baseExpr`, wire-key collision,
  arg-index pre-count, variant/depth/slot guards, the 8a/8b split.
- **S2a breaking names** — fixture audit + `BREAKING CHANGE:`.
- **`range`/`Natural`/`Positive` lose bounds at decode** (`baseTypeName` resolves to
  the underlying int) — a future slice should reject or bounds-check; tracked, not
  blocking.

## 7. Property-test extensions (`tests/test_cat2_properties.nim`)

Each with a stable `testId`: S1 arbitrary-length arg lists; S2 case-engine
idempotency + round-trip over generated mixed-case names; S5 any-defaulted-field-
decodes-when-absent; S6 decode-via-alias ≡ canonical **and** a >8-field aliased
type; S7 `kdlSkipEncode` → field returns to zero after round-trip; S8 flatten ≡
equivalent nested shape.

## 8. S0.5 `kdlScalar` hook contract (RESOLVED → corrected KdlValue interchange)

**Correction (settled with the user, round 2):** round 1 chose the `KdlValue`-based
hook *because the span advantage was mis-stated.* Round 2 (two lenses) found that
claim **false** —
`value.nim` keeps `span` on a sidecar, not on `KdlValue`. The span advantage I
cited does not exist. What KdlValue-based *does* buy over the shipped string-based
hook is **typed scalar input**: a `kdlScalar` field whose KDL value is a number or
bool (not just a string) — the shipped string-only hook rejects those.

**Corrected design (recommended), pending your confirm:**

```nim
proc kdlDecodeValue*[T](val: KdlValue): Result[T, string]   # typed input
proc kdlEncodeValue*[T](v: T): KdlValue                     # value out, not emitter
```

- The macro builds a `KdlValue` from the token via an exposed
  **`tokenToKdlValue`** (extracted/renamed from `node_build`'s private
  `buildValueFromTok`), per a specified token→kind table (number→`kvInt`/`kvFloat`,
  keyword→`kvBool`/`kvNull`/`kvFloat`, string/ident→`kvString`).
- The macro **owns the span** (it has `tok.span` at the call site) and lifts the
  hook's `string` error into a `ParseError` with that span — so errors *are*
  span-accurate, just not via the hook.
- Encode **returns a `KdlValue`** (not handed the live `BufferEmitter` — round-2
  depth: that's a framing-corruption footgun); the macro pushes it via the existing
  value-typed pushes.

This is minimal vs. what shipped (`string`→`KdlValue` interchange), typed,
span-accurate, and symmetric. The conclusion (KdlValue-based) is unchanged from
round 1 — only the rationale is corrected.

**Decision:** corrected KdlValue design (above). Typed-scalar support is the real,
lasting win; span accuracy is preserved via the macro. S0.5 reworks the shipped
string-based hook (`d385019`) to this contract.
