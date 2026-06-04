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

let s = decode[Server]("server \"web\" port=443 { tag \"prod\" }").tryGet
let kdl = encode(s)
```

The `kdl:` block emits `kdlEncode`/`kdlDecode` for each `{.kdlNode.}` type. The
top-level entry points are `decode[T](src): Result[T, ParseError]`,
`encode[T](v): string`, `decodeAll[T](src)` (for `seq[U]`), and `embed[T](src)`
(compile-time decode → a baked-in `const`). To decode an **individual DOM node**
(the heterogeneous-config case) use the typed↔DOM bridge below.

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

## Consumer API / typed↔DOM bridge

The whole-source entry points (`decode`/`decodeAll`/`encode`) cover the common
case. These additional entry points decode an **individual node, child, or
scalar value** — the heterogeneous-top-level-config case — and attribute errors
to real source positions. All are `{.raises: [].}`.

### Source attribution

```nim
proc decode*[T](src: string, sourcePath = "<input>"): Result[T, ParseError]
proc decodeAll*[T](src: string, sourcePath = "<input>"): Parsed[T]   ## T must be seq[U]
proc decodeFile*[T](path: string): Result[T, ParseError]
```

`sourcePath` is the attribution that renders in `$err` (e.g. `"config.kdl"`);
it does not read a file. `decodeFile[T]` does — it reads `path`, threads the
filename as `sourcePath`, and converts any I/O failure (missing/unreadable
path) into a `peIOError` `ParseError` rather than raising. `decodeAll` returns a
`Parsed[T]` (a partial `value` plus every `error` collected while recovering;
`isComplete` iff no errors).

### Node / child / value decode

```nim
proc decodeNode*[T](doc: KdlDoc, node: KdlNode): Result[T, ParseError]
proc decodeNode*[T](node: KdlNode): Result[T, ParseError]
proc decodeChild*[T](doc: KdlDoc, parent: KdlNode, childName: string): Result[T, ParseError]
proc decodeProp*[T](node: KdlNode, key: string): Result[T, ParseError]
proc decodeArg*[T](node: KdlNode, i: int): Result[T, ParseError]
proc coerce*[T](val: KdlValue): Result[T, ParseError]
```

- `decodeNode[T](doc, node)` — decode a single parsed node into `T`. It slices
  the node's **verbatim original bytes** out of `doc.sourceText` and feeds them
  to the one decoder, so every pragma above works unchanged and a type error
  carries the **true file line/col** (not a slice-local offset). The node's name
  is checked against `{.kdlNode.}`, so `decodeNode[Daemon](doc, n)` errors if
  `n.name != "daemon"`. Instantiating with a `seq[T]` is a compile error (decode
  the element type).
- `decodeNode[T](node)` — doc-less **overload** for nodes built programmatically
  (no source span). It re-emits the node to canonical KDL via `encode(node)` and
  decodes *that*, so `kdlScalar` hooks, annotation requoting, and Option/null
  materialization may differ from the source-slice path. **Use the `(doc, node)`
  form whenever a parsed doc is in hand**; reserve the bare form for hand-built
  nodes where no source exists.
- `decodeChild[T](doc, parent, childName)` — decode `parent`'s **first** child
  named `childName` (first-wins on duplicates) via `decodeNode`. A missing child
  is a `peTypeMissingRequired` error naming the child and parent.
  To return a default instead of an error, compose with `Result.valueOr`:
  `decodeNode[T](doc, n).valueOr(fallback)` — strictly more general than a
  dedicated combinator and composes over the whole `Result` surface.
- `decodeProp[T](node, key)` — decode a single **property** value into scalar
  `T`: the value leg's named twin. Carries error currency and reaches
  `{.kdlScalar.}` / enum types. A missing prop is a `peTypeMissingRequired`
  error naming the key and node.
- `decodeArg[T](node, i)` — decode the `i`-th **positional argument** into scalar
  `T` (properties interleaved among args are skipped). Same error currency and
  `{.kdlScalar.}` / enum reach as `decodeProp`; an out-of-range index errors.
- `propInt`/`propStr`/`argInt`/`argStr` (`src/node.nim`) — by contrast, are
  quick **optional peeks** that return `Option[…]` where *absent* and
  *wrong-kind* both collapse to `none` (no error, no `{.kdlScalar.}` reach).
- `coerce[T](val)` — coerce a single **scalar** `KdlValue` into `T`: the value
  leg of the bridge (`string`/`bool`/`int*`/`uint*`/`float*`/`enum`, or a custom
  type with a `kdlDecodeValue` hook in scope). Instantiating it with an aggregate
  `T` is a compile error directing you to `decodeNode`/`decode`.

### Self-sufficient errors

`ParseError` carries eager `line`/`col`/`sourcePath` filled at the decode
boundary, so it is a value that outlives the source string. `$err` renders a
full one-line location with **no source argument**:

```nim
echo $err     # config.kdl:14:5: value type mismatch (listen)
```

The format is `sourcePath:line:col: message (dotted.field.path)`. `formatError(err,
src, filename)` still renders the multi-line caret diagnostic when you have the
source in hand. `peIOError` distinguishes an I/O failure from a lex/parse/type
error.

### `embed` vs `embedFile`

```nim
proc embed*[T](src: static[string], sourcePath: static[string] = "<embed>"): T
template embedFile*[T](path: static[string]): T
```

`embed[T]` takes KDL **source content**; `embedFile[T]` takes a **path**,
`staticRead`s it (relative to the invoking file), and threads the real filename
as `sourcePath`. Two distinct names, no "is this a path?" heuristic. Both run the
full decode in the NimVM and bake a `const`; a parse/type error fails the build
at compile time with a caret diagnostic (`{.error.}`), never a runtime defect.

## Notes

- **Duplicate keys** decode last-wins (matching the Cat-3 DOM).
- **Compile-time decode:** `embed[T](src)` / `embedFile[T](path)` run the decoder
  in the NimVM — including `kdlUntagged` (branch rewind is VM-safe).
- **Not supported** (compile error directing you to `kdlScalar`): `seq[seq[T]]`,
  `Table[K,V]`, `tuple` fields, `range`/`Natural`/`Positive` bounds, `char`.
- **`kdlAlias` on a wide (>8-field) type** forces linear prop dispatch instead of
  the perfect-hash path (correctness over speed; see issue #41).
