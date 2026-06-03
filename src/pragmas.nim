## pragmas — marker templates for the Cat 2 typed-derive surface.
##
## Hosted here (not in codegen.nim) so they survive the legacy-visitor
## cull. Stage C/D will emit `kdlEncode[T]` / `kdlDecode[T]` procs that
## consume these pragmas at compile time via `getCustomPragmaVal`.

template kdlNode*(name: string) {.pragma.}
  ## Type-level: explicit KDL node name. Defaults to type-name lowercased.

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
