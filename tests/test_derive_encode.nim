## Tests for `deriveEncode[T]` — typed-value-to-KDL serialization.
##
## Symmetric counterpart to `deriveDecode[T]`. Same pragma surface
## (kdlArg / kdlAttr / kdlChild / kdlSkip / kdlRename / kdlReserved /
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
    name {.kdlAttr.}: string
    count {.kdlAttr.}: int

  WithArg {.kdlNode: "item".} = object
    id {.kdlArg.}: string
    enabled {.kdlAttr.}: bool

  Tagged {.kdlNode: "config".} = object
    bindAddr {.kdlAttr, kdlReserved: "ipv4".}: string

  Color = enum
    cRed = "red"
    cBlue = "blue"

  WithEnum {.kdlNode: "fav".} = object
    color {.kdlAttr.}: Color

  Inner {.kdlNode: "inner".} = object
    label {.kdlAttr.}: string

  Outer {.kdlNode: "outer".} = object
    name {.kdlAttr.}: string
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
    let output = encode(s)
    check "name=foo" in output
    check "count=42" in output
    check output.startsWith("simple ")

  test "encodes positional argument":
    let w = WithArg(id: "abc", enabled: true)
    let output = encode(w)
    check "item " in output
    check "abc" in output
    check "enabled=#true" in output

suite "deriveEncode — round-trip":
  test "Simple round-trips through encode+decode":
    let s = Simple(name: "foo", count: 7)
    let output = encode(s)
    let back = decode[Simple](output)
    check back.isOk
    if back.isOk:
      check back.get.name == "foo"
      check back.get.count == 7

  test "WithArg round-trips":
    let w = WithArg(id: "x", enabled: true)
    let back = decode[WithArg](encode(w))
    check back.isOk
    if back.isOk:
      check back.get.id == "x"
      check back.get.enabled == true

suite "deriveEncode — reserved tag":
  test "kdlReserved field carries the declared tag in the output":
    let t = Tagged(bindAddr: "192.0.2.1")
    let output = encode(t)
    check "(ipv4)" in output
    # Round-trip through the typed decoder validates the tag too.
    let back = decode[Tagged](output)
    check back.isOk
    if back.isOk:
      check back.get.bindAddr == "192.0.2.1"

suite "deriveEncode — enums":
  test "enum field encoded as string-valued attribute":
    let w = WithEnum(color: cBlue)
    let output = encode(w)
    check "color=blue" in output
    let back = decode[WithEnum](output)
    check back.isOk
    if back.isOk:
      check back.get.color == cBlue

suite "deriveEncode — children":
  test "kdlChild field encodes as a nested node":
    let o = Outer(name: "top", inner: Inner(label: "bottom"))
    let output = encode(o)
    check "outer " in output
    check "inner " in output
    check "label=bottom" in output
    let back = decode[Outer](output)
    check back.isOk
    if back.isOk:
      check back.get.name == "top"
      check back.get.inner.label == "bottom"
