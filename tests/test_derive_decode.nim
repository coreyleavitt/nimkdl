## Tests for deriveDecode — per-type macro emitting kdlDecode procs.
##
## Cycles D1-D15 of the clean-core rebuild fill this out one shape at
## a time. Each test defines a type, derives kdlDecode, parses a KDL
## source through StringCursor, runs the macro-generated decoder, and
## asserts the populated value + outcome.

import std/[options, unittest]

import ../src/derive_decode
import ../src/cursor
import ../src/lexer
import ../src/pragmas
import ../src/spans

type CursorFixture = ref object
  stream*: ref TokenStream
  cursor*: StringCursor

proc mkCursor(src: string): CursorFixture =
  var sref: ref TokenStream
  new(sref)
  sref[] = lex(src)
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

suite "derive_decode — D12: kdlRename":

  type CfgD {.kdlNode: "cfg".} = object
    tmpl {.kdlProp, kdlRename: "template".}: string

  deriveDecode(CfgD)

  test "kdlRename substitutes wire key on decode":
    let f = mkCursor("cfg template=\"default\"")
    var c: CfgD
    let res = kdlDecode(c, f.cursor)
    check res.isOk
    check c.tmpl == "default"

  test "Nim field name does NOT decode (wire key is renamed)":
    let f = mkCursor("cfg tmpl=\"x\"")
    var c: CfgD
    let res = kdlDecode(c, f.cursor)
    check res.isErr  # "tmpl" is unknown property

suite "derive_decode — D5: perfect-hash dispatch (>8 kdlProp fields)":

  type Wide {.kdlNode: "w".} = object
    a {.kdlProp.}: int
    b {.kdlProp.}: int
    c {.kdlProp.}: int
    d {.kdlProp.}: int
    e {.kdlProp.}: int
    f {.kdlProp.}: int
    g {.kdlProp.}: int
    h {.kdlProp.}: int
    i {.kdlProp.}: int
    j {.kdlProp.}: int  # 10 props — triggers the hash-dispatch path

  deriveDecode(Wide)

  test "all 10 props decode in order":
    let src = "w a=1 b=2 c=3 d=4 e=5 f=6 g=7 h=8 i=9 j=10"
    let fix = mkCursor(src)
    var w: Wide
    let res = kdlDecode(w, fix.cursor)
    check res.isOk
    check w.a == 1
    check w.b == 2
    check w.c == 3
    check w.d == 4
    check w.e == 5
    check w.f == 6
    check w.g == 7
    check w.h == 8
    check w.i == 9
    check w.j == 10

  test "props in scrambled order — hash dispatch is order-independent":
    let src = "w j=10 a=1 e=5 c=3 h=8 b=2 g=7 d=4 i=9 f=6"
    let fix = mkCursor(src)
    var w: Wide
    let res = kdlDecode(w, fix.cursor)
    check res.isOk
    check w.a == 1
    check w.j == 10
    check w.e == 5

  test "unknown prop on wide type returns error":
    let src = "w zzz=99"
    let fix = mkCursor(src)
    var w: Wide
    let res = kdlDecode(w, fix.cursor)
    check res.isErr

suite "derive_decode — slashdash entry/children suppression (regression)":
  # Review finding #1: deriveDecode had no slashdash tracking, so a `/-`
  # prefixed entry/children block was decoded as if real — corrupting the
  # value or raising a spurious "extra positional argument" error.
  # buildDoc (Cat 3) suppresses these correctly; Cat 2 must agree.

  type SdTag {.kdlNode: "tag".} = object
    label {.kdlArg.}: string
  deriveDecode(SdTag)

  type SdSvc {.kdlNode: "service".} = object
    name {.kdlArg.}: string
    port {.kdlProp.}: int
  deriveDecode(SdSvc)

  type SdChild {.kdlNode: "child".} = object
    tag {.kdlArg.}: string
  deriveDecode(SdChild)
  type SdParent {.kdlNode: "parent".} = object
    kids {.kdlChild.}: seq[SdChild]
  deriveDecode(SdParent)

  test "slashdashed arg before a real arg is ignored":
    let fix = mkCursor("tag /-\"skip\" \"keep\"")
    var t: SdTag
    let res = kdlDecode(t, fix.cursor)
    check res.isOk
    check t.label == "keep"

  test "slashdashed prop is ignored; the real prop wins":
    let fix = mkCursor("service \"web\" /-port=99 port=80")
    var s: SdSvc
    let res = kdlDecode(s, fix.cursor)
    check res.isOk
    check s.port == 80

  test "trailing slashdashed (unknown-named) prop is ignored, not errored":
    let fix = mkCursor("service \"web\" port=80 /-extra=1")
    var s: SdSvc
    let res = kdlDecode(s, fix.cursor)
    check res.isOk
    check s.name == "web"
    check s.port == 80

  test "slashdashed children block is ignored":
    let fix = mkCursor("parent /-{ child \"x\" }")
    var p: SdParent
    let res = kdlDecode(p, fix.cursor)
    check res.isOk
    check p.kids.len == 0

  test "slashdashed child node INSIDE a real children block is ignored":
    # The nested-loop variant — found by the P9b property, missed by the
    # whole-block case above. A `/-`'d child among real children must not
    # be decoded into the seq.
    let fix = mkCursor("parent {\n  /-child \"junk\"\n  child \"real\"\n}")
    var p: SdParent
    let res = kdlDecode(p, fix.cursor)
    check res.isOk
    check p.kids.len == 1
    check p.kids[0].tag == "real"

suite "derive_decode — ckRef: ref object as the user-facing type (#9/#39)":

  type RefSvc {.kdlNode: "rsvc".} = ref object
    name {.kdlArg.}: string
    port {.kdlProp.}: int

  deriveDecode(RefSvc)

  test "ref object allocates and populates":
    let f = mkCursor("rsvc \"web\" port=8")
    var s: RefSvc
    let r = kdlDecode(s, f.cursor)
    check r.isOk
    check s != nil
    check s.name == "web"
    check s.port == 8

suite "derive_decode — ckRef: ref object as child field (#9/#39)":

  type RefKid {.kdlNode: "kid".} = ref object
    tag {.kdlArg.}: string
  type RefParent1 {.kdlNode: "parent".} = object
    one {.kdlChild.}: RefKid
  type RefParentN {.kdlNode: "parent".} = object
    many {.kdlChild.}: seq[RefKid]

  deriveDecode(RefKid)
  deriveDecode(RefParent1)
  deriveDecode(RefParentN)

  test "single ref child allocates and populates":
    let f = mkCursor("parent {\n  kid \"a\"\n}")
    var p: RefParent1
    let r = kdlDecode(p, f.cursor)
    check r.isOk
    check p.one != nil
    check p.one.tag == "a"

  test "seq of ref children each allocate":
    let f = mkCursor("parent {\n  kid \"a\"\n  kid \"b\"\n}")
    var p: RefParentN
    let r = kdlDecode(p, f.cursor)
    check r.isOk
    check p.many.len == 2
    check p.many[0].tag == "a"
    check p.many[1].tag == "b"

suite "derive_decode — type aliases resolve to base primitive (#39 item 5)":

  type Port = int
  type Name = string
  type AliasHost {.kdlNode: "ahost".} = object
    title {.kdlArg.}: Name
    port {.kdlProp.}: Port

  deriveDecode(AliasHost)

  test "aliased arg + prop decode through the underlying primitive":
    let f = mkCursor("ahost \"web\" port=8")
    var h: AliasHost
    let r = kdlDecode(h, f.cursor)
    check r.isOk
    check h.title == "web"
    check h.port == 8

suite "derive_decode — ckOption: Option[object] child (#39 item 1)":

  type OkChild {.kdlNode: "child".} = object
    tag {.kdlArg.}: string
  type OptParent {.kdlNode: "parent".} = object
    sect {.kdlChild.}: Option[OkChild]

  deriveDecode(OkChild)
  deriveDecode(OptParent)

  test "present optional child → Some":
    let f = mkCursor("parent {\n  child \"a\"\n}")
    var p: OptParent
    let r = kdlDecode(p, f.cursor)
    check r.isOk
    check p.sect.isSome
    check p.sect.get.tag == "a"

  test "absent optional child → None":
    let f = mkCursor("parent")
    var p: OptParent
    let r = kdlDecode(p, f.cursor)
    check r.isOk
    check p.sect.isNone

import std/strutils

suite "derive_decode — kdlScalar custom hook (#39 item3)":

  type Color = object
    r, g, b: uint8

  proc kdlDecodeValue(val: KdlValue, T: typedesc[Color]): Result[Color, string] =
    if val.kind != kvString:
      return err[Color, string]("expected #rrggbb string")
    let s = val.strVal
    if s.len == 7 and s[0] == '#':
      try:
        ok[Color, string](Color(r: uint8(parseHexInt(s[1..2])),
                                 g: uint8(parseHexInt(s[3..4])),
                                 b: uint8(parseHexInt(s[5..6]))))
      except CatchableError:
        err[Color, string]("invalid hex color")
    else:
      err[Color, string]("expected #rrggbb")

  type Paint {.kdlNode: "paint".} = object
    color {.kdlScalar.}: Color

  deriveDecode(Paint)

  test "kdlScalar prop decodes via hook":
    let f = mkCursor("paint color=\"#ff8000\"")
    var p: Paint
    let r = kdlDecode(p, f.cursor)
    check r.isOk
    check p.color == Color(r: 255, g: 128, b: 0)

  test "hook error surfaces as decode error":
    let f = mkCursor("paint color=\"nope\"")
    var p: Paint
    let r = kdlDecode(p, f.cursor)
    check r.isErr

suite "derive_decode — kdlScalar typed numeric input (rfc §8)":

  # The KdlValue interchange form lets a kdlScalar field decode from a KDL
  # NUMBER — impossible under the old string-only hook, which rejected any
  # non-string token before the hook ran.
  type Duration = object
    millis: int64

  proc kdlDecodeValue(val: KdlValue, T: typedesc[Duration]): Result[Duration, string] =
    case val.kind
    of kvInt:    ok[Duration, string](Duration(millis: val.intVal))
    else:        err[Duration, string]("expected integer milliseconds")

  type Timeout {.kdlNode: "timeout".} = object
    after {.kdlScalar.}: Duration

  deriveDecode(Timeout)

  test "kdlScalar prop decodes from a bare integer (typed input)":
    let f = mkCursor("timeout after=500")
    var t: Timeout
    let r = kdlDecode(t, f.cursor)
    check r.isOk
    check t.after.millis == 500

  test "wrong scalar kind surfaces as decode error":
    let f = mkCursor("timeout after=\"nope\"")
    var t: Timeout
    let r = kdlDecode(t, f.cursor)
    check r.isErr

suite "derive_decode — S1: kdlVariadic (variadic positional args)":

  type Cmd {.kdlNode: "cmd".} = object
    name {.kdlArg.}: string
    rest {.kdlVariadic.}: seq[string]

  deriveDecode(Cmd)

  test "fixed arg binds first, remaining args collect into the seq":
    let f = mkCursor("cmd \"run\" \"a\" \"b\" \"c\"")
    var v: Cmd
    let r = kdlDecode(v, f.cursor)
    check r.isOk
    check v.name == "run"
    check v.rest == @["a", "b", "c"]

  test "no extra args yields an empty variadic seq":
    let f = mkCursor("cmd \"run\"")
    var v: Cmd
    let r = kdlDecode(v, f.cursor)
    check r.isOk
    check v.name == "run"
    check v.rest.len == 0

  type Nums {.kdlNode: "nums".} = object
    vals {.kdlVariadic.}: seq[int]

  deriveDecode(Nums)

  test "variadic of typed (int) elements decodes all args":
    let f = mkCursor("nums 1 2 3 4")
    var v: Nums
    let r = kdlDecode(v, f.cursor)
    check r.isOk
    check v.vals == @[1, 2, 3, 4]

suite "derive_decode — S1: kdlVariadic macro-error guards":

  test "a valid single-variadic type compiles (sanity)":
    # Positive control: the guard rejections below mean nothing unless the
    # well-formed shape actually compiles.
    check compiles((
      block:
        type Ok {.kdlNode: "ok".} = object
          head {.kdlArg.}: string
          tail {.kdlVariadic.}: seq[string]
        deriveDecode(Ok)
    ))

  test "{.kdlArg.} on a seq field is rejected (did-you-mean kdlVariadic)":
    # §3.5.5.1: kdlArg consumes one arg; a seq[T] arg field is the variadic
    # mistake. PINNED guard.
    check not compiles((
      block:
        type Bad {.kdlNode: "bad".} = object
          tags {.kdlArg.}: seq[string]
        deriveDecode(Bad)
    ))

  test "two {.kdlVariadic.} fields on one type are rejected":
    # PINNED guard: only one positional tail per type.
    check not compiles((
      block:
        type Bad {.kdlNode: "bad".} = object
          a {.kdlVariadic.}: seq[string]
          b {.kdlVariadic.}: seq[int]
        deriveDecode(Bad)
    ))

  test "{.kdlVariadic.} on a non-seq field is rejected":
    check not compiles((
      block:
        type Bad {.kdlNode: "bad".} = object
          port {.kdlVariadic.}: int
        deriveDecode(Bad)
    ))
