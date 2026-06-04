## test_node_emit.nim — canonical encoder for the self-contained DOM (rfc §SB).
##
## `encode(doc)` walks a node.KdlDoc and renders canonical KDL via the existing
## (value-agnostic) BufferEmitter primitives. The strong gate is a round-trip
## over the kdl-org corpus: parseNodes(encode(parseNodes(input))) must denote the
## same model as parseNodes(input). Preserve-mode (byte-exact) needs the sidecar
## and lands in a later slice.

import std/[unittest, options, os, strutils, sets]
import ../src/node_build
import ../src/node_emit

suite "node_emit — canonical encode unit cases":
  proc enc(src: string): string = encode(parseNodes(src).get)

  test "bare node":
    check enc("foo\n") == "foo\n"

  test "args render in order":
    check enc("n 1 \"two\" #true #null\n") == "n 1 \"two\" #true #null\n"

  test "property":
    check enc("n a=1\n") == "n a=1\n"

  test "children nest":
    check enc("parent {\n  child 7\n}\n").parseNodes.get.node("parent").child("child").arg(0) ==
          some(newKdlInt(7))

suite "node_emit — single-node encode(node)":
  proc encNode(src: string): string =
    ## Encode the first top-level node of `src`.
    encode(parseNodes(src).get.rootNodes[0])

  test "bare node":
    check encNode("foo\n") == "foo\n"

  test "node with args and props":
    check encNode("n 1 \"two\" a=3 #true\n") == "n 1 \"two\" a=3 #true\n"

  test "node with children":
    check encNode("parent {\n  child 7\n}\n") == "parent {\n    child 7\n}\n"

  test "round-trips structurally":
    let n = parseNodes("daemon port=8080 {\n  log level=#null\n}\n").get.rootNodes[0]
    let reparsed = parseNodes(encode(n)).get.rootNodes[0]
    check reparsed == n

  test "encode(node) is usable at compile time (func-ness)":
    const txt = encode(parseNodes("svc name=\"web\"\n").get.rootNodes[0])
    check txt == "svc name=\"web\"\n"

suite "node_emit — round-trip over kdl-org corpus":
  test "parseNodes(encode(parseNodes(input))) == parseNodes(input)":
    const Conf = currentSourcePath.parentDir / "conformance"
    const Root = Conf / "test_cases"
    var skips: HashSet[string]
    for f in ["skips.txt", "skips_doc_builder.txt"]:
      let p = Conf / f
      if not fileExists(p): continue
      for line in readFile(p).splitLines():
        let s = line.strip()
        if s.len == 0 or s.startsWith("#"): continue
        var name = s
        let bar = s.find('|')
        if bar >= 0: name = s[0 ..< bar].strip()
        if name.endsWith(".kdl"): name = name[0 ..^ 5]
        skips.incl(name)
    var checked = 0
    var bad: seq[string]
    for entry in walkDir(Root / "input"):
      if not entry.path.endsWith(".kdl"): continue
      let base = entry.path.extractFilename
      if base[0 ..^ 5] in skips: continue
      if not fileExists(Root / "expected_kdl" / base): continue
      let parsed = parseNodes(readFile(entry.path))
      if parsed.isErr: continue
      let reparsed = parseNodes(encode(parsed.get))
      if reparsed.isErr:
        bad.add(base & " encode-unparseable:" & $reparsed.getErr.code); continue
      if reparsed.get != parsed.get:
        bad.add(base & " roundtrip-mismatch")
      inc checked
    if bad.len > 0:
      checkpoint("round-trip failures (" & $bad.len & "): " & bad.join("  |  "))
    check checked > 150
    check bad.len == 0
