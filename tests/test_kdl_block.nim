## Stage E1 — `kdl:` block macro orchestration.
##
## The macro wraps a `type` section. For every type declared with
## `{.kdlNode.}`, it emits `deriveEncode(T)` + `deriveDecode(T)`
## immediately after the type section. Non-`{.kdlNode.}` types in
## the block are left alone.
##
## These tests validate the orchestrator end-to-end by exercising
## the emitted procs on both directions.

import std/[unittest, options, strutils]

import ../src/cursor
import ../src/derive_decode
import ../src/derive_encode
import ../src/emitter
import ../src/kdl_block
import ../src/lexer
import ../src/pragmas
import ../src/spans   # Result / ok / err for kdlScalar hooks

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

suite "kdl: block — ckRef end-to-end round-trip (#9/#39)":

  kdl:
    type RefHost {.kdlNode: "host".} = ref object
      name {.kdlArg.}: string
      port {.kdlProp.}: int

  test "kdl block emits both derives for a ref type; round-trips":
    let v = RefHost(name: "web", port: 80)
    let bytes = encodeOne(v)
    check bytes == "host \"web\" port=80\n"
    let v2 = decodeOne[RefHost](bytes)
    check v2 != nil
    check v2.name == "web"
    check v2.port == 80

suite "kdl: block — ckOption end-to-end round-trip (#39 item 1)":

  kdl:
    type OptKid {.kdlNode: "kid".} = object
      tag {.kdlArg.}: string
    type OptHost {.kdlNode: "host".} = object
      kid {.kdlChild.}: Option[OptKid]

  test "present optional child round-trips":
    let v = OptHost(kid: some(OptKid(tag: "a")))
    let bytes = encodeOne(v)
    let v2 = decodeOne[OptHost](bytes)
    check v2.kid.isSome
    check v2.kid.get.tag == "a"

  test "absent optional child round-trips as None":
    let v = OptHost(kid: none(OptKid))
    let bytes = encodeOne(v)
    let v2 = decodeOne[OptHost](bytes)
    check v2.kid.isNone

suite "kdl: block — kdlScalar custom hook round-trip (#39 item3)":

  type RGB = object
    r, g, b: uint8

  proc kdlEncodeValue(c: RGB): string =
    "#" & toHex(c.r.int, 2) & toHex(c.g.int, 2) & toHex(c.b.int, 2)

  proc kdlDecodeValue(s: string, T: typedesc[RGB]): Result[RGB, string] =
    if s.len == 7 and s[0] == '#':
      try:
        ok[RGB, string](RGB(r: uint8(parseHexInt(s[1..2])),
                            g: uint8(parseHexInt(s[3..4])),
                            b: uint8(parseHexInt(s[5..6]))))
      except CatchableError:
        err[RGB, string]("invalid hex")
    else:
      err[RGB, string]("expected #rrggbb")

  kdl:
    type Swatch {.kdlNode: "swatch".} = object
      fill {.kdlScalar.}: RGB

  test "kdlScalar prop round-trips through user hooks":
    let v = Swatch(fill: RGB(r: 255, g: 128, b: 0))
    let bytes = encodeOne(v)
    let v2 = decodeOne[Swatch](bytes)
    check v2.fill == RGB(r: 255, g: 128, b: 0)

suite "kdl: block — kdlScalar + kdlArg positional override (#39 item3)":

  type Hue = object
    deg: uint16

  proc kdlEncodeValue(h: Hue): string = $h.deg & "deg"
  proc kdlDecodeValue(s: string, T: typedesc[Hue]): Result[Hue, string] =
    if s.endsWith("deg"):
      try: ok[Hue, string](Hue(deg: uint16(parseInt(s[0 ..< s.len-3]))))
      except CatchableError: err[Hue, string]("bad hue")
    else: err[Hue, string]("expected <n>deg")

  kdl:
    type Dial {.kdlNode: "dial".} = object
      angle {.kdlScalar, kdlArg.}: Hue

  test "kdlScalar as positional arg round-trips":
    let v = Dial(angle: Hue(deg: 270))
    let bytes = encodeOne(v)
    check bytes == "dial \"270deg\"\n"
    let v2 = decodeOne[Dial](bytes)
    check v2.angle.deg == 270
