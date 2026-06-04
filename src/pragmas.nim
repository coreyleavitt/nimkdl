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
  ## Field-level: do not parse — keep Nim's default.

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

template kdlRename*(name: string) {.pragma.}
  ## Field-level: KDL name differs from Nim field name.

template kdlReserved*(tag: string) {.pragma.}
  ## Field-level: assert the source KDL value carries this reserved-type
  ## annotation (e.g. `{.kdlReserved: "ipv4".}`). At decode time, a
  ## value lacking the declared tag — or carrying a different one —
  ## produces `peTypeReservedMismatch`. Layer-1 parse-time validation
  ## (see src/reserved.nim) still applies to the tag's content.
