## Faithful-enough stand-in for nim-results' colliding public surface (the
## shapes chronos re-exports): a generic `Result[T, E]` type plus the `ok`/`err`
## overloads whose signatures overlap what nkdl's generated decoders emit. A
## module importing BOTH this and `nkdl` reproduces the real-world ambiguity a
## consumer hits when it imports chronos alongside nkdl. Used by the
## derive-hygiene regression test — if the generated `kdlDecode` is hygienic,
## deriving + decoding here compiles despite the duplicate `Result`.
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
