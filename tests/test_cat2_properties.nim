## Stage F6 / F7 — Cat 2 (typed-derive) property tests.
##
## - **P7: typed-T encode-decode identity.** For arbitrary T,
##   `decode[T](encode[T](v)) == v`. Promotes D15's fixed examples
##   to a forAll over generated T values.
##
## - **P8: encode determinism.** Same T encodes to byte-identical
##   output every time. Promotes C10's fixed examples to forAll.
##
## Gated by NKDL_PROPTEST=1.

import std/[options, unittest]

import proptest

import ../src/api
import ../src/kdl_block
import ../src/pragmas

kdl:
  type Service {.kdlNode: "service".} = object
    name {.kdlArg.}: string
    port {.kdlProp.}: int

  type Pt {.kdlNode: "pt".} = object
    x {.kdlArg.}: float
    y {.kdlArg.}: float

  type Note {.kdlNode: "note".} = object
    body {.kdlArg.}: string
    pin {.kdlProp.}: Option[int]

  type Item {.kdlNode: "item".} = object
    label {.kdlArg.}: string

  type Catalog {.kdlNode: "catalog".} = object
    name {.kdlArg.}: string
    items {.kdlChild.}: seq[Item]

suite "P7 — typed-T encode-decode identity (forAll)":

  property "Service round-trips for any (name, port)":
    with Settings(maxExamples: 300, testId: "p7-service")
    given name in strings(1, 32), port in integers(0, 65535)
    let v0 = Service(name: name, port: port)
    let r = decode[Service](encode(v0).get)
    ensure r.isOk
    ensure r.get.name == v0.name
    ensure r.get.port == v0.port

  property "Pt with float kdlArgs round-trips":
    # Finite floats only; the encode-decode pair has to handle the
    # full float decode-precision contract — NaN/Inf round-trip
    # through KDL's #inf / #nan keywords is exercised separately by
    # P12 (emitter never produces unparseable bytes).
    with Settings(maxExamples: 200, testId: "p7-pt")
    given x in floats(-1e9, 1e9, allowNan = false),
          y in floats(-1e9, 1e9, allowNan = false)
    let v0 = Pt(x: x, y: y)
    let r = decode[Pt](encode(v0).get)
    ensure r.isOk
    ensure r.get.x == v0.x
    ensure r.get.y == v0.y

  property "Note with Option[int] kdlProp round-trips both Some and None":
    with Settings(maxExamples: 200, testId: "p7-note-option")
    given body in strings(0, 64), pinV in integers(-1000, 1000),
          present in booleans()
    let v0 = if present:
      Note(body: body, pin: some(pinV))
    else:
      Note(body: body, pin: none(int))
    let r = decode[Note](encode(v0).get)
    ensure r.isOk
    ensure r.get.body == v0.body
    ensure r.get.pin == v0.pin

  property "Catalog with seq[Item] children round-trips":
    with Settings(maxExamples: 150, testId: "p7-catalog")
    given catName in strings(1, 24),
          itemNames in lists(strings(1, 16), 0, 8)
    var items: seq[Item] = @[]
    for ln in itemNames: items.add(Item(label: ln))
    let v0 = Catalog(name: catName, items: items)
    let r = decode[Catalog](encode(v0).get)
    ensure r.isOk
    ensure r.get.name == v0.name
    ensure r.get.items.len == v0.items.len
    for i in 0 ..< v0.items.len:
      ensure r.get.items[i].label == v0.items[i].label

suite "P8 — encode determinism (forAll)":

  property "encode(Service) is deterministic":
    with Settings(maxExamples: 300, testId: "p8-service")
    given name in strings(1, 32), port in integers(0, 65535)
    let v = Service(name: name, port: port)
    let a = encode(v).get
    let b = encode(v).get
    ensure a == b

  property "encode(Catalog) is deterministic across child order":
    with Settings(maxExamples: 150, testId: "p8-catalog")
    given catName in strings(1, 24),
          itemNames in lists(strings(1, 16), 0, 8)
    var items: seq[Item] = @[]
    for ln in itemNames: items.add(Item(label: ln))
    let v = Catalog(name: catName, items: items)
    let a = encode(v).get
    let b = encode(v).get
    ensure a == b
