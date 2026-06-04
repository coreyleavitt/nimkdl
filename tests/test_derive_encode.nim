## Tests for deriveEncode — per-type macro emitting kdlEncode procs.
##
## Cycles C1-C10 of the clean-core rebuild fill this out one shape at
## a time. Each test defines a type, derives kdlEncode, constructs a
## value, runs it through a BufferEmitter, and asserts the wire bytes.

import std/[options, unittest, macros]

import ../src/derive_encode
import ../src/derive_decode  # S1 round-trip: encode → decode (re-exports cursor/lexer/spans)
import ../src/derive_common  # S2a: splitWords / toKebab oracle
import ../src/emitter
import ../src/pragmas

suite "derive_encode — C1: tracer (one kdlArg string field)":

  type Service {.kdlNode: "service".} = object
    name {.kdlArg.}: string

  deriveEncode(Service)

  test "single string kdlArg emits node + arg":
    var s = Service(name: "web")
    var e = newBufferEmitter()
    kdlEncode(s, e)
    check e.finish() == "service \"web\"\n"

suite "derive_encode — C2: multi-field typed args":

  type Edge {.kdlNode: "edge".} = object
    label {.kdlArg.}: string
    weight {.kdlArg.}: int
    bidir {.kdlArg.}: bool

  deriveEncode(Edge)

  test "string + int + bool emit in field order":
    var v = Edge(label: "hot", weight: 7, bidir: true)
    var e = newBufferEmitter()
    kdlEncode(v, e)
    check e.finish() == "edge \"hot\" 7 #true\n"

  type Pt {.kdlNode: "pt".} = object
    x {.kdlArg.}: float
    y {.kdlArg.}: float

  deriveEncode(Pt)

  test "two floats emit with .0 marker":
    var p = Pt(x: 1.5, y: 2.0)
    var e = newBufferEmitter()
    kdlEncode(p, e)
    check e.finish() == "pt 1.5 2.0\n"

  type Empty {.kdlNode: "empty".} = object

  deriveEncode(Empty)

  test "node with no fields emits bare name":
    var v = Empty()
    var e = newBufferEmitter()
    kdlEncode(v, e)
    check e.finish() == "empty\n"

suite "derive_encode — C3: kdlProp":

  type Sv {.kdlNode: "sv".} = object
    host {.kdlProp.}: string
    port {.kdlProp.}: int
    enabled {.kdlProp.}: bool

  deriveEncode(Sv)

  test "three typed props emit key=value in field order":
    var s = Sv(host: "a.b", port: 443, enabled: true)
    var e = newBufferEmitter()
    kdlEncode(s, e)
    check e.finish() == "sv host=\"a.b\" port=443 enabled=#true\n"

  type Mixed {.kdlNode: "mixed".} = object
    name {.kdlArg.}: string
    count {.kdlProp.}: int
    ratio {.kdlProp.}: float

  deriveEncode(Mixed)

  test "kdlArg before kdlProp emits in declaration order":
    var m = Mixed(name: "first", count: 3, ratio: 1.5)
    var e = newBufferEmitter()
    kdlEncode(m, e)
    check e.finish() == "mixed \"first\" count=3 ratio=1.5\n"

suite "derive_encode — C4: kdlChild single nested object":

  type Action {.kdlNode: "action".} = object
    kind {.kdlArg.}: string

  deriveEncode(Action)

  type Rule {.kdlNode: "rule".} = object
    id {.kdlArg.}: string
    action {.kdlChild.}: Action

  deriveEncode(Rule)

  test "kdlChild emits nested node inside children block":
    var r = Rule(id: "compaction", action: Action(kind: "inject"))
    var e = newBufferEmitter()
    kdlEncode(r, e)
    check e.finish() == "rule \"compaction\" {\n    action \"inject\"\n}\n"

  type Outer {.kdlNode: "outer".} = object
    a {.kdlChild.}: Action
    b {.kdlChild.}: Action

  deriveEncode(Outer)

  test "multiple kdlChild fields nest in field order":
    var o = Outer(a: Action(kind: "x"), b: Action(kind: "y"))
    var e = newBufferEmitter()
    kdlEncode(o, e)
    check e.finish() == "outer {\n    action \"x\"\n    action \"y\"\n}\n"

suite "derive_encode — C5: kdlChild seq[T]":

  type Item {.kdlNode: "item".} = object
    label {.kdlArg.}: string

  deriveEncode(Item)

  type Catalog {.kdlNode: "catalog".} = object
    items {.kdlChild.}: seq[Item]

  deriveEncode(Catalog)

  test "seq of child type emits one child node per element":
    var c = Catalog(items: @[Item(label: "a"), Item(label: "b"), Item(label: "c")])
    var e = newBufferEmitter()
    kdlEncode(c, e)
    check e.finish() == "catalog {\n    item \"a\"\n    item \"b\"\n    item \"c\"\n}\n"

  test "empty seq omits children block entirely":
    var c = Catalog(items: @[])
    var e = newBufferEmitter()
    kdlEncode(c, e)
    check e.finish() == "catalog\n"

  type Manifest {.kdlNode: "manifest".} = object
    name {.kdlArg.}: string
    contents {.kdlChild.}: seq[Item]

  deriveEncode(Manifest)

  test "kdlArg before kdlChild seq":
    var m = Manifest(name: "n", contents: @[Item(label: "x")])
    var e = newBufferEmitter()
    kdlEncode(m, e)
    check e.finish() == "manifest \"n\" {\n    item \"x\"\n}\n"

suite "derive_encode — C6: self-recursive Tree (closes #11 by construction)":

  type Tree {.kdlNode: "tree".} = object
    value {.kdlArg.}: string
    children {.kdlChild.}: seq[Tree]

  deriveEncode(Tree)

  test "single leaf — depth 1":
    var t = Tree(value: "root")
    var e = newBufferEmitter()
    kdlEncode(t, e)
    check e.finish() == "tree \"root\"\n"

  test "depth 2 — root with two leaves":
    var t = Tree(value: "root", children: @[Tree(value: "a"), Tree(value: "b")])
    var e = newBufferEmitter()
    kdlEncode(t, e)
    check e.finish() == "tree \"root\" {\n    tree \"a\"\n    tree \"b\"\n}\n"

  test "depth 3 — the #11 structural test":
    var t = Tree(
      value: "L1",
      children: @[
        Tree(value: "L2a",
             children: @[Tree(value: "L3a"), Tree(value: "L3b")]),
        Tree(value: "L2b"),
      ])
    var e = newBufferEmitter()
    kdlEncode(t, e)
    check e.finish() == (
      "tree \"L1\" {\n" &
      "    tree \"L2a\" {\n" &
      "        tree \"L3a\"\n" &
      "        tree \"L3b\"\n" &
      "    }\n" &
      "    tree \"L2b\"\n" &
      "}\n"
    )

  test "linear chain — depth 5":
    var t = Tree(value: "1", children: @[
      Tree(value: "2", children: @[
        Tree(value: "3", children: @[
          Tree(value: "4", children: @[
            Tree(value: "5"),
          ]),
        ]),
      ]),
    ])
    var e = newBufferEmitter()
    kdlEncode(t, e)
    check e.finish() == (
      "tree \"1\" {\n" &
      "    tree \"2\" {\n" &
      "        tree \"3\" {\n" &
      "            tree \"4\" {\n" &
      "                tree \"5\"\n" &
      "            }\n" &
      "        }\n" &
      "    }\n" &
      "}\n"
    )

suite "derive_encode — C7: Option[T] arg / prop / child":

  type Config {.kdlNode: "config".} = object
    timeout {.kdlProp.}: Option[int]
    label {.kdlProp.}: Option[string]

  deriveEncode(Config)

  test "Option[T] kdlProp emits when Some":
    var c = Config(timeout: some(30), label: some("staging"))
    var e = newBufferEmitter()
    kdlEncode(c, e)
    check e.finish() == "config timeout=30 label=\"staging\"\n"

  test "Option[T] kdlProp omits when None":
    var c = Config(timeout: some(30), label: none(string))
    var e = newBufferEmitter()
    kdlEncode(c, e)
    check e.finish() == "config timeout=30\n"

  test "all Option[T] None emits bare node":
    var c = Config()
    var e = newBufferEmitter()
    kdlEncode(c, e)
    check e.finish() == "config\n"

  type Note {.kdlNode: "note".} = object
    text {.kdlArg.}: Option[string]

  deriveEncode(Note)

  test "Option[T] kdlArg emits when Some, omits when None":
    var n1 = Note(text: some("hi"))
    var e1 = newBufferEmitter()
    kdlEncode(n1, e1)
    check e1.finish() == "note \"hi\"\n"
    var n2 = Note(text: none(string))
    var e2 = newBufferEmitter()
    kdlEncode(n2, e2)
    check e2.finish() == "note\n"

  type Detail {.kdlNode: "detail".} = object
    name {.kdlArg.}: string

  deriveEncode(Detail)

  type Wrapper {.kdlNode: "wrapper".} = object
    payload {.kdlChild.}: Option[Detail]

  deriveEncode(Wrapper)

  test "Option[T] kdlChild emits when Some":
    var w = Wrapper(payload: some(Detail(name: "x")))
    var e = newBufferEmitter()
    kdlEncode(w, e)
    check e.finish() == "wrapper {\n    detail \"x\"\n}\n"

  test "Option[T] kdlChild None omits children block":
    var w = Wrapper(payload: none(Detail))
    var e = newBufferEmitter()
    kdlEncode(w, e)
    check e.finish() == "wrapper\n"

suite "derive_encode — C8: enum fields":

  type ActionKind = enum
    akInject = "inject"
    akDeny = "deny"
    akAllow = "allow"

  type Action2 {.kdlNode: "action".} = object
    kind {.kdlArg.}: ActionKind

  deriveEncode(Action2)

  test "enum field with explicit string mapping emits the string":
    var a = Action2(kind: akInject)
    var e = newBufferEmitter()
    kdlEncode(a, e)
    check e.finish() == "action \"inject\"\n"

  test "second enum variant emits its mapped string":
    var a = Action2(kind: akDeny)
    var e = newBufferEmitter()
    kdlEncode(a, e)
    check e.finish() == "action \"deny\"\n"

  type Status = enum
    sOk
    sFailed

  type Job {.kdlNode: "job".} = object
    state {.kdlProp.}: Status

  deriveEncode(Job)

  test "plain enum (no string mapping) emits symbol name":
    var j = Job(state: sOk)
    var e = newBufferEmitter()
    kdlEncode(j, e)
    check e.finish() == "job state=\"sOk\"\n"

  type Severity = enum
    sevLow = "low"
    sevHigh = "high"

  type Alert {.kdlNode: "alert".} = object
    name {.kdlArg.}: string
    threshold {.kdlProp.}: Option[Severity]

  deriveEncode(Alert)

  test "Option[Enum] kdlProp emits when Some":
    var a = Alert(name: "disk", threshold: some(sevHigh))
    var e = newBufferEmitter()
    kdlEncode(a, e)
    check e.finish() == "alert \"disk\" threshold=\"high\"\n"

  test "Option[Enum] kdlProp omits when None":
    var a = Alert(name: "disk", threshold: none(Severity))
    var e = newBufferEmitter()
    kdlEncode(a, e)
    check e.finish() == "alert \"disk\"\n"

suite "derive_encode — C9: variant (case object)":

  type Effect = enum
    efDeny = "deny"
    efAllow = "allow"

  type Action9 {.kdlNode: "action".} = object
    case kind {.kdlArg.}: Effect
    of efDeny:
      reason {.kdlProp.}: string
    of efAllow:
      quota {.kdlProp.}: int

  deriveEncode(Action9)

  test "variant — efDeny branch emits its branch field":
    var a = Action9(kind: efDeny, reason: "blocked")
    var e = newBufferEmitter()
    kdlEncode(a, e)
    check e.finish() == "action \"deny\" reason=\"blocked\"\n"

  test "variant — efAllow branch emits its different branch field":
    var a = Action9(kind: efAllow, quota: 1000)
    var e = newBufferEmitter()
    kdlEncode(a, e)
    check e.finish() == "action \"allow\" quota=1000\n"

  type Shape = enum
    skCircle = "circle"
    skSquare = "square"
    skEmpty = "empty"

  type Drawing {.kdlNode: "drawing".} = object
    case kind {.kdlArg.}: Shape
    of skCircle:
      radius {.kdlProp.}: float
    of skSquare:
      side {.kdlProp.}: float
    of skEmpty:
      discard  # branch with no fields

  deriveEncode(Drawing)

  test "variant — branch with no fields emits only discriminator":
    var d = Drawing(kind: skEmpty)
    var e = newBufferEmitter()
    kdlEncode(d, e)
    check e.finish() == "drawing \"empty\"\n"

  test "variant — circle branch":
    var d = Drawing(kind: skCircle, radius: 1.5)
    var e = newBufferEmitter()
    kdlEncode(d, e)
    check e.finish() == "drawing \"circle\" radius=1.5\n"

suite "derive_encode — C10: kdlReserved + kdlRename + P8 determinism":

  type Host {.kdlNode: "host".} = object
    addr1 {.kdlArg, kdlReserved: "ipv4".}: string
    port {.kdlProp, kdlReserved: "u16".}: int

  deriveEncode(Host)

  test "kdlReserved on kdlArg emits (tag) before value":
    var h = Host(addr1: "10.0.0.1", port: 80)
    var e = newBufferEmitter()
    kdlEncode(h, e)
    check e.finish() == "host (ipv4)\"10.0.0.1\" port=(u16)80\n"

  type Cfg {.kdlNode: "cfg".} = object
    tmpl {.kdlProp, kdlRename: "template".}: string

  deriveEncode(Cfg)

  test "kdlRename substitutes wire name":
    var c = Cfg(tmpl: "default")
    var e = newBufferEmitter()
    kdlEncode(c, e)
    check e.finish() == "cfg template=\"default\"\n"

  test "P8 — encoding the same value twice produces identical bytes":
    type Svc {.kdlNode: "svc".} = object
      name {.kdlArg.}: string
      port {.kdlProp.}: int
    deriveEncode(Svc)
    var s = Svc(name: "web", port: 80)
    var e1 = newBufferEmitter()
    var e2 = newBufferEmitter()
    kdlEncode(s, e1)
    kdlEncode(s, e2)
    check e1.finish() == e2.finish()

suite "deriveEncode — ckRef: ref object as the user-facing type (#9)":

  type RefSvc {.kdlNode: "rsvc".} = ref object
    name {.kdlArg.}: string
    port {.kdlProp.}: int

  deriveEncode(RefSvc)

  test "ref object encodes through deref":
    var s = RefSvc(name: "web", port: 8)
    var e = newBufferEmitter()
    kdlEncode(s, e)
    check e.finish() == "rsvc \"web\" port=8\n"

suite "deriveEncode — type aliases resolve to base primitive (#39 item 5)":

  type Port = int
  type Name = string
  type AliasHost {.kdlNode: "ahost".} = object
    title {.kdlArg.}: Name
    port {.kdlProp.}: Port

  deriveEncode(AliasHost)

  test "aliased arg + prop encode through the underlying primitive":
    var h = AliasHost(title: "web", port: 8)
    var e = newBufferEmitter()
    kdlEncode(h, e)
    check e.finish() == "ahost \"web\" port=8\n"

suite "derive_encode — S0c: no-pragma field inference (mirrors decode classify)":

  # A primitive field with NO routing pragma must infer to a prop (key =
  # field name), symmetric with decode's classify inference. Before S0c,
  # encode's dispatchField had no else-branch and silently DROPPED such a
  # field from the output.

  type Doc {.kdlNode: "doc".} = object
    title {.kdlArg.}: string
    count: int            # no pragma → inferred prop

  deriveEncode(Doc)

  test "no-pragma primitive field encodes as inferred prop":
    var d = Doc(title: "hello", count: 5)
    var e = newBufferEmitter()
    kdlEncode(d, e)
    check e.finish() == "doc \"hello\" count=5\n"

  type Section {.kdlNode: "section".} = object
    name {.kdlArg.}: string

  deriveEncode(Section)

  type Book {.kdlNode: "book".} = object
    section: Section      # no pragma, object → inferred child

  deriveEncode(Book)

  test "no-pragma object field infers a child":
    var b = Book(section: Section(name: "intro"))
    var e = newBufferEmitter()
    kdlEncode(b, e)
    check e.finish() == "book {\n    section \"intro\"\n}\n"

  type Library {.kdlNode: "library".} = object
    sections: seq[Section]   # no pragma, seq[object] → inferred child-seq

  deriveEncode(Library)

  test "no-pragma seq-of-object field infers a child-seq":
    var l = Library(sections: @[Section(name: "a"), Section(name: "b")])
    var e = newBufferEmitter()
    kdlEncode(l, e)
    check e.finish() == "library {\n    section \"a\"\n    section \"b\"\n}\n"

import std/strutils

suite "derive_encode — kdlScalar custom hook (rfc §8 KdlValue interchange)":

  type Color = object
    r, g, b: uint8

  proc kdlEncodeValue(c: Color): KdlValue =
    newKdlString("#" & toLowerAscii(toHex(c.r.int, 2) & toHex(c.g.int, 2) &
                                    toHex(c.b.int, 2)))

  type Paint {.kdlNode: "paint".} = object
    color {.kdlScalar.}: Color

  deriveEncode(Paint)

  test "kdlScalar prop encodes via hook as a string value":
    var p = Paint(color: Color(r: 255, g: 128, b: 0))
    var e = newBufferEmitter()
    kdlEncode(p, e)
    check e.finish() == "paint color=\"#ff8000\"\n"

  # A kdlEncodeValue returning a NUMERIC KdlValue emits a bare number — the
  # value-typed push (not pushArgString) is what makes typed scalars possible.
  type Duration = object
    millis: int64

  proc kdlEncodeValue(d: Duration): KdlValue = newKdlInt(d.millis)

  type Timeout {.kdlNode: "timeout".} = object
    after {.kdlScalar.}: Duration

  deriveEncode(Timeout)

  test "kdlScalar hook returning kvInt emits a bare integer":
    var t = Timeout(after: Duration(millis: 500))
    var e = newBufferEmitter()
    kdlEncode(t, e)
    check e.finish() == "timeout after=500\n"

suite "derive_encode — S1: kdlVariadic (variadic positional args)":

  type Cmd {.kdlNode: "cmd".} = object
    name {.kdlArg.}: string
    rest {.kdlVariadic.}: seq[string]

  deriveEncode(Cmd)
  deriveDecode(Cmd)

  test "fixed arg emits first, then each variadic element in order":
    var c = Cmd(name: "run", rest: @["a", "b", "c"])
    var e = newBufferEmitter()
    kdlEncode(c, e)
    check e.finish() == "cmd \"run\" \"a\" \"b\" \"c\"\n"

  test "empty variadic seq emits only the fixed arg":
    var c = Cmd(name: "run", rest: @[])
    var e = newBufferEmitter()
    kdlEncode(c, e)
    check e.finish() == "cmd \"run\"\n"

  test "round-trips encode → decode":
    var c = Cmd(name: "run", rest: @["a", "b", "c"])
    var e = newBufferEmitter()
    kdlEncode(c, e)
    let wire = e.finish()
    check wire == "cmd \"run\" \"a\" \"b\" \"c\"\n"
    var sref: ref TokenStream
    new(sref)
    sref[] = lex(wire)
    var cur = initStringCursor(addr sref[], wire)
    var back: Cmd
    let r = kdlDecode(back, cur)
    check r.isOk
    check back.name == "run"
    check back.rest == @["a", "b", "c"]

  type Nums {.kdlNode: "nums".} = object
    vals {.kdlVariadic.}: seq[int]

  deriveEncode(Nums)

  test "variadic of int elements emits bare numbers":
    var n = Nums(vals: @[1, 2, 3])
    var e = newBufferEmitter()
    kdlEncode(n, e)
    check e.finish() == "nums 1 2 3\n"

suite "derive_encode — S1: kdlVariadic macro-error guards":

  test "well-formed variadic encode compiles (sanity)":
    check compiles((
      block:
        type Ok {.kdlNode: "ok".} = object
          head {.kdlArg.}: string
          tail {.kdlVariadic.}: seq[string]
        deriveEncode(Ok)
    ))

  test "a fixed {.kdlArg.} declared after {.kdlVariadic.} is rejected":
    # Required fixed-then-variadic invariant (rfc S1): an arg after the
    # variadic would interleave on the wire and break round-trips.
    check not compiles((
      block:
        type Bad {.kdlNode: "bad".} = object
          tail {.kdlVariadic.}: seq[string]
          trailing {.kdlArg.}: string
        deriveEncode(Bad)
    ))

  test "{.kdlArg.} on a seq field is rejected on encode too":
    check not compiles((
      block:
        type Bad {.kdlNode: "bad".} = object
          tags {.kdlArg.}: seq[string]
        deriveEncode(Bad)
    ))

suite "derive_encode — S2a: acronym-aware default node name (BREAKING)":

  # End-to-end: a type with NO {.kdlNode.} falls back to acronym-aware
  # kebab. Pre-S2a this emitted `httpserver`; now `http-server`.
  type HTTPServer = object
    name {.kdlArg.}: string

  deriveEncode(HTTPServer)

  test "HTTPServer (no kdlNode) emits node name http-server, not httpserver":
    var v = HTTPServer(name: "web")
    var e = newBufferEmitter()
    kdlEncode(v, e)
    check e.finish() == "http-server \"web\"\n"

  test "splitWords / toKebab oracle table (S2a)":
    static:
      doAssert toKebab(splitWords("HTTPServer")) == "http-server"
      doAssert toKebab(splitWords("MyService"))  == "my-service"
      doAssert toKebab(splitWords("Service"))    == "service"
      doAssert toKebab(splitWords("IOError"))    == "io-error"
      doAssert toKebab(splitWords("A"))          == "a"
      doAssert toKebab(splitWords("Service2"))   == "service2"

  test "splitWords boundary cases (S2a engine)":
    static:
      doAssert splitWords("HTTPServer") == @["HTTP", "Server"]
      doAssert splitWords("myService")  == @["my", "Service"]
      doAssert splitWords("IOError")    == @["IO", "Error"]
      doAssert splitWords("Service2")   == @["Service2"]
      doAssert splitWords("A")          == @["A"]
      doAssert splitWords("")           == newSeq[string]()

suite "derive_common — S2b: case engine joins (maxRetries → each convention)":

  test "case-engine join tables":
    static:
      let w = splitWords("maxRetries")
      doAssert w == @["max", "Retries"]
      doAssert toKebab(w)          == "max-retries"
      doAssert toCamel(w)          == "maxRetries"
      doAssert toSnake(w)          == "max_retries"
      doAssert toPascal(w)         == "MaxRetries"
      doAssert toScreamingSnake(w) == "MAX_RETRIES"

  test "acronym-bearing name through each convention":
    static:
      let w = splitWords("HTTPServer")  # ["HTTP", "Server"]
      doAssert toKebab(w)          == "http-server"
      doAssert toCamel(w)          == "httpServer"
      doAssert toSnake(w)          == "http_server"
      doAssert toPascal(w)         == "HttpServer"
      doAssert toScreamingSnake(w) == "HTTP_SERVER"

  test "single-word names":
    static:
      let w = splitWords("port")  # ["port"]
      doAssert toKebab(w)          == "port"
      doAssert toCamel(w)          == "port"
      doAssert toSnake(w)          == "port"
      doAssert toPascal(w)         == "Port"
      doAssert toScreamingSnake(w) == "PORT"

suite "derive_common — S2b: wireKeyOf resolver (§3.5.3)":

  test "no pragma, no convention → field name verbatim":
    static:
      doAssert wireKeyOf("maxRetries", @[], "") == "maxRetries"
      doAssert wireKeyOf("maxRetries", @[], "kcVerbatim") == "maxRetries"

  test "convention applied to field name when no kdlRename":
    static:
      doAssert wireKeyOf("maxRetries", @[], "kcKebabCase") == "max-retries"
      doAssert wireKeyOf("maxRetries", @[], "kcSnakeCase") == "max_retries"
      doAssert wireKeyOf("maxRetries", @[], "kcCamelCase") == "maxRetries"
      doAssert wireKeyOf("maxRetries", @[], "kcPascalCase") == "MaxRetries"
      doAssert wireKeyOf("maxRetries", @[], "kcScreamingSnakeCase") == "MAX_RETRIES"

  test "kdlRename WINS over convention":
    static:
      # build a {.kdlRename: "keep".} pragma node
      let renamePragma = nnkExprColonExpr.newTree(ident("kdlRename"),
                                                  newLit("keep"))
      doAssert wireKeyOf("maxRetries", @[renamePragma], "kcKebabCase") == "keep"
      doAssert wireKeyOf("maxRetries", @[renamePragma], "kcScreamingSnakeCase") == "keep"

suite "derive_encode — S2b: kdlRenameAll convention applied to prop keys":

  type RetryCfg {.kdlNode: "retry", kdlRenameAll: kcKebabCase.} = object
    maxRetries {.kdlProp.}: int

  deriveEncode(RetryCfg)

  test "kdlRenameAll: kcKebabCase encodes max-retries":
    var v = RetryCfg(maxRetries: 3)
    var e = newBufferEmitter()
    kdlEncode(v, e)
    check e.finish() == "retry max-retries=3\n"

  type RetryScream {.kdlNode: "retry", kdlRenameAll: kcScreamingSnakeCase.} = object
    maxRetries {.kdlProp.}: int

  deriveEncode(RetryScream)

  test "kdlRenameAll: kcScreamingSnakeCase encodes MAX_RETRIES":
    var v = RetryScream(maxRetries: 3)
    var e = newBufferEmitter()
    kdlEncode(v, e)
    check e.finish() == "retry MAX_RETRIES=3\n"

  type RetryKeep {.kdlNode: "retry", kdlRenameAll: kcKebabCase.} = object
    maxRetries {.kdlProp, kdlRename: "keep".}: int

  deriveEncode(RetryKeep)

  test "kdlRename overrides kdlRenameAll on encode":
    var v = RetryKeep(maxRetries: 3)
    var e = newBufferEmitter()
    kdlEncode(v, e)
    check e.finish() == "retry keep=3\n"

  # The node name must NOT be convention-transformed. This type has no
  # explicit kdlNode; with kdlRenameAll active the node name must still
  # come from nodeNameOf (its own kebab fallback), unaffected by the prop
  # convention.
  type MultiWordNode {.kdlRenameAll: kcScreamingSnakeCase.} = object
    maxRetries {.kdlProp.}: int

  deriveEncode(MultiWordNode)

  test "kdlRenameAll does not affect the node name":
    var v = MultiWordNode(maxRetries: 3)
    var e = newBufferEmitter()
    kdlEncode(v, e)
    # node name stays multi-word-node (nodeNameOf kebab), prop screams.
    check e.finish() == "multi-word-node MAX_RETRIES=3\n"

suite "derive_encode — S7: directional skip (kdlSkipEncode)":

  type SkipEProp {.kdlNode: "sep".} = object
    name {.kdlArg.}: string
    secret {.kdlSkipEncode, kdlProp.}: string

  deriveEncode(SkipEProp)

  test "kdlSkipEncode prop emits nothing — output omits the field":
    var v = SkipEProp(name: "web", secret: "leaked")
    var e = newBufferEmitter()
    kdlEncode(v, e)
    let s = e.finish()
    check s == "sep \"web\"\n"
    check "secret" notin s
    check "leaked" notin s

  type Leaf {.kdlNode: "leaf".} = object
    label {.kdlArg.}: string
  deriveEncode(Leaf)

  type SkipEChild {.kdlNode: "sec".} = object
    name {.kdlArg.}: string
    inner {.kdlSkipEncode, kdlChild.}: Leaf

  deriveEncode(SkipEChild)

  test "kdlSkipEncode child emits nothing":
    var v = SkipEChild(name: "web", inner: Leaf(label: "x"))
    var e = newBufferEmitter()
    kdlEncode(v, e)
    let s = e.finish()
    check s == "sec \"web\"\n"
    check "leaf" notin s

  type SkipBothE {.kdlNode: "sbe".} = object
    name {.kdlArg.}: string
    hidden {.kdlSkip, kdlProp.}: string

  deriveEncode(SkipBothE)

  test "kdlSkip (both) emits nothing on encode":
    var v = SkipBothE(name: "web", hidden: "x")
    var e = newBufferEmitter()
    kdlEncode(v, e)
    check e.finish() == "sbe \"web\"\n"

suite "derive_encode — S7: kdlSkipEncode + kdlArg is a compile error":

  test "a valid skipEncode-on-prop type compiles (sanity)":
    check compiles((
      block:
        type Ok {.kdlNode: "ok".} = object
          a {.kdlArg.}: string
          b {.kdlSkipEncode, kdlProp.}: string
        deriveEncode(Ok)
    ))

  test "kdlSkipEncode on a positional kdlArg field is rejected":
    check not compiles((
      block:
        type Bad {.kdlNode: "bad".} = object
          a {.kdlArg.}: string
          weight {.kdlSkipEncode, kdlArg.}: int
        deriveEncode(Bad)
    ))

  test "kdlSkip (both) on a kdlArg field is allowed (symmetric drop)":
    check compiles((
      block:
        type Ok2 {.kdlNode: "ok2".} = object
          a {.kdlArg.}: string
          weight {.kdlSkip, kdlArg.}: int
        deriveEncode(Ok2)
    ))

suite "derive_encode — S8b: kdlFlatten encode (mirror of S8a decode)":

  # Mirror of the S8a deriveDecode flatten tests, on the encode side: the
  # flattened object's args/props emit INLINE on the parent (no child node).
  type Meta = object
    author {.kdlProp.}: string
    version {.kdlProp.}: int

  type Doc {.kdlNode: "doc".} = object
    title {.kdlArg.}: string
    meta {.kdlFlatten.}: Meta

  deriveEncode(Doc)
  deriveDecode(Doc)

  test "flattened props emit inline on the parent node":
    var d = Doc(title: "t", meta: Meta(author: "me", version: 2))
    var e = newBufferEmitter()
    kdlEncode(d, e)
    check e.finish() == "doc \"t\" author=\"me\" version=2\n"

  test "flatten encode round-trips":
    let d0 = Doc(title: "t", meta: Meta(author: "me", version: 2))
    var e = newBufferEmitter()
    kdlEncode(d0, e)
    let bytes = e.finish()
    var sref: ref TokenStream
    new(sref)
    sref[] = lex(bytes)
    var c = initStringCursor(addr sref[], bytes)
    var d1: Doc
    check kdlDecode(d1, c).isOk
    check d1.title == "t"
    check d1.meta.author == "me"
    check d1.meta.version == 2

  # Flattened positional args stay contiguous with the parent's fixed args.
  type Coords = object
    x {.kdlArg.}: int
    y {.kdlArg.}: int

  type Placed {.kdlNode: "placed".} = object
    label {.kdlArg.}: string
    at {.kdlFlatten.}: Coords
    tail {.kdlArg.}: int

  deriveEncode(Placed)

  test "flattened args emit contiguously between the parent's fixed args":
    var p = Placed(label: "p", at: Coords(x: 10, y: 20), tail: 99)
    var e = newBufferEmitter()
    kdlEncode(p, e)
    check e.finish() == "placed \"p\" 10 20 99\n"

  # A flattened object that itself contains a {.kdlChild.} sub-field: the
  # child emits in the parent's children block via the threaded compound base.
  type Item {.kdlNode: "item".} = object
    label {.kdlArg.}: string

  type Bundle = object
    note {.kdlProp.}: string
    item {.kdlChild.}: Item

  type Crate {.kdlNode: "crate".} = object
    id {.kdlArg.}: string
    bundle {.kdlFlatten.}: Bundle

  deriveEncode(Item)   # the flattened child's element type needs its own encoder
  deriveEncode(Crate)

  test "flattened child sub-field emits through the compound base":
    var cr = Crate(id: "c1", bundle: Bundle(note: "n", item: Item(label: "x")))
    var e = newBufferEmitter()
    kdlEncode(cr, e)
    check e.finish() == "crate \"c1\" note=\"n\" {\n    item \"x\"\n}\n"

suite "derive_encode — S9: untagged variants ({.kdlUntagged.})":

  type Payload9 = enum
    plText9 = "text"
    plNum9 = "num"

  type Msg9 {.kdlNode: "msg", kdlUntagged.} = object
    case kind: Payload9
    of plText9:
      body {.kdlProp.}: string
    of plNum9:
      value {.kdlProp.}: int

  deriveEncode(Msg9)
  deriveDecode(Msg9)

  test "untagged encode — text branch emits its prop, no discriminator on wire":
    var m = Msg9(kind: plText9, body: "hi")
    var e = newBufferEmitter()
    kdlEncode(m, e)
    check e.finish() == "msg body=\"hi\"\n"

  test "untagged encode — num branch emits its prop, no discriminator on wire":
    var m = Msg9(kind: plNum9, value: 42)
    var e = newBufferEmitter()
    kdlEncode(m, e)
    check e.finish() == "msg value=42\n"

  proc roundtrip9(src: string): Msg9 =
    var sref: ref TokenStream
    new(sref)
    sref[] = lex(src)
    var c = initStringCursor(addr sref[], src)
    let r = kdlDecode(result, c)
    check r.isOk

  test "untagged round-trip — text branch":
    let m = roundtrip9("msg body=\"hello\"")
    check m.kind == plText9
    check m.body == "hello"
    var e = newBufferEmitter()
    kdlEncode(m, e)
    check e.finish() == "msg body=\"hello\"\n"

  test "untagged round-trip — num branch":
    let m = roundtrip9("msg value=7")
    check m.kind == plNum9
    check m.value == 7
    var e = newBufferEmitter()
    kdlEncode(m, e)
    check e.finish() == "msg value=7\n"
