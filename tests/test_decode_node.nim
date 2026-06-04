## test_decode_node.nim — `decodeNode[T](doc, node)` source-slice + rebase
## (rfc-consumer-api N2, the centerpiece).
##
## A parsed node carries `span = [offset, length)` into `doc.sourceText` (S1).
## `decodeNode` slices the node's verbatim original bytes and feeds them to the
## ONE decoder un-enriched, then `rebased` the error offset into the full doc
## and `enriched`es it — so a type error in node `i` of a MULTI-node source
## reports the true file line/col, not a slice-local position (§4.4 enrichment
## order, §9 item 3 rebasing correctness).
##
## A hand-built node (`span.length == 0`) falls back to `reEmitDecodeNode`
## (re-emit then decode).

import std/unittest
import std/options
import std/strutils

import ../src/api
import ../src/parser
import ../src/node
import ../src/node_build   # newNode / addArg / addProp builders for hand-built nodes
import ../src/value
import ../src/kdl_block
import ../src/pragmas
import ../src/spans        # Result / ok / err for the kdlScalar hook

# A custom scalar type for the N2f re-emit round-trip hazard pin. The hook pair
# must be in scope before the `kdl:` block so the derive macro wires it.
type Hue = object
  v: uint8

proc kdlEncodeValue(h: Hue): KdlValue = newKdlInt(int64(h.v))
proc kdlDecodeValue(val: KdlValue, T: typedesc[Hue]): Result[Hue, string] =
  case val.kind
  of kvInt: ok[Hue, string](Hue(v: uint8(val.intVal)))
  else:     err[Hue, string]("expected integer hue")

kdl:
  type Daemon {.kdlNode: "daemon".} = object
    name {.kdlArg.}: string
    port {.kdlProp.}: int

  type Permissions {.kdlNode: "permissions".} = object
    mode {.kdlArg.}: string

  # N2f round-trip hazard fixtures (rfc §8 N2f): Option/none + kdlScalar.
  type Server {.kdlNode: "server".} = object
    host {.kdlArg.}: string
    label {.kdlProp.}: Option[string]   # absent → none; present → some
    port {.kdlProp.}: Option[int]

  type Swatch {.kdlNode: "swatch".} = object
    shade {.kdlScalar, kdlProp.}: Hue   # custom scalar through the re-emit path

proc parseDoc(src: string): KdlDoc =
  let r = parse(src)
  check r.isOk
  r.get

suite "decodeNode[T](doc, node) — slice path (parsed nodes)":

  test "well-typed node in a heterogeneous multi-node doc decodes":
    let src = "daemon \"web\" port=80\npermissions \"rw\"\n"
    let d = parseDoc(src)
    let dae = decodeNode[Daemon](d, d.nodes[0])
    check dae.isOk
    check dae.get.name == "web"
    check dae.get.port == 80
    let perm = decodeNode[Permissions](d, d.nodes[1])
    check perm.isOk
    check perm.get.mode == "rw"

  test "name-check fires: decodeNode[Daemon] on a non-'daemon' node errors":
    let src = "daemon \"web\" port=80\npermissions \"rw\"\n"
    let d = parseDoc(src)
    let r = decodeNode[Daemon](d, d.nodes[1])  # node is 'permissions'
    check r.isErr

suite "decodeNode error rebasing — absolute file position":

  test "type mismatch in node i of a multi-node source reports ORIGINAL line/col":
    # daemon is well-formed; permissions has a non-string mode (int) — the type
    # error lives on line 2. If enrichment ran on the slice (slice-local), the
    # error would report line 1. The rebase-then-enrich order must report line 2.
    let src = "daemon \"web\" port=80\n" &
              "permissions 123\n"
    let d = parseDoc(src)
    let r = decodeNode[Permissions](d, d.nodes[1])
    check r.isErr
    let e = r.getErr
    check e.line == 2          # ORIGINAL file line, not slice-local line 1
    check e.sourcePath == d.sourcePath
    # the absolute span offset lands inside line 2 of the full source
    check e.span.offset >= len("daemon \"web\" port=80\n")

  test "rebase is correct deeper into the doc (third node, multi-line)":
    let src = "permissions \"rw\"\n" &
              "daemon \"a\" port=1\n" &
              "daemon \"b\" port=\"oops\"\n"   # port wants int, gets string → line 3
    let d = parseDoc(src)
    let r = decodeNode[Daemon](d, d.nodes[2])
    check r.isErr
    check r.getErr.line == 3

suite "decodeNode cross-check (§8 N2)":

  test "decodeNode equals decode of the node's source slice":
    let src = "daemon \"web\" port=80\npermissions \"rw\"\n"
    let d = parseDoc(src)
    let n = d.nodes[0]
    let slice = d.sourceText[n.span.offset ..< n.span.offset + n.span.length]
    let viaNode = decodeNode[Daemon](d, n)
    let viaSlice = decode[Daemon](slice)
    check viaNode.isOk
    check viaSlice.isOk
    check viaNode.get == viaSlice.get

  test "decodeNode equals whole-source decode of a single-node doc":
    let src = "daemon \"web\" port=80\n"
    let d = parseDoc(src)
    let viaNode = decodeNode[Daemon](d, d.nodes[0])
    let viaWhole = decode[Daemon](src)
    check viaNode.isOk and viaWhole.isOk
    check viaNode.get == viaWhole.get

suite "decodeNode — hand-built node re-emit fallback":

  test "a hand-built node (span.length == 0) decodes via re-emit":
    let n = newNode("daemon")
    check n.span.length == 0
    n.addArg(newKdlString("web"))
    n.setProp("port", newKdlInt(80))
    let r = decodeNode[Daemon](newDoc(), n)
    check r.isOk
    check r.get.name == "web"
    check r.get.port == 80

  test "reEmitDecodeNode helper decodes a hand-built node directly":
    let n = newNode("permissions")
    n.addArg(newKdlString("ro"))
    let r = reEmitDecodeNode[Permissions](n)
    check r.isOk
    check r.get.mode == "ro"

suite "decodeNode[T](node) — bare doc-less overload (N2f)":

  test "bare overload on a hand-built node returns the right value":
    # No doc, no source span — the overload routes through reEmitDecodeNode.
    let n = newNode("daemon")
    check n.span.length == 0
    n.addArg(newKdlString("web"))
    n.setProp("port", newKdlInt(80))
    let r = decodeNode[Daemon](n)   # <-- the N2f overload (no doc arg)
    check r.isOk
    check r.get.name == "web"
    check r.get.port == 80

  test "bare overload agrees with the (doc, node) hand-built fallback":
    let n = newNode("permissions")
    n.addArg(newKdlString("rw"))
    let viaBare = decodeNode[Permissions](n)
    let viaDoc  = decodeNode[Permissions](newDoc(), n)  # span.length==0 → same path
    check viaBare.isOk and viaDoc.isOk
    check viaBare.get == viaDoc.get

suite "decodeNode[T](node) re-emit round-trip hazard pins (§8 N2f)":
  # These pin the depth-flagged hazards confined to the re-emit path: a value
  # built programmatically must survive encode(node) → decode[T] unchanged.

  test "annotation hazard: an annotated arg value round-trips through re-emit":
    # The arg carries a (type) annotation; the canonical emitter must requote it
    # so the re-decoded value is identical. The derive vocab reads the value
    # regardless of annotation, so the pin is that re-emit preserves the value.
    let n = newNode("daemon")
    var v = newKdlString("web")
    v.typeAnnotation = some("hostname")   # annotated arg: (hostname)"web"
    n.addArg(v)
    n.setProp("port", newKdlInt(80))
    let r = decodeNode[Daemon](n)
    check r.isOk
    check r.get.name == "web"
    check r.get.port == 80

  test "Option-none hazard: an absent Option prop materializes as none via re-emit":
    let n = newNode("server")
    n.addArg(newKdlString("localhost"))
    # label + port deliberately absent → must re-emit to no prop → decode to none
    let r = decodeNode[Server](n)
    check r.isOk
    check r.get.host == "localhost"
    check r.get.label == none(string)
    check r.get.port == none(int)

  test "Option-some hazard: a present Option prop materializes as some via re-emit":
    let n = newNode("server")
    n.addArg(newKdlString("localhost"))
    n.setProp("label", newKdlString("primary"))
    n.setProp("port", newKdlInt(8080))
    let r = decodeNode[Server](n)
    check r.isOk
    check r.get.label == some("primary")
    check r.get.port == some(8080)

  test "kdlScalar hazard: a custom-scalar prop round-trips through the hook + re-emit":
    let n = newNode("swatch")
    n.setProp("shade", newKdlInt(200))   # hook decodes int → Hue(v: 200)
    let r = decodeNode[Swatch](n)
    check r.isOk
    check r.get.shade == Hue(v: 200)

suite "decodeChild[T](doc, parent, childName) — first-wins child decode (N3)":

  test "decodes the named child of a parent node to T":
    let src = "service {\n" &
              "  daemon \"web\" port=80\n" &
              "}\n"
    let d = parseDoc(src)
    let parent = d.nodes[0]
    let r = decodeChild[Daemon](d, parent, "daemon")
    check r.isOk
    check r.get.name == "web"
    check r.get.port == 80

  test "first-wins: duplicate children named 'daemon' → picks child #1":
    let src = "service {\n" &
              "  daemon \"first\" port=1\n" &
              "  daemon \"second\" port=2\n" &
              "}\n"
    let d = parseDoc(src)
    let parent = d.nodes[0]
    let r = decodeChild[Daemon](d, parent, "daemon")
    check r.isOk
    check r.get.name == "first"   # first-wins, not "second"
    check r.get.port == 1

  test "missing child → clear error (peTypeMissingRequired) with helpful hint":
    let src = "service {\n" &
              "  daemon \"web\" port=80\n" &
              "}\n"
    let d = parseDoc(src)
    let parent = d.nodes[0]
    let r = decodeChild[Permissions](d, parent, "permissions")
    check r.isErr
    let e = r.getErr
    check e.code == peTypeMissingRequired
    check e.hint.contains("permissions")   # the missing child name
    check e.hint.contains("service")        # the parent name for context

  test "decoded child error rebases to the child's true file line/col":
    let src = "service {\n" &
              "  daemon \"web\" port=\"oops\"\n" &   # port wants int → line 2
              "}\n"
    let d = parseDoc(src)
    let parent = d.nodes[0]
    let r = decodeChild[Daemon](d, parent, "daemon")
    check r.isErr
    check r.getErr.line == 2

suite "decodeOr[T](doc, node, fallback) — value or fallback, never errs (N3)":

  test "good node → the decoded value (fallback ignored)":
    let src = "daemon \"web\" port=80\n"
    let d = parseDoc(src)
    let fallback = Daemon(name: "DEFAULT", port: 0)
    let v = decodeOr[Daemon](d, d.nodes[0], fallback)
    check v.name == "web"
    check v.port == 80

  test "bad node (wrong type) → exactly the fallback, no error surfaced":
    let src = "daemon \"web\" port=\"oops\"\n"   # port wants int → decode fails
    let d = parseDoc(src)
    let fallback = Daemon(name: "DEFAULT", port: 42)
    let v = decodeOr[Daemon](d, d.nodes[0], fallback)
    check v == fallback
    check v.name == "DEFAULT"
    check v.port == 42

  test "name-mismatch node → fallback (decode would error on name check)":
    let src = "permissions \"rw\"\n"
    let d = parseDoc(src)
    let fallback = Daemon(name: "DEFAULT", port: 7)
    let v = decodeOr[Daemon](d, d.nodes[0], fallback)
    check v == fallback
