## Memory-footprint measurement harness for nimkdl. ONE fixture per
## invocation so each measurement gets a fresh VmPeak baseline (peak
## RSS is monotonic per-process — sharing a process across fixtures
## contaminates earlier measurements with later allocations).
##
## Usage:
##   nimkdl-mem <fixture-path>
##
## Output (one line):
##   nimkdl  <fixture>  baseline=<KB>  peak=<KB>  delta=<KB>  iters=<N>
##
## Methodology:
##   1. Read fixture into a string (this happens before any parse work,
##      so the post-read VmPeak is our "baseline" — Nim runtime + libc
##      + fixture bytes + any pre-parse harness overhead).
##   2. Parse N times in a loop, holding the FINAL doc in scope.
##   3. Read VmPeak again. Delta = (final - baseline).
##
## Delta is upper-bounded: peak RSS captures allocator high-water +
## the held doc + transient allocations that didn't get freed before
## the high-water was hit. That's the right number for "will my
## container OOM while parsing this." It is NOT a pure "doc size in
## isolation" metric; that requires a heap profiler.

import std/[os, strformat, strutils]
import kdl

proc vmPeakKb(): int =
  ## Read VmPeak (high-water-mark RSS) from /proc/self/status. Linux
  ## only — every harness in this comparison runs in Linux containers
  ## so portability isn't a concern.
  for line in lines("/proc/self/status"):
    if line.startsWith("VmPeak:"):
      for tok in line.splitWhitespace():
        if tok.len > 0 and tok[0] in {'0'..'9'}: return parseInt(tok)
  return -1

proc main() =
  if paramCount() < 1:
    echo "usage: nimkdl-mem <fixture-path>"
    quit(2)
  let path = paramStr(1)
  if not fileExists(path):
    echo &"missing fixture: {path}"
    quit(2)
  let content = readFile(path)
  # Iteration count: scale down for huge inputs so the bench doesn't
  # hang. Held-doc cost is captured by holding just the final parse;
  # the loop is for transient peak.
  # 20 iters on huge files (tree-d8-b3 = 794KB takes ~8ms each);
  # 200 on smaller. Iter count affects allocator high-water more
  # than held-doc cost — both signals fold into delta.
  let iters = (if content.len > 200_000: 20 else: 200)
  let baseline = vmPeakKb()

  var held: KdlDoc
  for _ in 0 ..< iters:
    let r = parse(content)
    doAssert r.isOk
    held = r.get
  let peak = vmPeakKb()
  discard held    # the hold is the point; silence "unused"

  let fixture = path.extractFilename
  let inputKb = (content.len + 1023) div 1024
  echo &"  nimkdl  {fixture:<35} input {inputKb:>5} KB   baseline {baseline:>6} KB   peak {peak:>6} KB   delta {peak - baseline:>6} KB"

main()
