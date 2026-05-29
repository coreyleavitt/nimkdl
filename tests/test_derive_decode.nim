## Tests for deriveDecode — per-type macro emitting kdlDecode procs.
##
## Cycles D1-D15 of the clean-core rebuild fill this out one shape at
## a time. Each test defines a type, derives kdlDecode, parses a KDL
## source through StringCursor, runs the macro-generated decoder, and
## asserts the populated value + outcome.

import std/[options, unittest]

import ../src/derive_decode
import ../src/cursor
import ../src/intern
import ../src/lexer
import ../src/pragmas
import ../src/spans

type CursorFixture = ref object
  stream*: ref TokenStream
  cursor*: StringCursor

proc mkCursor(src: string): CursorFixture =
  var interner = initInterner()
  var sref: ref TokenStream
  new(sref)
  sref[] = lex(src, interner)
  result = CursorFixture(stream: sref,
                         cursor: initStringCursor(addr sref[], src))

suite "derive_decode — D1: tracer (one kdlArg string field)":

  type Service {.kdlNode: "service".} = object
    name {.kdlArg.}: string

  deriveDecode(Service)

  test "single string kdlArg populates field":
    let f = mkCursor("service \"web\"")
    var s: Service
    let r = kdlDecode(s, f.cursor)
    check r.isOk
    check s.name == "web"

  test "wrong node name returns error":
    let f = mkCursor("other \"web\"")
    var s: Service
    let r = kdlDecode(s, f.cursor)
    check r.isErr

suite "derive_decode — D2: multi-field typed args":

  type Edge {.kdlNode: "edge".} = object
    label {.kdlArg.}: string
    weight {.kdlArg.}: int
    bidir {.kdlArg.}: bool

  deriveDecode(Edge)

  test "string + int + bool populate in field order":
    let f = mkCursor("edge \"hot\" 7 #true")
    var v: Edge
    let r = kdlDecode(v, f.cursor)
    check r.isOk
    check v.label == "hot"
    check v.weight == 7
    check v.bidir == true

  test "negative int decodes":
    let f = mkCursor("edge \"x\" -3 #false")
    var v: Edge
    let r = kdlDecode(v, f.cursor)
    check r.isOk
    check v.weight == -3
    check v.bidir == false

  type Pt {.kdlNode: "pt".} = object
    x {.kdlArg.}: float
    y {.kdlArg.}: float

  deriveDecode(Pt)

  test "float kdlArgs populate":
    let f = mkCursor("pt 1.5 2.0")
    var p: Pt
    let r = kdlDecode(p, f.cursor)
    check r.isOk
    check p.x == 1.5
    check p.y == 2.0

  type Empty {.kdlNode: "empty".} = object

  deriveDecode(Empty)

  test "node with no fields decodes from bare":
    let f = mkCursor("empty")
    var v: Empty
    let r = kdlDecode(v, f.cursor)
    check r.isOk

  test "too many positional args returns error":
    let f = mkCursor("pt 1.0 2.0 3.0")
    var p: Pt
    let r = kdlDecode(p, f.cursor)
    check r.isErr

suite "derive_decode — D3: kdlProp via bytesEq dispatch":

  type Sv {.kdlNode: "sv".} = object
    host {.kdlProp.}: string
    port {.kdlProp.}: int
    enabled {.kdlProp.}: bool

  deriveDecode(Sv)

  test "three typed props populate":
    let f = mkCursor("sv host=\"a.b\" port=443 enabled=#true")
    var s: Sv
    let r = kdlDecode(s, f.cursor)
    check r.isOk
    check s.host == "a.b"
    check s.port == 443
    check s.enabled == true

  test "props in any order":
    let f = mkCursor("sv enabled=#false port=80 host=\"x\"")
    var s: Sv
    let r = kdlDecode(s, f.cursor)
    check r.isOk
    check s.host == "x"
    check s.port == 80
    check s.enabled == false

  test "unknown prop returns error":
    let f = mkCursor("sv unknown=1")
    var s: Sv
    let r = kdlDecode(s, f.cursor)
    check r.isErr

  type Mixed {.kdlNode: "mixed".} = object
    name {.kdlArg.}: string
    count {.kdlProp.}: int

  deriveDecode(Mixed)

  test "kdlArg + kdlProp combined":
    let f = mkCursor("mixed \"first\" count=3")
    var m: Mixed
    let r = kdlDecode(m, f.cursor)
    check r.isOk
    check m.name == "first"
    check m.count == 3

suite "derive_decode — D4: kdlChild single + seq + self-recursive Tree":

  type Action4 {.kdlNode: "action".} = object
    kind {.kdlArg.}: string

  deriveDecode(Action4)

  type Rule {.kdlNode: "rule".} = object
    id {.kdlArg.}: string
    action {.kdlChild.}: Action4

  deriveDecode(Rule)

  test "single kdlChild decodes nested node":
    let f = mkCursor("rule \"compaction\" {\n    action \"inject\"\n}")
    var r: Rule
    let res = kdlDecode(r, f.cursor)
    check res.isOk
    check r.id == "compaction"
    check r.action.kind == "inject"

  type Item {.kdlNode: "item".} = object
    label {.kdlArg.}: string

  deriveDecode(Item)

  type Catalog {.kdlNode: "catalog".} = object
    items {.kdlChild.}: seq[Item]

  deriveDecode(Catalog)

  test "kdlChild seq populates from multiple child nodes":
    let f = mkCursor("catalog {\n    item \"a\"\n    item \"b\"\n    item \"c\"\n}")
    var c: Catalog
    let res = kdlDecode(c, f.cursor)
    check res.isOk
    check c.items.len == 3
    check c.items[0].label == "a"
    check c.items[1].label == "b"
    check c.items[2].label == "c"

  test "empty children block leaves seq empty":
    let f = mkCursor("catalog")
    var c: Catalog
    let res = kdlDecode(c, f.cursor)
    check res.isOk
    check c.items.len == 0

  type Tree {.kdlNode: "tree".} = object
    value {.kdlArg.}: string
    children {.kdlChild.}: seq[Tree]

  deriveDecode(Tree)

  test "self-recursive Tree — depth 1":
    let f = mkCursor("tree \"root\"")
    var t: Tree
    let res = kdlDecode(t, f.cursor)
    check res.isOk
    check t.value == "root"
    check t.children.len == 0

  test "self-recursive Tree — depth 2":
    let f = mkCursor("tree \"root\" {\n    tree \"a\"\n    tree \"b\"\n}")
    var t: Tree
    let res = kdlDecode(t, f.cursor)
    check res.isOk
    check t.value == "root"
    check t.children.len == 2
    check t.children[0].value == "a"
    check t.children[1].value == "b"

  test "self-recursive Tree — depth 3 (the #11 closure)":
    let src = "tree \"L1\" {\n    tree \"L2a\" {\n        tree \"L3a\"\n        tree \"L3b\"\n    }\n    tree \"L2b\"\n}"
    let f = mkCursor(src)
    var t: Tree
    let res = kdlDecode(t, f.cursor)
    check res.isOk
    check t.value == "L1"
    check t.children.len == 2
    check t.children[0].value == "L2a"
    check t.children[0].children.len == 2
    check t.children[0].children[0].value == "L3a"
    check t.children[0].children[1].value == "L3b"
    check t.children[1].value == "L2b"
    check t.children[1].children.len == 0

suite "derive_decode — D6: Option[T] for arg / prop":

  type Config {.kdlNode: "config".} = object
    timeout {.kdlProp.}: Option[int]
    label {.kdlProp.}: Option[string]

  deriveDecode(Config)

  test "Option[T] kdlProp present → Some":
    let f = mkCursor("config timeout=30 label=\"staging\"")
    var c: Config
    let res = kdlDecode(c, f.cursor)
    check res.isOk
    check c.timeout == some(30)
    check c.label == some("staging")

  test "Option[T] kdlProp absent → None":
    let f = mkCursor("config timeout=30")
    var c: Config
    let res = kdlDecode(c, f.cursor)
    check res.isOk
    check c.timeout == some(30)
    check c.label == none(string)

  test "all Option[T] absent → all None":
    let f = mkCursor("config")
    var c: Config
    let res = kdlDecode(c, f.cursor)
    check res.isOk
    check c.timeout == none(int)
    check c.label == none(string)

  type Note {.kdlNode: "note".} = object
    text {.kdlArg.}: Option[string]

  deriveDecode(Note)

  test "Option[T] kdlArg present → Some":
    let f = mkCursor("note \"hi\"")
    var n: Note
    let res = kdlDecode(n, f.cursor)
    check res.isOk
    check n.text == some("hi")

  test "Option[T] kdlArg absent → None":
    let f = mkCursor("note")
    var n: Note
    let res = kdlDecode(n, f.cursor)
    check res.isOk
    check n.text == none(string)

suite "derive_decode — D7: enum fields (string-mapped + symbol-name)":

  type ActionKind = enum
    akInject = "inject"
    akDeny = "deny"
    akAllow = "allow"

  type ActionD {.kdlNode: "action".} = object
    kind {.kdlArg.}: ActionKind

  deriveDecode(ActionD)

  test "enum with explicit string mapping decodes from quoted string":
    let f = mkCursor("action \"inject\"")
    var a: ActionD
    let res = kdlDecode(a, f.cursor)
    check res.isOk
    check a.kind == akInject

  test "second enum variant":
    let f = mkCursor("action \"deny\"")
    var a: ActionD
    let res = kdlDecode(a, f.cursor)
    check res.isOk
    check a.kind == akDeny

  test "unknown enum literal returns error":
    let f = mkCursor("action \"unknown\"")
    var a: ActionD
    let res = kdlDecode(a, f.cursor)
    check res.isErr

  type Status = enum
    sOk
    sFailed

  type Job {.kdlNode: "job".} = object
    state {.kdlProp.}: Status

  deriveDecode(Job)

  test "plain enum decodes from symbol-name string":
    let f = mkCursor("job state=\"sOk\"")
    var j: Job
    let res = kdlDecode(j, f.cursor)
    check res.isOk
    check j.state == sOk

suite "derive_decode — D8: variant (case object) discriminator dispatch":

  type Effect = enum
    efDeny = "deny"
    efAllow = "allow"

  type Action9D {.kdlNode: "action".} = object
    case kind {.kdlArg.}: Effect
    of efDeny:
      reason {.kdlProp.}: string
    of efAllow:
      quota {.kdlProp.}: int

  deriveDecode(Action9D)

  test "variant — efDeny branch reads its branch-specific kdlProp":
    let f = mkCursor("action \"deny\" reason=\"blocked\"")
    var a: Action9D
    let res = kdlDecode(a, f.cursor)
    check res.isOk
    check a.kind == efDeny
    check a.reason == "blocked"

  test "variant — efAllow branch reads its different kdlProp":
    let f = mkCursor("action \"allow\" quota=1000")
    var a: Action9D
    let res = kdlDecode(a, f.cursor)
    check res.isOk
    check a.kind == efAllow
    check a.quota == 1000

  type Shape = enum
    skCircle = "circle"
    skEmpty = "empty"

  type DrawingD {.kdlNode: "drawing".} = object
    case kind {.kdlArg.}: Shape
    of skCircle:
      radius {.kdlProp.}: float
    of skEmpty:
      discard  # no fields

  deriveDecode(DrawingD)

  test "variant — branch with no fields decodes from bare":
    let f = mkCursor("drawing \"empty\"")
    var d: DrawingD
    let res = kdlDecode(d, f.cursor)
    check res.isOk
    check d.kind == skEmpty

  test "variant — circle branch with float prop":
    let f = mkCursor("drawing \"circle\" radius=2.5")
    var d: DrawingD
    let res = kdlDecode(d, f.cursor)
    check res.isOk
    check d.kind == skCircle
    check d.radius == 2.5

suite "derive_decode — D10: required-field bitmap":

  type Required10 {.kdlNode: "req".} = object
    name {.kdlArg.}: string  # required
    port {.kdlProp.}: int    # required

  deriveDecode(Required10)

  test "all required fields present → OK":
    let f = mkCursor("req \"web\" port=80")
    var r: Required10
    let res = kdlDecode(r, f.cursor)
    check res.isOk
    check r.name == "web"
    check r.port == 80

  test "missing required kdlProp → error":
    let f = mkCursor("req \"web\"")  # port missing
    var r: Required10
    let res = kdlDecode(r, f.cursor)
    check res.isErr

  test "missing required kdlArg → error":
    let f = mkCursor("req port=80")  # name missing
    var r: Required10
    let res = kdlDecode(r, f.cursor)
    check res.isErr

  type WithOpt {.kdlNode: "wopt".} = object
    name {.kdlArg.}: string         # required
    count {.kdlProp.}: Option[int]  # optional

  deriveDecode(WithOpt)

  test "missing Option field → still OK":
    let f = mkCursor("wopt \"x\"")
    var w: WithOpt
    let res = kdlDecode(w, f.cursor)
    check res.isOk
    check w.name == "x"
    check w.count == none(int)

  test "missing required even with optional present → error":
    let f = mkCursor("wopt count=5")
    var w: WithOpt
    let res = kdlDecode(w, f.cursor)
    check res.isErr

  type Item10 {.kdlNode: "item".} = object
    label {.kdlArg.}: string

  deriveDecode(Item10)

  type WithSeq {.kdlNode: "wseq".} = object
    name {.kdlArg.}: string             # required
    children {.kdlChild.}: seq[Item10]  # optional (empty seq is fine)

  deriveDecode(WithSeq)

  test "missing seq[T] kdlChild → still OK (empty seq)":
    let f = mkCursor("wseq \"x\"")
    var w: WithSeq
    let res = kdlDecode(w, f.cursor)
    check res.isOk
    check w.name == "x"
    check w.children.len == 0

suite "derive_decode — D9: kdlReserved tag validation":

  type HostD {.kdlNode: "host".} = object
    addr1 {.kdlArg, kdlReserved: "ipv4".}: string
    port {.kdlProp, kdlReserved: "u16".}: int

  deriveDecode(HostD)

  test "matching annotations decode cleanly":
    let f = mkCursor("host (ipv4)\"10.0.0.1\" port=(u16)80")
    var h: HostD
    let res = kdlDecode(h, f.cursor)
    check res.isOk
    check h.addr1 == "10.0.0.1"
    check h.port == 80

  test "missing kdlReserved annotation on arg returns error":
    let f = mkCursor("host \"10.0.0.1\" port=(u16)80")
    var h: HostD
    let res = kdlDecode(h, f.cursor)
    check res.isErr

  test "wrong kdlReserved annotation on arg returns error":
    let f = mkCursor("host (ipv6)\"::1\" port=(u16)80")
    var h: HostD
    let res = kdlDecode(h, f.cursor)
    check res.isErr

  test "missing kdlReserved annotation on prop returns error":
    let f = mkCursor("host (ipv4)\"10.0.0.1\" port=80")
    var h: HostD
    let res = kdlDecode(h, f.cursor)
    check res.isErr
