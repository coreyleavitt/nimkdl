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

  proc kdlEncodeValue(c: RGB): KdlValue =
    newKdlString("#" & toHex(c.r.int, 2) & toHex(c.g.int, 2) & toHex(c.b.int, 2))

  proc kdlDecodeValue(val: KdlValue, T: typedesc[RGB]): Result[RGB, string] =
    if val.kind != kvString:
      return err[RGB, string]("expected #rrggbb string")
    let s = val.strVal
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

  proc kdlEncodeValue(h: Hue): KdlValue = newKdlString($h.deg & "deg")
  proc kdlDecodeValue(val: KdlValue, T: typedesc[Hue]): Result[Hue, string] =
    if val.kind != kvString:
      return err[Hue, string]("expected <n>deg string")
    let s = val.strVal
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

suite "kdl: block — directional derive pragmas (S3)":

  kdl:
    type Inbound {.kdlNode: "inbound", kdlDecodeOnly.} = object
      name {.kdlArg.}: string
      port {.kdlProp.}: int

  test "kdlDecodeOnly: decode works":
    let v = decodeOne[Inbound]("inbound \"web\" port=80")
    check v.name == "web"
    check v.port == 80

  test "kdlDecodeOnly: no kdlEncode is generated":
    # No deriveEncode emitted → no kdlEncode(Inbound) overload exists.
    let v = Inbound(name: "web", port: 80)
    check not compiles(encodeOne(v))

  kdl:
    type Outbound {.kdlNode: "outbound", kdlEncodeOnly.} = object
      name {.kdlArg.}: string
      port {.kdlProp.}: int

  test "kdlEncodeOnly: encode works":
    let v = Outbound(name: "web", port: 80)
    let bytes = encodeOne(v)
    check bytes == "outbound \"web\" port=80\n"

  test "kdlEncodeOnly: no kdlDecode is generated":
    # No deriveDecode emitted → no kdlDecode(Outbound) overload exists.
    check not compiles(decodeOne[Outbound]("outbound \"web\" port=80"))

suite "kdl: block — kdlAlias decode-only alternate keys (S6)":

  kdl:
    type Themed {.kdlNode: "themed".} = object
      color {.kdlProp, kdlAlias: "colour".}: string

  test "canonical key decodes; alias key decodes; encode uses canonical":
    # Both wire keys populate the same field on decode.
    let a = decodeOne[Themed]("themed color=\"red\"")
    check a.color == "red"
    let b = decodeOne[Themed]("themed colour=\"red\"")
    check b.color == "red"
    # Encode emits ONLY the canonical key (never the alias).
    let v = Themed(color: "green")
    let bytes = encodeOne(v)
    check bytes == "themed color=\"green\"\n"
    # Round-trips through the canonical key.
    let v2 = decodeOne[Themed](bytes)
    check v2.color == "green"

# ===========================================================================
# S8b — kdlFlatten ENCODE + cross-pragma interaction matrix
# ===========================================================================

suite "kdl: block — S8b: kdlFlatten encode (core)":

  kdl:
    type Meta {.kdlNode: "meta".} = object
      author {.kdlProp.}: string
      version {.kdlProp.}: int

    type Doc {.kdlNode: "doc".} = object
      title {.kdlArg.}: string
      meta {.kdlFlatten.}: Meta

  test "flattened sub-fields encode inline on the parent (no child node)":
    let v = Doc(title: "t", meta: Meta(author: "me", version: 2))
    let bytes = encodeOne(v)
    check bytes == "doc \"t\" author=\"me\" version=2\n"

  test "flatten encode round-trips through decode":
    let v0 = Doc(title: "t", meta: Meta(author: "me", version: 2))
    let v1 = decodeOne[Doc](encodeOne(v0))
    check v1.title == "t"
    check v1.meta.author == "me"
    check v1.meta.version == 2

  # Flattened positional args must stay contiguous with the parent's fixed
  # args, in declaration order, on BOTH sides.
  kdl:
    type Coords {.kdlNode: "coords".} = object
      x {.kdlArg.}: int
      y {.kdlArg.}: int

    type Placed {.kdlNode: "placed".} = object
      label {.kdlArg.}: string
      at {.kdlFlatten.}: Coords
      tail {.kdlArg.}: int

  test "flattened args encode contiguously and round-trip by index":
    let v0 = Placed(label: "p", at: Coords(x: 10, y: 20), tail: 99)
    let bytes = encodeOne(v0)
    check bytes == "placed \"p\" 10 20 99\n"
    let v1 = decodeOne[Placed](bytes)
    check v1.label == "p"
    check v1.at.x == 10
    check v1.at.y == 20
    check v1.tail == 99

  # Nested flatten (flatten of a flattening object) on the encode side.
  kdl:
    type Deep {.kdlNode: "deep".} = object
      d {.kdlProp.}: string

    type Inner {.kdlNode: "inner".} = object
      i {.kdlProp.}: int
      deep {.kdlFlatten.}: Deep

    type Outer {.kdlNode: "outer".} = object
      name {.kdlArg.}: string
      inner {.kdlFlatten.}: Inner

  test "nested flatten encodes flush onto the root and round-trips":
    let v0 = Outer(name: "o", inner: Inner(i: 7, deep: Deep(d: "deepval")))
    let bytes = encodeOne(v0)
    check bytes == "outer \"o\" i=7 d=\"deepval\"\n"
    let v1 = decodeOne[Outer](bytes)
    check v1.name == "o"
    check v1.inner.i == 7
    check v1.inner.deep.d == "deepval"

suite "kdl: block — S8b matrix: kdlRenameAll × flatten":

  # The flattened type carries its OWN {.kdlRenameAll.}; its sub-field wire
  # keys use F's convention (kebab), NOT the parent's (verbatim). Both encode
  # and decode must agree on F's convention or the round-trip breaks (§3.5.3).
  kdl:
    type FMeta {.kdlNode: "fmeta", kdlRenameAll: kcKebabCase.} = object
      authorName {.kdlProp.}: string
      schemaVersion {.kdlProp.}: int

    type FDoc {.kdlNode: "fdoc".} = object
      title {.kdlArg.}: string
      meta {.kdlFlatten.}: FMeta

  test "flattened sub-fields use the flattened type's own convention":
    let v0 = FDoc(title: "t", meta: FMeta(authorName: "me", schemaVersion: 2))
    let bytes = encodeOne(v0)
    check bytes == "fdoc \"t\" author-name=\"me\" schema-version=2\n"
    let v1 = decodeOne[FDoc](bytes)
    check v1.title == "t"
    check v1.meta.authorName == "me"
    check v1.meta.schemaVersion == 2

suite "kdl: block — S8b matrix: kdlAlias × kdlRenameAll":

  # On a renameAll type, the canonical key is convention-transformed but the
  # alias stays the exact literal. Decode accepts both; encode emits canonical.
  kdl:
    type Aliased {.kdlNode: "aliased", kdlRenameAll: kcKebabCase.} = object
      colorValue {.kdlProp, kdlAlias: "colour".}: string

  test "canonical key is kebab-transformed; alias is verbatim":
    # decode via canonical (kebab) key
    let a = decodeOne[Aliased]("aliased color-value=\"red\"")
    check a.colorValue == "red"
    # decode via the exact-literal alias (NOT convention-transformed)
    let b = decodeOne[Aliased]("aliased colour=\"red\"")
    check b.colorValue == "red"
    # encode emits ONLY the canonical kebab key
    let v = Aliased(colorValue: "green")
    check encodeOne(v) == "aliased color-value=\"green\"\n"

suite "kdl: block — S8b matrix: kdlSkipDecode × flatten":

  # A flattened sub-field marked {.kdlSkipDecode.} is omitted from decode and
  # keeps its default; encode still emits it (skipDecode is decode-only).
  kdl:
    type SkMeta {.kdlNode: "skmeta".} = object
      author {.kdlProp.}: string
      cached {.kdlProp, kdlSkipDecode.}: int = 7

    type SkDoc {.kdlNode: "skdoc".} = object
      title {.kdlArg.}: string
      meta {.kdlFlatten.}: SkMeta

  test "skipDecode flattened sub-field is ignored on decode, keeps default":
    # wire carries cached=99 but it is consumed-and-ignored; field keeps 7.
    let v = decodeOne[SkDoc]("skdoc \"t\" author=\"me\" cached=99")
    check v.title == "t"
    check v.meta.author == "me"
    check v.meta.cached == 7

suite "kdl: block — S8b matrix: kdlVariadic + flatten on one parent":

  # A parent with BOTH a kdlVariadic field and a kdlFlatten field. DOCUMENTED
  # arg ordering: parent + flattened fields emit in DECLARATION order (args and
  # props inline as they appear), THEN the variadic tail is appended last. Here
  # the flattened object declares arg `a` then prop `label`, so the wire is
  # `1 label="x"` followed by the variadic tail `2 3 4`. Positionally this is
  # arg0 = a, args1..3 = variadic (props occupy no positional slot), so it
  # round-trips even though the prop sits textually between the args.
  kdl:
    type VFlat {.kdlNode: "vflat".} = object
      a {.kdlArg.}: int
      label {.kdlProp.}: string

    type VParent {.kdlNode: "vparent".} = object
      flat {.kdlFlatten.}: VFlat
      rest {.kdlVariadic.}: seq[int]

  test "variadic + flatten: flattened fields in decl order, variadic tail last":
    let v0 = VParent(flat: VFlat(a: 1, label: "x"), rest: @[2, 3, 4])
    let bytes = encodeOne(v0)
    check bytes == "vparent 1 label=\"x\" 2 3 4\n"
    let v1 = decodeOne[VParent](bytes)
    check v1.flat.a == 1
    check v1.flat.label == "x"
    check v1.rest == @[2, 3, 4]

suite "kdl: block — S8b matrix: kdlIgnoreUnknown × flatten":

  # Flattened keys live in the parent namespace; with the parent marked
  # {.kdlIgnoreUnknown.}, an unknown prop in that namespace is ignored even
  # alongside flattened sub-fields.
  kdl:
    type IMeta {.kdlNode: "imeta".} = object
      author {.kdlProp.}: string

    type IDoc {.kdlNode: "idoc", kdlIgnoreUnknown.} = object
      title {.kdlArg.}: string
      meta {.kdlFlatten.}: IMeta

  test "unknown prop in parent namespace is ignored with flatten present":
    let v = decodeOne[IDoc]("idoc \"t\" author=\"me\" mystery=\"x\"")
    check v.title == "t"
    check v.meta.author == "me"

suite "kdl: block — S8b matrix: Option[FlatObj] flatten (documented limitation)":

  # DOCUMENTED LIMITATION (rfc §4-S8a escape): {.kdlFlatten.} on an Option[F]
  # is rejected at macro time. The splice model writes sub-fields directly
  # through a compound pathExpr (`v.meta.author`); an Option has no
  # var-returning accessor, so in-place writes are impossible without a
  # temp-object reassembly mechanism disproportionate to this slice. Both
  # derive directions reject it with a clear message.

  type OMeta {.kdlNode: "ometa".} = object
    author {.kdlProp.}: string
    version {.kdlProp.}: int

  test "Option[FlatObj] flatten is a compile error (decode)":
    check not compiles((
      block:
        type OptDoc {.kdlNode: "optdoc".} = object
          title {.kdlArg.}: string
          meta {.kdlFlatten.}: Option[OMeta]
        deriveDecode(OptDoc)
    ))

  test "Option[FlatObj] flatten is a compile error (encode)":
    check not compiles((
      block:
        type OptDoc2 {.kdlNode: "optdoc".} = object
          title {.kdlArg.}: string
          meta {.kdlFlatten.}: Option[OMeta]
        deriveEncode(OptDoc2)
    ))

type InheritBase = object of RootObj
  id {.kdlProp.}: int
  tag {.kdlProp.}: string = "default"

suite "kdl: block — inherited fields + inherited defaults (S10)":

  kdl:
    type InheritDerived {.kdlNode: "derived".} = object of InheritBase
      name {.kdlArg.}: string

  test "derived decodes inherited fields + inherited S5 default":
    let v = decodeOne[InheritDerived]("derived \"n\" id=5")
    check v.name == "n"
    check v.id == 5
    check v.tag == "default"   # inherited default applied

  test "round-trips inherited + own fields":
    let v0 = InheritDerived(name: "n", id: 5, tag: "x")
    let v1 = decodeOne[InheritDerived](encodeOne(v0))
    check v1.name == "n"
    check v1.id == 5
    check v1.tag == "x"
