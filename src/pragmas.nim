## pragmas — marker templates for the Cat 2 typed-derive surface.
##
## Hosted here (not in codegen.nim) so they survive the legacy-visitor
## cull. Stage C/D will emit `kdlEncode[T]` / `kdlDecode[T]` procs that
## consume these pragmas at compile time via `getCustomPragmaVal`.

template kdlNode*(name: string) {.pragma.}
  ## Type-level: explicit KDL node name. Defaults to type-name lowercased.

template kdlArg*() {.pragma.}
  ## Field-level: serialize/parse as a positional argument.

template kdlProp*() {.pragma.}
  ## Field-level: serialize/parse as a property (key=value).

template kdlChild*() {.pragma.}
  ## Field-level: serialize/parse as a child node (default for objects + seq).

template kdlSkip*() {.pragma.}
  ## Field-level: do not parse — keep Nim's default.

template kdlRename*(name: string) {.pragma.}
  ## Field-level: KDL name differs from Nim field name.

template kdlReserved*(tag: string) {.pragma.}
  ## Field-level: assert the source KDL value carries this reserved-type
  ## annotation (e.g. `{.kdlReserved: "ipv4".}`). At decode time, a
  ## value lacking the declared tag — or carrying a different one —
  ## produces `peTypeReservedMismatch`. Layer-1 parse-time validation
  ## (see src/reserved.nim) still applies to the tag's content.
