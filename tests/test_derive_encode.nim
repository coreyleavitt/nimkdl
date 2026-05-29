## Tests for deriveEncode — per-type macro emitting kdlEncode procs.
##
## Cycles C1-C10 of the clean-core rebuild fill this out one shape at
## a time. Each test defines a type, derives kdlEncode, constructs a
## value, runs it through a BufferEmitter, and asserts the wire bytes.

import std/[options, unittest]

import ../src/derive_encode
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
