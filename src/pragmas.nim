## pragmas — marker templates for the Cat 2 typed-derive surface.
##
## Hosted here (not in codegen.nim) so they survive the legacy-visitor
## cull. Stage C/D will emit `kdlEncode[T]` / `kdlDecode[T]` procs that
## consume these pragmas at compile time via `getCustomPragmaVal`.

template kdlNode*(name: string) {.pragma.}
  ## Type-level: explicit KDL node name. Defaults to type-name lowercased.

type KdlNamingConvention* = enum
  ## Naming convention applied by type-level `{.kdlRenameAll.}` to every
  ## field's canonical wire key. The `kc` prefix matches the codebase's
  ## 2-letter enum convention (`kv`, `tk`, `pe`, `ck`, …). A garbage
  ## convention is unrepresentable — no runtime failure mode.
  kcVerbatim,           ## field name unchanged (identity / documents intent)
  kcKebabCase,          ## maxRetries → max-retries
  kcCamelCase,          ## max_retries → maxRetries   (lower first letter)
  kcSnakeCase,          ## maxRetries → max_retries
  kcPascalCase,         ## max_retries → MaxRetries   (upper first letter)
  kcScreamingSnakeCase  ## maxRetries → MAX_RETRIES

template kdlRenameAll*(conv: KdlNamingConvention) {.pragma.}
  ## Type-level: apply a `KdlNamingConvention` to EVERY field's canonical
  ## wire key (the prop key on encode + the accepted key on decode),
  ## derived from the Nim field name. A field carrying its own
  ## `{.kdlRename: "x".}` is exempt — `kdlRename` sets the exact wire key
  ## and WINS over the convention (see `wireKeyOf`, rfc §3.5.3). The
  ## convention affects field/prop keys only; it does NOT rename the node
  ## itself (`{.kdlNode.}` / `nodeNameOf` are independent). Example:
  ##   type RetryCfg {.kdlNode: "retry", kdlRenameAll: kcKebabCase.} = object
  ##     maxRetries {.kdlProp.}: int      # wire key: max-retries

template kdlEncodeOnly*() {.pragma.}
  ## Type-level: generate ONLY the encode direction for this `{.kdlNode.}`
  ## type — the `kdl:` block emits `deriveEncode(T)` and SKIPS
  ## `deriveDecode(T)`, so no `kdlDecode` overload exists for `T`. Use it to
  ## declare intent: this type is produced (serialized) but never parsed from
  ## KDL. Suppresses the *decode* side; the name names the side that stays.
  ## Combining it with `{.kdlDecodeOnly.}` on the same type is contradictory
  ## and is a compile-time error.

template kdlDecodeOnly*() {.pragma.}
  ## Type-level: generate ONLY the decode direction for this `{.kdlNode.}`
  ## type — the `kdl:` block emits `deriveDecode(T)` and SKIPS
  ## `deriveEncode(T)`, so no `kdlEncode` overload exists for `T`. Use it to
  ## declare intent: this type is parsed from KDL but never serialized back.
  ## Suppresses the *encode* side; the name names the side that stays.
  ## **Footgun (intentional):** because no `kdlEncode(T)` is generated, using
  ## a `{.kdlDecodeOnly.}` type as a `{.kdlChild.}` of another derived type
  ## makes the PARENT's encode fail to compile (missing `kdlEncode` overload
  ## for the child). This is by design — it surfaces the asymmetry at the use
  ## site rather than silently emitting a half-working parent. Combining it
  ## with `{.kdlEncodeOnly.}` on the same type is contradictory and is a
  ## compile-time error.

template kdlIgnoreUnknown*() {.pragma.}
  ## Type-level: relax the default strict-unknown behavior on DECODE. Without
  ## it, an unknown property OR an unknown child node (one matching no
  ## `{.kdlProp.}` / `{.kdlChild.}` field) is a `peTypeUnknownField` error.
  ## With it, both are silently skipped: unknown props are consumed and
  ## ignored, unknown child nodes are `skip()`'d. Use it for forward-compatible
  ## decoding of documents that may carry fields this type does not model.
  ## Affects decode only; encode never emits unknown data. The `/-` slashdash
  ## path is unaffected (it suppresses decoding regardless).

template kdlArg*() {.pragma.}
  ## Field-level: serialize/parse as a positional argument.

template kdlVariadic*() {.pragma.}
  ## Field-level: collect ALL positional arguments beyond the fixed
  ## `{.kdlArg.}` fields into a `seq[T]`. The field type MUST be a
  ## `seq[T]` whose element type `T` is a scalar (string/int/float/bool/
  ## enum/`{.kdlScalar.}` — args are scalar, never child-shaped). At most
  ## ONE variadic field per type. Combine freely with fixed `{.kdlArg.}`
  ## fields: the fixed args bind by position first, then every remaining
  ## arg is decoded as `T` and appended to the seq. A variadic field is
  ## never required (an empty arg list yields an empty seq). On encode the
  ## fixed `{.kdlArg.}` fields are written first (in declaration order),
  ## then each variadic element — so the variadic field must be declared
  ## after every fixed `{.kdlArg.}` field for round-trips to align.
  ## Use `{.kdlVariadic.}`, not `{.kdlArg.}`, for a `seq[T]` of arguments.

template kdlProp*() {.pragma.}
  ## Field-level: serialize/parse as a property (key=value).

template kdlChild*() {.pragma.}
  ## Field-level: serialize/parse as a child node (default for objects + seq).

template kdlSkip*() {.pragma.}
  ## Field-level: exclude the field from BOTH directions. It is never read
  ## from KDL (keeps its Nim default / zero value on decode) and never
  ## written to KDL (emits nothing on encode). Equivalent to applying both
  ## `{.kdlSkipDecode.}` and `{.kdlSkipEncode.}`. A skipped field never
  ## claims a required slot, so its absence on the wire is not an error.

template kdlSkipDecode*() {.pragma.}
  ## Field-level: exclude the field from DECODE only (rfc S7). The decoder
  ## does not read the field from KDL — it keeps its Nim default / zero
  ## value (composing with a native `field = expr` default, S5), and never
  ## claims a required slot. Any wire value matching its name/position is
  ## ignored. ENCODE is unaffected — the field is still written out. On a
  ## `{.kdlArg.}` field this is allowed: the positional arg counter still
  ## advances over the slot, so subsequent args keep their indices, and the
  ## field simply retains its default. Combine with `{.kdlSkipEncode.}` for
  ## the both-directions behavior of `{.kdlSkip.}`.

template kdlSkipEncode*() {.pragma.}
  ## Field-level: exclude the field from ENCODE only (rfc S7). The encoder
  ## emits nothing for the field; DECODE is unaffected — a value present on
  ## the wire is still read into the field. **Compile-time error on a
  ## `{.kdlArg.}` field:** dropping a positional arg on encode shifts every
  ## subsequent arg index, so the round-trip silently decodes the wrong
  ## values into the wrong fields. Use `{.kdlSkip.}` (both directions) for a
  ## positional field you want fully excluded. Combine with
  ## `{.kdlSkipDecode.}` for the both-directions behavior of `{.kdlSkip.}`.

template kdlScalar*() {.pragma.}
  ## Field-level: encode/decode this field as a single KDL scalar via the
  ## user-provided hook pair, instead of the built-in primitive/child
  ## dispatch. The hooks exchange the typed `KdlValue` interchange form
  ## (rfc §8) — so a scalar whose KDL value is a number or bool decodes too,
  ## not just strings. The user defines, in scope before the type's `kdl:`
  ## block:
  ##   proc kdlEncodeValue(v: T): KdlValue
  ##   proc kdlDecodeValue(val: KdlValue; T: typedesc): Result[T, string]
  ## `kdlDecodeValue` pattern-matches on `val.kind`; `kdlEncodeValue` returns
  ## a `KdlValue` (e.g. `newKdlString(...)` / `newKdlInt(...)`). The macro
  ## owns the wire framing (it builds the `KdlValue` from the token and pushes
  ## the returned one) + lifts a decode error string into a `ParseError` with
  ## the value's span. Defaults to a property (key = field name); combine with
  ## `{.kdlArg.}` for positional.

template kdlFlatten*() {.pragma.}
  ## Field-level: SPLICE a nested object field's args/props/children into the
  ## PARENT node's namespace — no child node is emitted for the flattened
  ## field. The field's type MUST be an object (or `ref object`); its
  ## sub-fields are routed as if they were declared directly on the parent.
  ## A flattened arg sub-field occupies a contiguous positional slot computed
  ## against the parent's running arg count; a flattened prop/child sub-field
  ## uses its own wire key/name in the parent namespace. Example:
  ##   type Meta = object
  ##     author {.kdlProp.}: string
  ##     version {.kdlProp.}: int
  ##   type Doc {.kdlNode: "doc".} = object
  ##     title {.kdlArg.}: string
  ##     meta {.kdlFlatten.}: Meta        # author=…, version=… land on `doc`
  ## decodes `doc "t" author="me" version=2` into `v.title`, `v.meta.author`,
  ## `v.meta.version`. Flattening nests (a flattened object may itself flatten
  ## an inner object) up to a depth bound. **Constraints (compile-time
  ## errors):** the union of all parent + flattened WIRE keys (post-rename)
  ## must be globally unique; a flattened field whose type IS the parent type
  ## (self-flatten) is rejected; `{.kdlFlatten.}` on a `case`/variant-bearing
  ## type is rejected (discriminator ordering is out of scope); nesting deeper
  ## than 8 levels is rejected.

template kdlRename*(name: string) {.pragma.}
  ## Field-level: KDL name differs from Nim field name.

template kdlAlias*(names: varargs[string]) {.pragma.}
  ## Field-level: DECODE-ONLY alternate wire keys, accepted IN ADDITION to
  ## the field's canonical key. A single alias uses the colon form
  ## (`{.kdlProp, kdlAlias: "colour".}`); multiple aliases use the paren form
  ## (`{.kdlProp, kdlAlias("colour", "old").}`) — Nim's pragma colon syntax
  ## takes only one expression. Either makes the decoder populate the field
  ## from `colour=…` (or `old=…`) as well as the
  ## canonical key. ENCODE is unaffected — it always emits the canonical key
  ## (`kdlRename`/`kdlRenameAll`/field name). Aliases are EXACT literals: they
  ## are NEVER transformed by `{.kdlRenameAll.}` (rfc §3.5.3). The union of all
  ## fields' canonical keys and all alias keys must be globally unique within
  ## the type — a collision is a compile-time error. Use it for forward/backward
  ## compatibility when a wire key is renamed but old documents must still parse.

template kdlReserved*(tag: string) {.pragma.}
  ## Field-level: assert the source KDL value carries this reserved-type
  ## annotation (e.g. `{.kdlReserved: "ipv4".}`). At decode time, a
  ## value lacking the declared tag — or carrying a different one —
  ## produces `peTypeReservedMismatch`. Layer-1 parse-time validation
  ## (see src/reserved.nim) still applies to the tag's content.
