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
import ../src/lexer
import ../src/pragmas

template roundtrip[T](v0: T): T =
  ## Encode v0 → bytes → cursor → decode into v1; return v1.
  var e = newBufferEmitter()
  kdlEncode(v0, e)
  let bytes = e.finish()
  var sref: ref TokenStream
  new(sref)
  sref[] = lex(bytes)
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

  test "Pt — full-mantissa floats round-trip (regression: $float must be round-trip-safe)":
    # Legacy Nim `$float` emits 16 significant digits, but ~45% of full-
    # mantissa doubles need 17 and silently re-parse to a NEIGHBORING
    # double — a latent encode-decode identity violation invisible to
    # short-decimal example/conformance tests. Guards the shortest-
    # round-trippable formatter (numlit.formatFloat via addFloatRoundtrip).
    const counterexample = cast[float64](0x2CA92B3ED4AFDA78'u64)
    check roundtrip(Pt(x: counterexample, y: 0.0)).x == counterexample
    var seed = 0x9E3779B97F4A7C15'u64
    for i in 0 ..< 256:
      seed = seed * 6364136223846793005'u64 + 1442695040888963407'u64
      let f = cast[float64](seed)
      if f != f or f == Inf or f == NegInf: continue   # skip nan/inf
      let v1 = roundtrip(Pt(x: f, y: f))
      check v1.x == f
      check v1.y == f

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

  type Renamed {.kdlNode: "renamed".} = object
    tmpl {.kdlProp, kdlRename: "template".}: string

  deriveEncode(Renamed)
  deriveDecode(Renamed)

  test "kdlRename round-trips correctly":
    let v0 = Renamed(tmpl: "default")
    let v1 = roundtrip(v0)
    check v1.tmpl == v0.tmpl

  type Reserved {.kdlNode: "reserved".} = object
    addr1 {.kdlArg, kdlReserved: "ipv4".}: string
    port {.kdlProp, kdlReserved: "u16".}: int

  deriveEncode(Reserved)
  deriveDecode(Reserved)

  test "kdlReserved tags round-trip identically":
    let v0 = Reserved(addr1: "10.0.0.1", port: 443)
    let v1 = roundtrip(v0)
    check v1.addr1 == v0.addr1
    check v1.port == v0.port
