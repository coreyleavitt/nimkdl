## D15 — encode-decode identity property (round-trip).
##
## For each typed shape, the macro-emitted kdlEncode produces wire
## bytes that the macro-emitted kdlDecode reads back into a
## structurally-equal value. The strongest single validation that
## deriveEncode and deriveDecode are honest inverses on the
## architectural substrate.
##
## Test pattern per shape:
##   1. Build a value V0 of type T
##   2. Emit bytes via kdlEncode(V0, e); finish() → bytes
##   3. Lex+cursor those bytes
##   4. Decode via kdlDecode(V1, c); confirm V1 == V0 field-wise

import std/[options, unittest]

import ../src/cursor
import ../src/derive_decode
import ../src/derive_encode
import ../src/emitter
import ../src/intern
import ../src/lexer
import ../src/pragmas

template roundtrip[T](v0: T): T =
  ## Encode v0 → bytes → cursor → decode into v1; return v1.
  var e = newBufferEmitter()
  kdlEncode(v0, e)
  let bytes = e.finish()
  var interner = initInterner()
  var sref: ref TokenStream
  new(sref)
  sref[] = lex(bytes, interner)
  var c = initStringCursor(addr sref[], bytes)
  var v1: T
  let r = kdlDecode(v1, c)
  check r.isOk
  v1

suite "round-trip — D15: encode-decode identity":

  type Service {.kdlNode: "service".} = object
    name {.kdlArg.}: string
    port {.kdlProp.}: int

  deriveEncode(Service)
  deriveDecode(Service)

  test "Service round-trip":
    let v0 = Service(name: "web", port: 80)
    let v1 = roundtrip(v0)
    check v1.name == v0.name
    check v1.port == v0.port

  type Pt {.kdlNode: "pt".} = object
    x {.kdlArg.}: float
    y {.kdlArg.}: float

  deriveEncode(Pt)
  deriveDecode(Pt)

  test "Pt — float kdlArgs round-trip":
    let v0 = Pt(x: 1.5, y: 2.0)
    let v1 = roundtrip(v0)
    check v1.x == v0.x
    check v1.y == v0.y

  type Item {.kdlNode: "item".} = object
    label {.kdlArg.}: string

  deriveEncode(Item)
  deriveDecode(Item)

  type Catalog {.kdlNode: "catalog".} = object
    name {.kdlArg.}: string
    items {.kdlChild.}: seq[Item]

  deriveEncode(Catalog)
  deriveDecode(Catalog)

  test "Catalog with seq[Item] children round-trips":
    let v0 = Catalog(name: "n", items: @[
      Item(label: "a"), Item(label: "b"), Item(label: "c")])
    let v1 = roundtrip(v0)
    check v1.name == v0.name
    check v1.items.len == 3
    check v1.items[0].label == "a"
    check v1.items[1].label == "b"
    check v1.items[2].label == "c"

  type Tree {.kdlNode: "tree".} = object
    value {.kdlArg.}: string
    children {.kdlChild.}: seq[Tree]

  deriveEncode(Tree)
  deriveDecode(Tree)

  test "Tree — depth-3 self-recursive round-trips":
    let v0 = Tree(value: "root", children: @[
      Tree(value: "a", children: @[Tree(value: "leaf")]),
      Tree(value: "b"),
    ])
    let v1 = roundtrip(v0)
    check v1.value == "root"
    check v1.children.len == 2
    check v1.children[0].value == "a"
    check v1.children[0].children.len == 1
    check v1.children[0].children[0].value == "leaf"
    check v1.children[1].value == "b"
    check v1.children[1].children.len == 0

  type ActionKind = enum
    akInject = "inject"
    akAllow = "allow"

  type Action {.kdlNode: "action".} = object
    kind {.kdlArg.}: ActionKind
    name {.kdlProp.}: string

  deriveEncode(Action)
  deriveDecode(Action)

  test "Action with enum kdlArg round-trips":
    let v0 = Action(kind: akInject, name: "policy-1")
    let v1 = roundtrip(v0)
    check v1.kind == v0.kind
    check v1.name == v0.name

  type Note {.kdlNode: "note".} = object
    name {.kdlArg.}: string
    tag {.kdlProp.}: Option[string]

  deriveEncode(Note)
  deriveDecode(Note)

  test "Note with Option[T] present → Some after round-trip":
    let v0 = Note(name: "hello", tag: some("greeting"))
    let v1 = roundtrip(v0)
    check v1.name == v0.name
    check v1.tag == v0.tag

  test "Note with Option[T] None → None after round-trip":
    let v0 = Note(name: "hello", tag: none(string))
    let v1 = roundtrip(v0)
    check v1.name == v0.name
    check v1.tag == none(string)
