## test_derive_hygiene.nim — the generated `kdlDecode` must compile in a module
## that ALSO imports another library exporting its own `Result`/`ok`/`err`
## (the real-world case: a consumer importing chronos — which re-exports
## nim-results — alongside nkdl). A bare `ident("Result")` in the codegen would
## resolve in the CONSUMER's scope and be ambiguous; the derive binds its own
## types with `bindSym` so it stays hygienic regardless of the importer.
##
## `competing_result` is a faithful stand-in for nim-results' colliding public
## surface (Result type + the `ok`/`err` overload shapes), and ALSO defines its
## own `BufferEmitter`/`ParseError`/`StringCursor` — nkdl's own internal codegen
## type names (F3/F12). This suite failing to COMPILE is the regression — the
## runtime asserts are a bonus.

import std/unittest
import ../src/nkdl
import fixtures/competing_result   # brings competing Result/ok/err + BufferEmitter/ParseError/StringCursor into scope

type
  Sidecar {.kdlNode: "hook".} = object
    interactive {.kdlProp.}: bool = false

  Kind = enum kA = "a", kB = "b"
  Variant {.kdlNode: "node".} = object
    label {.kdlProp.}: string        # top-level prop (exercises the branch-prop path too)
    case kind {.kdlArg.}: Kind
    of kA: discard
    of kB:
      weight {.kdlProp.}: int = 7

deriveDecode(Sidecar)
deriveDecode(Variant)
deriveEncode(Sidecar)
deriveEncode(Variant)

suite "derive_decode — codegen hygiene against a competing Result":

  test "a derived type decodes even when the module imports another Result":
    # If deriveDecode emitted a bare `Result`, this file would not compile.
    let r = nkdl.decode[Sidecar]("""hook interactive=#true""", "h.kdl")
    check r.isOk
    check r.get.interactive

  test "the competing library's Result is still usable in the same module":
    # Prove the two coexist: qualify to pick the stand-in explicitly.
    let x = competing_result.ok(42)
    discard x

  test "variant with a top-level prop decodes under the competing import":
    let r = nkdl.decode[Variant]("""node "b" label="x" weight=9""", "n.kdl")
    check r.isOk
    check r.get.label == "x"
    check r.get.kind == kB
    check r.get.weight == 9

  test "the derived kdlEncode compiles and runs under a competing BufferEmitter":
    # If deriveEncode emitted a bare `BufferEmitter`, this file would not compile.
    var e = newBufferEmitter()
    kdlEncode(Sidecar(interactive: true), e)
    check e.finish().len > 0
