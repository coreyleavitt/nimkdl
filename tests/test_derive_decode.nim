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

suite "derive_decode — S2b: kdlRenameAll convention on prop keys":

  type RetryCfg {.kdlNode: "retry", kdlRenameAll: kcKebabCase.} = object
    maxRetries {.kdlProp.}: int

  deriveDecode(RetryCfg)

  test "kdlRenameAll: kcKebabCase decodes max-retries=3":
    let f = mkCursor("retry max-retries=3")
    var v: RetryCfg
    let r = kdlDecode(v, f.cursor)
    check r.isOk
    check v.maxRetries == 3

  test "the un-renamed wire key is no longer accepted":
    let f = mkCursor("retry maxRetries=3")
    var v: RetryCfg
    let r = kdlDecode(v, f.cursor)
    check r.isErr

  type RetryScream {.kdlNode: "retry", kdlRenameAll: kcScreamingSnakeCase.} = object
    maxRetries {.kdlProp.}: int

  deriveDecode(RetryScream)

  test "kdlRenameAll: kcScreamingSnakeCase decodes MAX_RETRIES=3":
    let f = mkCursor("retry MAX_RETRIES=3")
    var v: RetryScream
    let r = kdlDecode(v, f.cursor)
    check r.isOk
    check v.maxRetries == 3

  type RetryKeep {.kdlNode: "retry", kdlRenameAll: kcKebabCase.} = object
    maxRetries {.kdlProp, kdlRename: "keep".}: int

  deriveDecode(RetryKeep)

  test "kdlRename overrides kdlRenameAll on decode (stays 'keep')":
    let f = mkCursor("retry keep=3")
    var v: RetryKeep
    let r = kdlDecode(v, f.cursor)
    check r.isOk
    check v.maxRetries == 3

  test "the convention-transformed key is NOT accepted when kdlRename set":
    let f = mkCursor("retry max-retries=3")
    var v: RetryKeep
    let r = kdlDecode(v, f.cursor)
    check r.isErr

  # node name unaffected by kdlRenameAll
  type MultiWordNode {.kdlRenameAll: kcScreamingSnakeCase.} = object
    maxRetries {.kdlProp.}: int

  deriveDecode(MultiWordNode)

  test "kdlRenameAll does not affect the node name (decode)":
    let f = mkCursor("multi-word-node MAX_RETRIES=3")
    var v: MultiWordNode
    let r = kdlDecode(v, f.cursor)
    check r.isOk
    check v.maxRetries == 3

suite "derive_decode — S4 step 1: unknown child nodes are strict":

  type S4Child {.kdlNode: "known".} = object
    label {.kdlArg.}: string

  deriveDecode(S4Child)

  type S4Parent {.kdlNode: "parent".} = object
    known {.kdlChild.}: S4Child

  deriveDecode(S4Parent)

  test "unknown child node (type WITH a child field) → peTypeUnknownField":
    let f = mkCursor("parent {\n    known \"ok\"\n    mystery \"x\"\n}")
    var p: S4Parent
    let r = kdlDecode(p, f.cursor)
    check r.isErr
    check r.getErr.code == peTypeUnknownField

  test "known child still decodes when it is the only child":
    let f = mkCursor("parent {\n    known \"ok\"\n}")
    var p: S4Parent
    let r = kdlDecode(p, f.cursor)
    check r.isOk
    check p.known.label == "ok"

  type S4NoKids {.kdlNode: "leaf".} = object
    id {.kdlArg.}: string

  deriveDecode(S4NoKids)

  test "unknown child node (type with NO child fields) → peTypeUnknownField":
    let f = mkCursor("leaf \"a\" {\n    surprise 1\n}")
    var v: S4NoKids
    let r = kdlDecode(v, f.cursor)
    check r.isErr
    check r.getErr.code == peTypeUnknownField

suite "derive_decode — S4 step 2: kdlIgnoreUnknown opt-out":

  type S4IgChild {.kdlNode: "known".} = object
    label {.kdlArg.}: string

  deriveDecode(S4IgChild)

  type S4Lenient {.kdlNode: "lenient", kdlIgnoreUnknown.} = object
    name {.kdlProp.}: string
    known {.kdlChild.}: S4IgChild

  deriveDecode(S4Lenient)

  test "kdlIgnoreUnknown ignores both unknown prop and unknown child":
    let f = mkCursor(
      "lenient name=\"hi\" extra=99 {\n    known \"ok\"\n    mystery \"x\"\n}")
    var v: S4Lenient
    let r = kdlDecode(v, f.cursor)
    check r.isOk
    check v.name == "hi"
    check v.known.label == "ok"

  type S4LenientNoKids {.kdlNode: "lleaf", kdlIgnoreUnknown.} = object
    id {.kdlArg.}: string

  deriveDecode(S4LenientNoKids)

  test "kdlIgnoreUnknown on a type with no child fields skips unknown child":
    let f = mkCursor("lleaf \"a\" {\n    surprise 1\n}")
    var v: S4LenientNoKids
    let r = kdlDecode(v, f.cursor)
    check r.isOk
    check v.id == "a"

suite "derive_decode — S5: native field defaults":

  type S5Basic {.kdlNode: "c".} = object
    name {.kdlArg.}: string
    port {.kdlProp.}: int = 8080

  deriveDecode(S5Basic)

  test "absent defaulted prop gets its native default":
    let f = mkCursor("c \"x\"")
    var v: S5Basic
    let r = kdlDecode(v, f.cursor)
    check r.isOk
    check v.name == "x"
    check v.port == 8080

  test "present defaulted prop keeps the wire value (default not applied)":
    let f = mkCursor("c \"x\" port=9090")
    var v: S5Basic
    let r = kdlDecode(v, f.cursor)
    check r.isOk
    check v.port == 9090

  type S5Req {.kdlNode: "req".} = object
    host {.kdlProp.}: string          # required, no default
    maxRetries {.kdlRename: "max-retries", kdlProp.}: int = 3

  deriveDecode(S5Req)

  test "missing required field still errors AND names it by wire key":
    let f = mkCursor("req max-retries=5")   # host absent
    var v: S5Req
    let r = kdlDecode(v, f.cursor)
    check r.isErr
    check r.getErr.code == peTypeMissingRequired
    check r.getErr.hint.contains("host")

  test "defaulted required-named field absent → default applied, decode ok":
    let f = mkCursor("req host=\"h\"")      # max-retries absent
    var v: S5Req
    let r = kdlDecode(v, f.cursor)
    check r.isOk
    check v.host == "h"
    check v.maxRetries == 3

  # MIXED-ORDER — round-2 slot-vs-declaration misalignment scenario.
  type S5Mixed {.kdlNode: "mix".} = object
    a {.kdlProp.}: int                 # required → slot 0
    b {.kdlProp.}: Option[int]         # optional → slot -1
    c {.kdlProp.}: int = 7             # defaulted → next real slot
    d {.kdlProp.}: int                 # required → next real slot

  deriveDecode(S5Mixed)

  test "mixed order: only a + d present → c defaulted, b none, no misassignment":
    let f = mkCursor("mix a=1 d=4")
    var v: S5Mixed
    let r = kdlDecode(v, f.cursor)
    check r.isOk
    check v.a == 1
    check v.b.isNone
    check v.c == 7
    check v.d == 4

  test "mixed order: c present on the wire keeps its value":
    let f = mkCursor("mix a=1 d=4 c=99")
    var v: S5Mixed
    let r = kdlDecode(v, f.cursor)
    check r.isOk
    check v.c == 99

  test "a const-call / noSideEffect default compiles (positive control)":
    # A literal default and a {.noSideEffect.}/func-headed call are both
    # VM-evaluable, so the embed[T] guard must accept them.
    check compiles((
      block:
        func defPort(): int {.noSideEffect.} = 8080
        type OkDef {.kdlNode: "okdef".} = object
          name {.kdlArg.}: string
          port {.kdlProp.}: int = defPort()
        deriveDecode(OkDef)
    ))

  test "a VM-incompatible (FFI) default is rejected by Nim's own folding":
    # §4 S5 specified a Call-head {.noSideEffect.} guard inside deriveDecode.
    # That guard is unreachable: by the time the typed macro inspects T, Nim
    # has already const-folded every field-default initializer in the NimVM
    # (a CT-evaluable side-effecting call folds to its literal result). A
    # genuinely VM-incompatible default — e.g. one calling an importc proc —
    # fails at the `type` definition itself, strictly before deriveDecode
    # runs. So the embed[T]/VM-safety property is structurally enforced one
    # phase earlier by the language. This pins that the rejection still
    # happens (just not via our macro). PINNED.
    check not compiles((
      block:
        proc ffiDefault(): int =
          var f = open("/tmp/nkdl_should_never_open", fmWrite)  # importc at CT
          result = 1
        type BadDef {.kdlNode: "baddef".} = object
          name {.kdlArg.}: string
          port {.kdlProp.}: int = ffiDefault()
        deriveDecode(BadDef)
    ))

suite "derive_decode — S6: kdlAlias decode-only alternate keys":

  type Paint {.kdlNode: "paint".} = object
    color {.kdlProp, kdlAlias: "colour".}: string

  deriveDecode(Paint)

  test "canonical key decodes":
    let f = mkCursor("paint color=\"red\"")
    var v: Paint
    let r = kdlDecode(v, f.cursor)
    check r.isOk
    check v.color == "red"

  test "alias key decodes into the same field":
    let f = mkCursor("paint colour=\"red\"")
    var v: Paint
    let r = kdlDecode(v, f.cursor)
    check r.isOk
    check v.color == "red"

  type Versioned {.kdlNode: "versioned".} = object
    name {.kdlProp, kdlAlias("title", "label").}: string

  deriveDecode(Versioned)

  test "multiple aliases on one field — each decodes":
    block:
      let f = mkCursor("versioned name=\"a\"")
      var v: Versioned
      check kdlDecode(v, f.cursor).isOk
      check v.name == "a"
    block:
      let f = mkCursor("versioned title=\"b\"")
      var v: Versioned
      check kdlDecode(v, f.cursor).isOk
      check v.name == "b"
    block:
      let f = mkCursor("versioned label=\"c\"")
      var v: Versioned
      check kdlDecode(v, f.cursor).isOk
      check v.name == "c"

  # The AC (rfc §4 S6): a >8-field type carrying an alias forces useHash=false
  # for the WHOLE type (the FNV hash table is alias-blind). This exercises the
  # if-elif fallback path, NOT the perfect-hash path. Both the canonical and
  # alias keys must still decode.
  type Wide {.kdlNode: "wide".} = object
    f1 {.kdlProp.}: int
    f2 {.kdlProp.}: int
    f3 {.kdlProp.}: int
    f4 {.kdlProp.}: int
    f5 {.kdlProp.}: int
    f6 {.kdlProp.}: int
    f7 {.kdlProp.}: int
    f8 {.kdlProp.}: int
    color {.kdlProp, kdlAlias: "colour".}: string

  deriveDecode(Wide)

  test ">8-field type with an alias — canonical key decodes (if-elif fallback)":
    let f = mkCursor("wide f1=1 f2=2 f3=3 f4=4 f5=5 f6=6 f7=7 f8=8 color=\"red\"")
    var v: Wide
    let r = kdlDecode(v, f.cursor)
    check r.isOk
    check v.f1 == 1
    check v.f8 == 8
    check v.color == "red"

  test ">8-field type with an alias — alias key decodes (if-elif fallback)":
    let f = mkCursor("wide f1=1 f2=2 f3=3 f4=4 f5=5 f6=6 f7=7 f8=8 colour=\"blue\"")
    var v: Wide
    let r = kdlDecode(v, f.cursor)
    check r.isOk
    check v.color == "blue"

suite "derive_decode — S6: kdlAlias macro-error guards":

  test "a valid aliased type compiles (sanity)":
    check compiles((
      block:
        type Ok {.kdlNode: "ok".} = object
          color {.kdlProp, kdlAlias: "colour".}: string
        deriveDecode(Ok)
    ))

  test "an alias colliding with another field's canonical key is rejected":
    check not compiles((
      block:
        type Bad {.kdlNode: "bad".} = object
          color {.kdlProp, kdlAlias: "shade".}: string
          shade {.kdlProp.}: string
        deriveDecode(Bad)
    ))

  test "an alias colliding with another alias is rejected":
    check not compiles((
      block:
        type Bad {.kdlNode: "bad".} = object
          a {.kdlProp, kdlAlias: "dup".}: string
          b {.kdlProp, kdlAlias: "dup".}: string
        deriveDecode(Bad)
    ))

suite "derive_decode — S7: directional skip (kdlSkipDecode)":

  type SkipDProp {.kdlNode: "sdp".} = object
    name {.kdlArg.}: string
    secret {.kdlSkipDecode, kdlProp.}: string

  deriveDecode(SkipDProp)

  test "kdlSkipDecode prop ignores any wire value, keeps zero/default":
    # `secret=...` is present on the wire but must NOT be read.
    let f = mkCursor("sdp \"web\" secret=\"leaked\"")
    var s: SkipDProp
    let r = kdlDecode(s, f.cursor)
    check r.isOk
    check s.name == "web"
    check s.secret == ""           # untouched — kept its zero value

  test "kdlSkipDecode prop with no wire value is not a missing-required error":
    let f = mkCursor("sdp \"web\"")
    var s: SkipDProp
    let r = kdlDecode(s, f.cursor)
    check r.isOk
    check s.secret == ""

  type SkipDDefault {.kdlNode: "sdd".} = object
    name {.kdlArg.}: string
    mode {.kdlSkipDecode, kdlProp.}: string = "fallback"

  deriveDecode(SkipDDefault)

  test "kdlSkipDecode composes with an S5 native default (kept, wire ignored)":
    let f = mkCursor("sdd \"web\" mode=\"override\"")
    var s: SkipDDefault
    let r = kdlDecode(s, f.cursor)
    check r.isOk
    check s.mode == "fallback"     # native default, not the wire "override"

  type SkipDArg {.kdlNode: "sda".} = object
    first {.kdlArg.}: string
    skipped {.kdlSkipDecode, kdlArg.}: string
    third {.kdlArg.}: int

  deriveDecode(SkipDArg)

  test "kdlSkipDecode on a kdlArg advances the positional counter (no shift)":
    # Wire has THREE positionals; the middle one is consumed-and-ignored so
    # `third` still binds the 3rd arg, not the 2nd.
    let f = mkCursor("sda \"a\" \"ignored\" 99")
    var s: SkipDArg
    let r = kdlDecode(s, f.cursor)
    check r.isOk
    check s.first == "a"
    check s.skipped == ""          # kept its default
    check s.third == 99            # bound the 3rd positional, not the 2nd

  type SkipBoth {.kdlNode: "sb".} = object
    name {.kdlArg.}: string
    hidden {.kdlSkip, kdlProp.}: string

  deriveDecode(SkipBoth)

  test "kdlSkip (both) ignores wire value on decode too":
    let f = mkCursor("sb \"web\" hidden=\"x\"")
    var s: SkipBoth
    let r = kdlDecode(s, f.cursor)
    check r.isOk
    check s.hidden == ""


suite "derive_decode — S8a: kdlFlatten decode":

  type Meta = object
    author {.kdlProp.}: string
    version {.kdlProp.}: int

  type Doc {.kdlNode: "doc".} = object
    title {.kdlArg.}: string
    meta {.kdlFlatten.}: Meta

  deriveDecode(Doc)

  test "flattened object props land in the parent namespace":
    let f = mkCursor("doc \"t\" author=\"me\" version=2")
    var v: Doc
    let r = kdlDecode(v, f.cursor)
    check r.isOk
    check v.title == "t"
    check v.meta.author == "me"
    check v.meta.version == 2

  test "a flattened required prop missing is a missing-required error":
    let f = mkCursor("doc \"t\" author=\"me\"")  # version absent
    var v: Doc
    let r = kdlDecode(v, f.cursor)
    check r.isErr

  # Arg-index test: two flattened args must occupy contiguous positional
  # slots AFTER the parent's fixed arg, in declaration order.
  type Coords = object
    x {.kdlArg.}: int
    y {.kdlArg.}: int

  type Placed {.kdlNode: "placed".} = object
    label {.kdlArg.}: string
    at {.kdlFlatten.}: Coords
    tail {.kdlArg.}: int

  deriveDecode(Placed)

  test "two flattened args are contiguous with parent fixed args (index order)":
    # positional 0 = label, 1 = at.x, 2 = at.y, 3 = tail
    let f = mkCursor("placed \"p\" 10 20 99")
    var v: Placed
    let r = kdlDecode(v, f.cursor)
    check r.isOk
    check v.label == "p"
    check v.at.x == 10
    check v.at.y == 20
    check v.tail == 99

  # Nested flatten: Inner flattens Deep; Mid flattens Inner.
  type Deep = object
    d {.kdlProp.}: string

  type Inner = object
    i {.kdlProp.}: int
    deep {.kdlFlatten.}: Deep

  type Outer {.kdlNode: "outer".} = object
    name {.kdlArg.}: string
    inner {.kdlFlatten.}: Inner

  deriveDecode(Outer)

  test "a nested flatten (flatten of a flattening object) decodes":
    let f = mkCursor("outer \"o\" i=7 d=\"deepval\"")
    var v: Outer
    let r = kdlDecode(v, f.cursor)
    check r.isOk
    check v.name == "o"
    check v.inner.i == 7
    check v.inner.deep.d == "deepval"

  # §3.5.3 regression (S8b fix): a flattened sub-field's wire key uses the
  # FLATTENED type's own {.kdlRenameAll.} convention, NOT the parent's. Before
  # the S8b fix, classify reused the enclosing type's convention for spliced
  # sub-fields, so a flattened kebab-cased type's keys were read verbatim and
  # the decode missed them. Here CMeta is kebab; the parent CDoc is verbatim.
  type CMeta {.kdlRenameAll: kcKebabCase.} = object
    authorName {.kdlProp.}: string
    schemaVersion {.kdlProp.}: int

  type CDoc {.kdlNode: "cdoc".} = object
    title {.kdlArg.}: string
    meta {.kdlFlatten.}: CMeta

  deriveDecode(CDoc)

  test "flattened sub-field keys use the flattened type's own convention":
    let f = mkCursor("cdoc \"t\" author-name=\"me\" schema-version=2")
    var v: CDoc
    let r = kdlDecode(v, f.cursor)
    check r.isOk
    check v.title == "t"
    check v.meta.authorName == "me"
    check v.meta.schemaVersion == 2

suite "derive_decode — S8a: kdlFlatten macro-error guards":

  test "a valid flattened type compiles (sanity)":
    check compiles((
      block:
        type M = object
          a {.kdlProp.}: string
        type D {.kdlNode: "d".} = object
          m {.kdlFlatten.}: M
        deriveDecode(D)
    ))

  test "kdlFlatten on a variant-bearing type is rejected":
    check not compiles((
      block:
        type Variant = object
          case kind {.kdlProp.}: bool
          of true:
            t {.kdlProp.}: string
          of false:
            f {.kdlProp.}: int
        type Bad {.kdlNode: "bad".} = object
          v {.kdlFlatten.}: Variant
        deriveDecode(Bad)
    ))

  test "a self-flattening field is rejected":
    check not compiles((
      block:
        type SelfFlat {.kdlNode: "sf".} = object
          name {.kdlArg.}: string
          me {.kdlFlatten.}: SelfFlat
        deriveDecode(SelfFlat)
    ))

  test "a wire-key collision between parent prop and flattened sub-prop is rejected":
    check not compiles((
      block:
        type Sub = object
          dup {.kdlProp.}: string
        type Clash {.kdlNode: "clash".} = object
          dup {.kdlProp.}: int
          sub {.kdlFlatten.}: Sub
        deriveDecode(Clash)
    ))

suite "derive_decode — S9: untagged variants ({.kdlUntagged.})":

  type Payload = enum
    plText = "text"
    plNum = "num"

  type Msg {.kdlNode: "msg", kdlUntagged.} = object
    case kind: Payload
    of plText:
      body {.kdlProp.}: string
    of plNum:
      value {.kdlProp.}: int

  deriveDecode(Msg)

  test "untagged — first branch (plText) matches when its prop is on the wire":
    let f = mkCursor("msg body=\"hi\"")
    var m: Msg
    let r = kdlDecode(m, f.cursor)
    check r.isOk
    check m.kind == plText
    check m.body == "hi"

  test "untagged — second branch (plNum) matches when its prop is on the wire":
    let f = mkCursor("msg value=42")
    var m: Msg
    let r = kdlDecode(m, f.cursor)
    check r.isOk
    check m.kind == plNum
    check m.value == 42

  test "untagged — no branch matches → peTypeNoVariantMatch":
    let f = mkCursor("msg other=1")
    var m: Msg
    let r = kdlDecode(m, f.cursor)
    check r.isErr
    check r.getErr.code == peTypeNoVariantMatch

  test "untagged — empty node (no required prop) → no branch matches":
    let f = mkCursor("msg")
    var m: Msg
    let r = kdlDecode(m, f.cursor)
    check r.isErr
    check r.getErr.code == peTypeNoVariantMatch

  # Gate: a branch carrying a seq child is rejected at macro time.
  test "untagged with a seq child branch is rejected (gate)":
    check not compiles((
      block:
        type Inner = object
          x {.kdlProp.}: int
        type Bad {.kdlNode: "bad", kdlUntagged.} = object
          case kind: bool
          of true:
            items {.kdlChild.}: seq[Inner]
          of false:
            n {.kdlProp.}: int
        deriveDecode(Bad)
    ))

  # Gate: Σ field counts > 20 is rejected at macro time.
  test "untagged exceeding 20 total branch fields is rejected (gate)":
    check not compiles((
      block:
        type Big {.kdlNode: "big", kdlUntagged.} = object
          case kind: bool
          of true:
            a01 {.kdlProp.}: int
            a02 {.kdlProp.}: int
            a03 {.kdlProp.}: int
            a04 {.kdlProp.}: int
            a05 {.kdlProp.}: int
            a06 {.kdlProp.}: int
            a07 {.kdlProp.}: int
            a08 {.kdlProp.}: int
            a09 {.kdlProp.}: int
            a10 {.kdlProp.}: int
            a11 {.kdlProp.}: int
          of false:
            b01 {.kdlProp.}: int
            b02 {.kdlProp.}: int
            b03 {.kdlProp.}: int
            b04 {.kdlProp.}: int
            b05 {.kdlProp.}: int
            b06 {.kdlProp.}: int
            b07 {.kdlProp.}: int
            b08 {.kdlProp.}: int
            b09 {.kdlProp.}: int
            b10 {.kdlProp.}: int
        deriveDecode(Big)
    ))

suite "derive_decode — exported (*) fields (regression: fieldInfo strips export postfix)":
  ## An exported field carries its name under an nnkPostfix (`foo*`); fieldInfo
  ## used to render `$node` as "foo*" and emit `undeclared field: 'foo*'` in the
  ## generated decoder. Every real-world config type exports its fields, yet no
  ## prior decode test did — this pins the fix (derive_common.bareFieldName).
  type SvExported {.kdlNode: "sv".} = object
    host* {.kdlProp.}: string
    port* {.kdlProp.}: int
    enabled* {.kdlProp.}: bool

  deriveDecode(SvExported)

  test "exported props decode":
    let f = mkCursor("sv host=\"a.b\" port=443 enabled=#true")
    var s: SvExported
    let r = kdlDecode(s, f.cursor)
    check r.isOk
    check s.host == "a.b"
    check s.port == 443
    check s.enabled == true
