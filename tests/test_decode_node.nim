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

import ../src/api
import ../src/parser
import ../src/node
import ../src/node_build   # newNode / addArg / addProp builders for hand-built nodes
import ../src/value
import ../src/kdl_block
import ../src/pragmas

kdl:
  type Daemon {.kdlNode: "daemon".} = object
    name {.kdlArg.}: string
    port {.kdlProp.}: int

  type Permissions {.kdlNode: "permissions".} = object
    mode {.kdlArg.}: string

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
