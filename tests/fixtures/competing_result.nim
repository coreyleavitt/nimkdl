## Faithful-enough stand-in for nim-results' colliding public surface (the
## shapes chronos re-exports): a generic `Result[T, E]` type plus the `ok`/`err`
## overloads whose signatures overlap what nkdl's generated decoders emit. A
## module importing BOTH this and `nkdl` reproduces the real-world ambiguity a
## consumer hits when it imports chronos alongside nkdl. Used by the
## derive-hygiene regression test — if the generated `kdlDecode` is hygienic,
## deriving + decoding here compiles despite the duplicate `Result`.
##
## Also stands in for a consumer that happens to define its own
## `BufferEmitter`, `ParseError`, and `StringCursor` — nkdl's own internal
## codegen type names. F3/F12: every bare `ident(...)` the derive macros emit
## in a TYPE position must instead be `bindSym`'d, or a consumer with any of
## these names in scope hits "ambiguous identifier" at their call site.
type Result*[T, E] = object
  isOkV: bool
  v: T
  e: E
template ok*[T: not void, E](R: type Result[T, E], x: untyped): R = default(R)
template ok*[E](R: type Result[void, E]): R = default(R)
template ok*(v: auto): auto = default(Result[typeof(v), string])
template ok*(): auto = default(Result[void, string])
template err*[T; E: not void](R: type Result[T, E], x: untyped): R = default(R)
template err*(v: auto): auto = default(Result[string, typeof(v)])

type
  BufferEmitter* = object
    junk*: int
  ParseError* = object
    junk*: int
  StringCursor* = object
    junk*: int
