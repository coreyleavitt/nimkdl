## Edit-then-encode throughput. Both nimkdl and kdl-rs are explicitly
## designed for byte-lossless edit-then-emit workflows (the editor /
## formatter / config-rewriter use case). This bench exercises the
## full cycle: parse(preserveFormat) → mutate one node → encode().
##
## nimkdl strategy: per-node `parseHash`; on encode, mutated subtrees
## emit canonical while siblings preserve verbatim source bytes.
##
## kdl-rs strategy: per-token whitespace storage; on encode, walks the
## tree emitting carried trivia per token regardless of mutation.
##
## The bench measures the COMPLETE cycle (parse + edit + encode) per
## iteration because that's the realistic editor "open → edit → save"
## workflow on a single file. Same cycle shape on both parsers.

import std/[monotimes, os, strformat, times]
import kdl

proc main() =
  if paramCount() < 1:
    echo "usage: nimkdl-edit <fixture-path>"
    quit(2)
  let path = paramStr(1)
  if not fileExists(path):
    echo &"missing fixture: {path}"
    quit(2)
  let src = readFile(path)

  const iters = 5_000
  # Warmup
  for _ in 0 ..< 100:
    var doc = parse(src, preserveFormat = true).get
    doc.nodes[0].setProp(doc, "bench-mark", newStringValue("edited"))
    discard encode(doc, emPreserve)
  let start = getMonoTime()
  for _ in 0 ..< iters:
    var doc = parse(src, preserveFormat = true).get
    doc.nodes[0].setProp(doc, "bench-mark", newStringValue("edited"))
    discard encode(doc, emPreserve)
  let el = (getMonoTime() - start).inNanoseconds.float / 1e9

  let us = el / float(iters) * 1_000_000.0
  let ops = float(iters) / el
  let fixture = path.extractFilename
  echo &"  nimkdl  edit-encode  {fixture:<30} {us:>8.1f}us avg   {ops/1000:>8.1f}K ops/s   {src.len} bytes"

main()
