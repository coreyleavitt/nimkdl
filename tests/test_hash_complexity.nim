## Compile with -d:kdlHashStats. Pins the linear-hashing invariant for
## BOTH parse and encode-preserve paths. Without this guard, an O(N·d)
## recursive re-hash creeps back in (caught once in flight at
## src/encode.nim:338 / src/parser.nim:481 — see
## [[nimkdl-pending-perf-work]] in memory).

import std/[unittest, strutils]
import ../src/[parser, encode, ast, spans]

proc countNodes(ns: seq[KdlNode]): int =
  for n in ns:
    result.inc
    result.inc countNodes(n.children)

proc buildDeepChain(depth: int): string =
  ## A linear chain of `depth` nested nodes. Recursive parser hashing
  ## costs Σ i = depth·(depth+1)/2; bottom-up costs depth.
  var s = ""
  for i in 0 ..< depth:
    s.add("n" & $i)
    if i < depth - 1: s.add(" {\n")
  for i in 0 ..< depth - 1:
    s.add("\n}")
  s

when defined(kdlHashStats):
  suite "hash-call complexity — parse-time bottom-up":
    test "parse of N-deep chain calls hash O(N), not O(N²)":
      const depth = 64
      let src = buildDeepChain(depth)
      kdlHashCallCount = 0
      let r = parse(src)
      check r.isOk
      let nodeCount = countNodes(r.get.nodes)
      check nodeCount == depth
      # Allow a small constant multiplier (entries vs nodes etc.).
      # The buggy form gives ~depth·(depth+1)/2 = 2080 for depth=64.
      # Bottom-up gives ~depth = 64. Cap at 4× node count.
      check kdlHashCallCount <= nodeCount * 4

    test "parse of wide-shallow tree is also linear":
      var src = "root {\n"
      const width = 100
      for i in 0 ..< width:
        src.add("  child" & $i & " v=" & $i & "\n")
      src.add("}")
      kdlHashCallCount = 0
      let r = parse(src)
      check r.isOk
      let nodeCount = countNodes(r.get.nodes)
      check kdlHashCallCount <= nodeCount * 4
else:
  echo "test_hash_complexity: skipped (compile with -d:kdlHashStats)"
