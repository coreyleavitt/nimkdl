## Tests for `deriveEncode[T]` — typed-value-to-KDL serialization.
##
## Symmetric counterpart to `deriveDecode[T]`. Same pragma surface
## (kdlArg / kdlProp / kdlChild / kdlSkip / kdlRename / kdlReserved /
## kdlNode); the macro generates a `kdlEncodeImpl(v: T, doc: var KdlDoc):
## KdlNode` proc, and `encode[T](v: T)` wraps that in a fresh document
## and renders to KDL text.

import std/[strutils, unittest]

import ../src/ast
import ../src/codegen
import ../src/encode
import ../src/parser
import ../src/spans

type
  Simple {.kdlNode: "simple".} = object
    name {.kdlProp.}: string
    count {.kdlProp.}: int

  WithArg {.kdlNode: "item".} = object
    id {.kdlArg.}: string
    enabled {.kdlProp.}: bool

  Tagged {.kdlNode: "config".} = object
    bindAddr {.kdlProp, kdlReserved: "ipv4".}: string

  Color = enum
    cRed = "red"
    cBlue = "blue"

  WithEnum {.kdlNode: "fav".} = object
    color {.kdlProp.}: Color

  Inner {.kdlNode: "inner".} = object
    label {.kdlProp.}: string

  Outer {.kdlNode: "outer".} = object
    name {.kdlProp.}: string
    inner {.kdlChild.}: Inner

deriveEncode(Simple)
deriveEncode(WithArg)
deriveEncode(Tagged)
deriveEncode(WithEnum)
deriveEncode(Inner)
deriveEncode(Outer)

# For round-trip testing, also derive the decoders.
deriveDecode(Simple)
deriveDecode(WithArg)
deriveDecode(Tagged)
deriveDecode(WithEnum)
deriveDecode(Inner)
deriveDecode(Outer)

suite "deriveEncode — primitives":
  test "encodes attributes":
    let s = Simple(name: "foo", count: 42)
    let r = encode(s)
    check r.isOk
    if r.isOk:
      check "name=foo" in r.get
      check "count=42" in r.get
      check r.get.startsWith("simple ")

  test "encodes positional argument":
    let w = WithArg(id: "abc", enabled: true)
    let r = encode(w)
    check r.isOk
    if r.isOk:
      check "item " in r.get
      check "abc" in r.get
      check "enabled=#true" in r.get

suite "deriveEncode — round-trip":
  test "Simple round-trips through encode+decode":
    let s = Simple(name: "foo", count: 7)
    let r = encode(s)
    check r.isOk
    if r.isOk:
      let back = decode[Simple](r.get)
      check back.isOk
      if back.isOk:
        check back.get.name == "foo"
        check back.get.count == 7

  test "WithArg round-trips":
    let w = WithArg(id: "x", enabled: true)
    let r = encode(w)
    check r.isOk
    if r.isOk:
      let back = decode[WithArg](r.get)
      check back.isOk
      if back.isOk:
        check back.get.id == "x"
        check back.get.enabled == true

suite "deriveEncode — reserved tag":
  test "kdlReserved field carries the declared tag in the output":
    let t = Tagged(bindAddr: "192.0.2.1")
    let r = encode(t)
    check r.isOk
    if r.isOk:
      check "(ipv4)" in r.get
      # Round-trip through the typed decoder validates the tag too.
      let back = decode[Tagged](r.get)
      check back.isOk
      if back.isOk:
        check back.get.bindAddr == "192.0.2.1"

  test "kdlReserved field with invalid content errors at encode":
    # Symmetric Layer 1: if the value's content doesn't match the tag,
    # encode should fail rather than silently emit malformed KDL.
    let t = Tagged(bindAddr: "banana")
    let r = encode(t)
    check r.isErr
    if r.isErr:
      check r.getErr.code == peReservedTypeInvalid
      check "ipv4" in r.getErr.hint

suite "deriveEncode — enums":
  test "enum field encoded as string-valued attribute":
    let w = WithEnum(color: cBlue)
    let r = encode(w)
    check r.isOk
    if r.isOk:
      check "color=blue" in r.get
      let back = decode[WithEnum](r.get)
      check back.isOk
      if back.isOk:
        check back.get.color == cBlue

suite "deriveEncode — children":
  test "kdlChild field encodes as a nested node":
    let o = Outer(name: "top", inner: Inner(label: "bottom"))
    let r = encode(o)
    check r.isOk
    if r.isOk:
      check "outer " in r.get
      check "inner " in r.get
      check "label=bottom" in r.get
      let back = decode[Outer](r.get)
      check back.isOk
      if back.isOk:
        check back.get.name == "top"
        check back.get.inner.label == "bottom"

# ---------------------------------------------------------------------------
# M2: encode mode + encodeNode primitive
# ---------------------------------------------------------------------------

suite "encodeNode[T] — typed value to KdlNode primitive":
  test "encodeNode produces a node with the right name and entries":
    let v = Simple(name: "x", count: 3)
    var doc = newDoc()
    let r = encodeNode(v, doc)
    check r.isOk
    if r.isOk:
      let n = r.get
      check doc.resolveName(n) == "simple"
      check n.hasProp(doc, "name")
      check n.prop(doc, "name").get.strVal == "x"
      check n.prop(doc, "count").get.intVal == 3

suite "encode[T] — mode parameter":
  test "default mode is emPretty (multi-line children block)":
    let o = Outer(name: "top", inner: Inner(label: "bottom"))
    let r = encode(o)  # no explicit mode
    check r.isOk
    if r.isOk:
      # Pretty mode wraps the child block over multiple lines.
      check r.get.contains("{\n")
      check r.get.contains("\n}")

  test "emCompact produces single-line output":
    let o = Outer(name: "top", inner: Inner(label: "bottom"))
    let r = encode(o, mode = emCompact)
    check r.isOk
    if r.isOk:
      # Compact mode: no newlines, single `{ ... }` inline.
      check "\n" notin r.get
      check "outer" in r.get
      check "inner" in r.get

  test "encode[seq[T]] emits one top-level node per element":
    let vs = @[
      Simple(name: "a", count: 1),
      Simple(name: "b", count: 2),
      Simple(name: "c", count: 3),
    ]
    let r = encode(vs)
    check r.isOk
    if r.isOk:
      # Three nodes, each named "simple".
      let occurrences = r.get.count("simple ")
      check occurrences == 3
      # Round-trip: parse back to seq[Simple].
      let back = decode[seq[Simple]](r.get)
      check back.isOk
      if back.isOk:
        check back.get.len == 3
        check back.get[1].count == 2

  test "kdlReserved validation fires regardless of mode":
    # Tagged.bindAddr has {.kdlReserved: "ipv4".} — a non-IPv4 value
    # must surface as an Err whether we asked for emPretty, emCompact,
    # or the default. Mode is orthogonal to validity.
    let bad = Tagged(bindAddr: "not-an-ip")
    check encode(bad).isErr
    check encode(bad, mode = emCompact).isErr
    check encode(bad, mode = emPretty).isErr
    # And a valid one succeeds across all modes.
    let good = Tagged(bindAddr: "127.0.0.1")
    check encode(good).isOk
    check encode(good, mode = emCompact).isOk

suite "encode[T] — error diagnostics":
  test "kdlReserved failure hint includes Type.field path":
    # Tagged.bindAddr is kdlReserved=ipv4; a non-IPv4 value should
    # produce an error whose hint identifies the field. Span info is
    # synthetic on the encode side (we have no source file).
    let bad = Tagged(bindAddr: "not-an-ip")
    let r = encode(bad)
    check r.isErr
    if r.isErr:
      let h = r.getErr.hint
      check "Tagged" in h
      check "bindAddr" in h
