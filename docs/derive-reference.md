# nkdl derive reference (Cat-2 typed codec)

The complete pragma + API surface for nkdl's typed derive layer — mapping Nim
types to/from KDL with zero hand-written (de)serialization. Import `nkdl` (or the
`pragmas` / `kdl_block` / `api` modules) and annotate a type, then `decode[T]` /
`encode[T]`.

```nim
import nkdl

kdl:
  type Server {.kdlNode: "server".} = object
    host {.kdlArg.}: string
    port {.kdlProp.}: int = 8080
    tags {.kdlChild.}: seq[Tag]

let s = decode[Server]("server \"web\" port=443 { tag \"prod\" }").get
let kdl = encode(s)
```

The `kdl:` block emits `kdlEncode`/`kdlDecode` for each `{.kdlNode.}` type. The
public entry points are `decode[T](src): Result[T, ParseError]`,
`encode[T](v): string`, `decodeAll[T](src)` (for `seq[U]`), and `embed[T](staticSrc)`
(compile-time decode → a baked-in `const`).

## Type-level pragmas

| Pragma | Effect |
|---|---|
| `{.kdlNode: "name".}` | The KDL node name for this type. Default (no pragma): the type name in **kebab-case**, acronym-aware (`HTTPServer` → `http-server`). |
| `{.kdlRenameAll: kc….}` | Apply a naming convention to every field's wire key (see `KdlNamingConvention`). `kdlRename` on a field overrides it; does **not** affect the node name. |
| `{.kdlIgnoreUnknown.}` | Unknown props **and** child nodes are skipped instead of erroring. Default is strict (unknown → `peTypeUnknownField`). |
| `{.kdlEncodeOnly.}` | Generate only `kdlEncode` (no decoder). Calling `decode[T]` is a compile error. |
| `{.kdlDecodeOnly.}` | Generate only `kdlDecode` (no encoder). A decode-only type used as a `{.kdlChild.}` makes the parent's encode fail to compile — intentional. |
| `{.kdlUntagged.}` | For a `case` object with no discriminator on the wire: decode by trying each branch in declaration order (first full decode wins); encode emits the active branch. Gated: ≤20 total branch fields, no seq-child / nested-variant branch. |

`kdlEncodeOnly` + `kdlDecodeOnly` on one type is a compile error.

### `KdlNamingConvention`

`{.kdlRenameAll: <value>.}` — applied to `maxRetries`:

| Value | Result |
|---|---|
| `kcVerbatim` | `maxRetries` (identity; documents intent) |
| `kcKebabCase` | `max-retries` |
| `kcCamelCase` | `maxRetries` (lower first letter) |
| `kcSnakeCase` | `max_retries` |
| `kcPascalCase` | `MaxRetries` (upper first letter) |
| `kcScreamingSnakeCase` | `MAX_RETRIES` |

## Field-level pragmas

| Pragma | Slot | Effect |
|---|---|---|
| `{.kdlArg.}` | positional | A positional argument, in declaration order. |
| `{.kdlVariadic.}` | positional | On a `seq[T]`: collects all positional args beyond the fixed `kdlArg` fields. One per type; emitted after fixed args. |
| `{.kdlProp.}` | property | A `key=value` property. Wire key = field name (or `kdlRename`/`kdlRenameAll`). |
| `{.kdlChild.}` | child node | A nested node. `seq[T]` → repeated children; `Option[T]` → optional child; `T` (object) → one child. |
| `{.kdlScalar.}` | arg/prop | Encode/decode via a user hook pair (see below) — for custom scalar types. Default slot = prop; combine with `kdlArg`. |
| `{.kdlFlatten.}` | inline | On a nested object field: splices that object's args/props/children into the **parent** node (no child node). Wire-key collisions are a compile error; not allowed on variant/`Option`/seq fields. |
| `{.kdlRename: "wire".}` | — | Exact wire key for this field (beats `kdlRenameAll`). |
| `{.kdlAlias("old", "alt").}` | — | Extra **decode-only** wire keys (exact literals, never convention-transformed). Encode uses the canonical key. |
| `{.kdlReserved: "tag".}` | — | Assert/emit the KDL reserved-type annotation `(tag)` on the value. |
| `{.kdlSkip.}` | — | Field ignored in both directions (keeps Nim default on decode; absent on encode). |
| `{.kdlSkipDecode.}` | — | Not read from KDL (keeps Nim default). |
| `{.kdlSkipEncode.}` | — | Not written to KDL. (On a `kdlArg` field this is a compile error — it would shift arg indices.) |

Inference (no slot pragma): a primitive/enum field → prop; an object field → child;
`seq[object]` → child-seq; `Option[X]` inherits `X`'s routing. `seq[primitive]`
with no pragma is a compile error (annotate `kdlArg`/`kdlVariadic`/`kdlChild`).

## Native field defaults

A Nim default initializer is honored on decode: when the field is absent from the
wire it gets its default instead of a missing-required error.

```nim
type C {.kdlNode: "c".} = object
  retries {.kdlProp.}: int = 3      # absent → 3
  host {.kdlProp.}: string          # absent → "missing required field 'host'"
```

A genuinely required field that's missing errors with `peTypeMissingRequired`
naming the field by its wire key.

## Inheritance

`type Derived = object of Base` enumerates `Base`'s fields (and their defaults)
ahead of its own, on both decode and encode.

## Custom scalars — the `kdlScalar` hook

Define, in scope before the type's `kdl:` block:

```nim
proc kdlEncodeValue(v: MyType): KdlValue
proc kdlDecodeValue(val: KdlValue; T: typedesc[MyType]): Result[MyType, string]
```

`kdlDecodeValue` pattern-matches on `val.kind` (string/int/float/bool/null) and
returns the value or an error message; the macro builds the `KdlValue` from the
token and lifts the error string into a span-accurate `ParseError`.
`kdlEncodeValue` returns a `KdlValue`; the macro frames it. The hook never touches
the cursor or the emitter directly.

## Notes

- **Duplicate keys** decode last-wins (matching the Cat-3 DOM).
- **Compile-time decode:** `embed[T](staticSrc)` runs the decoder in the NimVM —
  including `kdlUntagged` (branch rewind is VM-safe).
- **Not supported** (compile error directing you to `kdlScalar`): `seq[seq[T]]`,
  `Table[K,V]`, `tuple` fields, `range`/`Natural`/`Positive` bounds, `char`.
- **`kdlAlias` on a wide (>8-field) type** forces linear prop dispatch instead of
  the perfect-hash path (correctness over speed; see issue #41).
