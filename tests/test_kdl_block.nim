## Stage E1 — `kdl:` block macro orchestration.
##
## The macro wraps a `type` section. For every type declared with
## `{.kdlNode.}`, it emits `deriveEncode(T)` + `deriveDecode(T)`
## immediately after the type section. Non-`{.kdlNode.}` types in
## the block are left alone.
##
## These tests validate the orchestrator end-to-end by exercising
## the emitted procs on both directions.

import std/unittest

import ../src/cursor
import ../src/derive_decode
import ../src/derive_encode
import ../src/emitter
import ../src/kdl_block
import ../src/lexer
import ../src/pragmas

template decodeOne[T](src: string): T =
  var sref: ref TokenStream
  new(sref)
  sref[] = lex(src)
  var c = initStringCursor(addr sref[], src)
  var v: T
  let r = kdlDecode(v, c)
  check r.isOk
  v

template encodeOne[T](v: T): string =
  var e = newBufferEmitter()
  kdlEncode(v, e)
  e.finish()

suite "kdl: block — E1 tracer":

  kdl:
    type Service {.kdlNode: "service".} = object
      name {.kdlArg.}: string
      port {.kdlProp.}: int

  test "decode goes through kdl-block-emitted deriveDecode":
    let v = decodeOne[Service]("service \"web\" port=80")
    check v.name == "web"
    check v.port == 80

  test "encode goes through kdl-block-emitted deriveEncode":
    let v = Service(name: "web", port: 80)
    let bytes = encodeOne(v)
    check bytes.len > 0
    let v2 = decodeOne[Service](bytes)
    check v2.name == v.name
    check v2.port == v.port

suite "kdl: block — E1 multi-type with kdlChild cross-reference":

  kdl:
    type Item {.kdlNode: "item".} = object
      label {.kdlArg.}: string

    type Catalog {.kdlNode: "catalog".} = object
      name {.kdlArg.}: string
      items {.kdlChild.}: seq[Item]

  test "parent decodes nested child types via cross-emitted procs":
    let src = "catalog \"a\" {\n  item \"x\"\n  item \"y\"\n}"
    let v = decodeOne[Catalog](src)
    check v.name == "a"
    check v.items.len == 2
    check v.items[0].label == "x"
    check v.items[1].label == "y"

  test "round-trip across cross-referenced types":
    let v0 = Catalog(name: "a", items: @[Item(label: "x"), Item(label: "y")])
    let bytes = encodeOne(v0)
    let v1 = decodeOne[Catalog](bytes)
    check v1.name == v0.name
    check v1.items.len == 2
    check v1.items[0].label == "x"

suite "kdl: block — E1 helper types without kdlNode pass through":

  # Helper enum has no {.kdlNode.}; must not get a derive emitted
  # (deriveEncode/deriveDecode on an enum has no meaningful semantics
  # — they require an object with kdlNode). Test asserts the block
  # compiles and the kdl-tagged type still works.
  kdl:
    type Color = enum
      cRed = "red"
      cGreen = "green"

    type Tag {.kdlNode: "tag".} = object
      name {.kdlArg.}: string
      color {.kdlProp.}: Color

  test "kdlNode-tagged type next to plain enum compiles + works":
    let v = decodeOne[Tag]("tag \"alpha\" color=\"red\"")
    check v.name == "alpha"
    check v.color == cRed
