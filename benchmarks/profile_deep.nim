## Phase-by-phase profile of deep-chain vs shallow parse cost.
##
## Compares per-byte cost across three workloads:
##   - shallow (Cargo.kdl, depth ~2-3)
##   - deep chain depth 100 (linear)
##   - deep+wide tree depth 8 branch 3 (~9.8k nodes)
##
## For each: times lex-only, parse-with-hash (current), and parse-with-hash
## minus lex (= parse+hash phase). The shallow-vs-deep per-byte ratio
## isolates depth-specific overhead.

import std/[times, strformat, monotimes, os, strutils]
import ../src/[parser, lexer, intern, encode, ast, fnv]

const HashStatsEnabled = defined(kdlHashStats)

proc timeIt(iters: int, body: proc()): float =
  for _ in 1..min(20, iters div 10): body()
  let start = getMonoTime()
  for _ in 1..iters: body()
  result = (getMonoTime() - start).inNanoseconds.float / 1e9

proc benchPhases(name: string, src: string, iters: int) =
  let bytes = src.len

  # Phase 1: lex only.
  let lexTime = timeIt(iters, proc () =
    var i = initInterner()
    discard lex(src, i))

  # Phase 2: full parse (lex + parse + parseHash assembly).
  let fullTime = timeIt(iters, proc () =
    discard parse(src))

  let parseOnlyTime = fullTime - lexTime
  let bytesTotal = bytes * iters

  echo &"  {name:<30} ({bytes:>6}B)  full={fullTime*1e6/iters.float:.1f}μs  " &
       &"lex={lexTime*1e6/iters.float:.1f}μs  " &
       &"parse+hash={parseOnlyTime*1e6/iters.float:.1f}μs  " &
       &"({(lexTime/fullTime)*100:.0f}% lex, " &
       &"{(parseOnlyTime/fullTime)*100:.0f}% parse+hash)  " &
       &"=> {(bytesTotal.float/fullTime/1024/1024):.1f} MB/s"

  when HashStatsEnabled:
    # Per-parse hash call count.
    kdlHashCallCount = 0
    discard parse(src)
    echo &"    hash calls per parse: {kdlHashCallCount}"

proc main() =
  echo "=== Phase-by-phase profile — deep vs shallow ===\n"

  # Shallow: Cargo.kdl
  let cargo = readFile(currentSourcePath().parentDir() / "fixtures" / "Cargo.kdl")
  benchPhases("Cargo.kdl (shallow)", cargo, 5_000)

  # Deep chain depth 100
  var deep100 = ""
  for i in 1..100: deep100.add(&"level{i} arg{i} key{i}={i} {{\n")
  deep100.add("leaf \"bottom\" depth=100\n")
  for _ in 1..100: deep100.add("}\n")
  benchPhases("deep chain (100)", deep100, 1_000)

  # Deep chain depth 50 for slope-vs-depth signal
  var deep50 = ""
  for i in 1..50: deep50.add(&"level{i} arg{i} key{i}={i} {{\n")
  deep50.add("leaf \"bottom\" depth=50\n")
  for _ in 1..50: deep50.add("}\n")
  benchPhases("deep chain (50)", deep50, 2_000)

  # Deep chain depth 100 — ZERO entries per level. Just `levelN { ... }`.
  # If this STILL super-linearly scales with depth, it's pure recursion/
  # stack overhead, not entries handling.
  var bare100 = ""
  for i in 1..100: bare100.add(&"level{i} {{\n")
  bare100.add("leaf\n")
  for _ in 1..100: bare100.add("}\n")
  benchPhases("bare chain (100, no entries)", bare100, 1_000)

  var bare50 = ""
  for i in 1..50: bare50.add(&"level{i} {{\n")
  bare50.add("leaf\n")
  for _ in 1..50: bare50.add("}\n")
  benchPhases("bare chain (50, no entries)", bare50, 2_000)

  # Tree d=8 b=3
  proc buildTree(d, b: int, prefix: string): string =
    if d == 0:
      result = &"{prefix}leaf \"x\" idx=0\n"
      return
    for k in 0 ..< b:
      let name = &"{prefix}n{k}"
      result.add(&"{prefix}{name} arg=\"v\" depth={d} {{\n")
      result.add(buildTree(d-1, b, prefix & "  "))
      result.add(&"{prefix}}}\n")
  let tree = buildTree(8, 3, "")
  benchPhases("tree d=8 b=3", tree, 100)

  echo ""
  echo "Notes:"
  echo "  - 'parse+hash' includes the AST construction AND parseHash assembly."
  echo "  - For depth-isolated overhead, compare ns/byte of deep vs shallow."
  echo "    If deep ns/byte >> shallow ns/byte → there's a real depth penalty."
  echo "  - If lex% is similar across shallow/deep → bottleneck is parse path."
  echo "  - If lex% drops in deep → parse/hash work is depth-amplified."

main()
