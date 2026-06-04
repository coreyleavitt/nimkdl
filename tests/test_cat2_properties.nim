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

import std/[options, unittest, strutils]

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

  # S5: a type with a native field default. `port` is required-shaped (plain
  # int) but carries a default, so its absence on the wire yields 8080 rather
  # than a missing-required error.
  type Defaulted {.kdlNode: "dfl".} = object
    name {.kdlArg.}: string
    port {.kdlProp.}: int = 8080

  # S7: a type with a {.kdlSkipEncode.} field. The field is never written to
  # KDL, so encode(v) omits it; decode(encode(v)) therefore leaves it at its
  # zero/default value regardless of what `v` held. The field is Option[string]
  # so decode of the (field-absent) bytes is not a missing-required error — it
  # round-trips to None, the canonical "back to zero" outcome for skipEncode.
  type SkipEnc {.kdlNode: "ske".} = object
    name {.kdlArg.}: string
    cached {.kdlSkipEncode, kdlProp.}: Option[string]

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

suite "P9b — slashdash injection invariance (typed decode)":
  # Hardens the class of bug found in review: deriveDecode had no
  # slashdash tracking, so `/-`-prefixed entries/children decoded as
  # real. Slashdash means "comment out" — injecting it MUST NOT change
  # the decoded value. We fuzz slashdash STRUCTURE (how many, where)
  # around fixed always-valid real content; content fidelity is P7's
  # job. Cat 3 `buildDoc` suppresses identically — the surfaces agree.

  property "slashdashed args/props/children never change a decoded Service":
    with Settings(maxExamples: 400, testId: "p9b-slashdash-service")
    given port in integers(0, 65535),
          nLeadArg in integers(0, 3),
          nMidProp in integers(0, 3),
          nTrailProp in integers(0, 3),
          nChild in integers(0, 2)
    var src = "service"
    for i in 0 ..< nLeadArg: src.add " /-\"j" & $i & "\""   # slashdashed args
    src.add " \"web\""                                      # the one real arg
    for i in 0 ..< nMidProp: src.add " /-m" & $i & "=" & $i # slashdashed props
    src.add " port=" & $port                                # the one real prop
    for i in 0 ..< nTrailProp: src.add " /-t" & $i & "=" & $i
    for i in 0 ..< nChild: src.add " /-{ junk \"x\" }"      # slashdashed children
    let r = decode[Service](src)
    ensure r.isOk
    ensure r.get.name == "web"
    ensure r.get.port == port

  property "slashdashed child nodes never change a decoded Catalog":
    with Settings(maxExamples: 300, testId: "p9b-slashdash-catalog")
    given nReal in integers(0, 5), nLeadJunk in integers(0, 3),
          interleaveJunk in booleans()
    var src = "catalog \"c\" {\n"
    for i in 0 ..< nLeadJunk: src.add "  /-item \"j" & $i & "\"\n"
    for i in 0 ..< nReal:
      src.add "  item \"r" & $i & "\"\n"
      if interleaveJunk: src.add "  /-item \"x" & $i & "\"\n"
    src.add "}\n"
    let r = decode[Catalog](src)
    ensure r.isOk
    ensure r.get.items.len == nReal
    for i in 0 ..< nReal:
      ensure r.get.items[i].label == "r" & $i

suite "S5 — native field defaults (forAll)":

  property "an absent defaulted prop yields its default; present keeps wire value":
    # Restrict the name to a quote/backslash-free ASCII range so the
    # hand-built wire string needs no KDL escaping — the property under test
    # is default-application, not string escaping (covered by P7).
    with Settings(maxExamples: 300, testId: "s5-defaulted")
    given nm in strings(intervals([(0x61'i32, 0x7a'i32)]), 1, 24),
          present in booleans(), port in integers(0, 65535)
    var src = "dfl \"" & nm & "\""
    if present: src.add " port=" & $port
    let r = decode[Defaulted](src)
    ensure r.isOk
    ensure r.get.name == nm
    if present: ensure r.get.port == port
    else:       ensure r.get.port == 8080

suite "S7 — kdlSkipEncode returns the field to zero after round-trip (forAll)":

  property "a kdlSkipEncode field is absent from the bytes; decode leaves it zero":
    # The field's value in v0 must NOT survive a round-trip — it's never
    # emitted, so decode of the emitted bytes can't repopulate it. Use a
    # quote/backslash-free lowercase alphabet for both fields so the
    # hand-checked invariant isn't muddied by string-escaping.
    with Settings(maxExamples: 300, testId: "s7-skip-encode")
    given nm in strings(intervals([(0x61'i32, 0x7a'i32)]), 1, 24),
          cachedV in strings(intervals([(0x61'i32, 0x7a'i32)]), 1, 24)
    let v0 = SkipEnc(name: nm, cached: some(cachedV))
    let bytes = encode(v0).get
    # The skipped field's value never appears on the wire.
    ensure "cached" notin bytes
    let r = decode[SkipEnc](bytes)
    ensure r.isOk
    ensure r.get.name == nm
    ensure r.get.cached.isNone       # back to zero — it was never encoded
