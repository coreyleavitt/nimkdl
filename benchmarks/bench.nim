## Performance benchmarks for coreyleavitt/nimkdl parser.
##
## Adapted from greenm01/nimkdl's benchmark.nim so the numbers compare
## directly against their published BENCHMARK_COMPARISON.md (which itself
## benches against Rust kdl-rs).
##
## Same input documents, same iteration counts, same synthetic shapes.
## Different parser, different flags = different number.
##
## Run with the matching production flag profile:
##
##   nim c -r -d:release --hints:off benchmarks/bench.nim
##
## Or with greenm01's "danger mode" profile for apples-to-apples vs
## their published numbers:
##
##   nim c -r -d:release -d:danger \
##     --passC:-march=native --passC:-ffast-math \
##     --hints:off benchmarks/bench.nim

import std/[times, strformat, monotimes, os, strutils]
import kdl

type
  BenchResult = object
    name: string
    totalTime: float
    iterations: int
    avgTime: float
    opsPerSec: float
    fileSize: int

proc formatDuration(seconds: float): string =
  if seconds < 0.001: &"{seconds * 1_000_000:.1f}μs"
  elif seconds < 1.0: &"{seconds * 1000:.2f}ms"
  else: &"{seconds:.3f}s"

proc formatSize(bytes: int): string =
  if bytes < 1024: &"{bytes}B"
  elif bytes < 1024 * 1024: &"{bytes div 1024}KB"
  else: &"{bytes div (1024*1024)}MB"

proc formatRate(rate: float): string =
  if rate < 1000: &"{rate:.1f} ops/s"
  elif rate < 1_000_000: &"{rate / 1000:.1f}K ops/s"
  else: &"{rate / 1_000_000:.2f}M ops/s"

proc benchmark(name: string, content: string, iterations: int): BenchResult =
  let fileSize = content.len

  # Warm up the JIT / cache lines / branch predictors before measurement.
  for i in 1..min(100, iterations div 10):
    discard parse(content)

  let start = getMonoTime()
  for i in 1..iterations:
    discard parse(content)
  let elapsed = (getMonoTime() - start).inNanoseconds.float / 1_000_000_000.0

  BenchResult(
    name: name,
    totalTime: elapsed,
    iterations: iterations,
    avgTime: elapsed / iterations.float,
    opsPerSec: iterations.float / elapsed,
    fileSize: fileSize,
  )

proc printResults(results: seq[BenchResult]) =
  echo ""
  echo "=".repeat(80)
  echo "  KDL Parser Benchmarks — coreyleavitt/nimkdl"
  echo "=".repeat(80)
  echo ""
  echo alignLeft("Benchmark", 30) & alignLeft("Size", 8) & alignLeft("Iterations", 12) &
       alignLeft("Avg Time", 12) & alignLeft("Throughput", 15)
  echo "-".repeat(80)
  for r in results:
    echo alignLeft(r.name, 30) & alignLeft(formatSize(r.fileSize), 8) &
         alignLeft($r.iterations, 12) & alignLeft(formatDuration(r.avgTime), 12) &
         alignLeft(formatRate(r.opsPerSec), 15)
  echo ""

  var totalOps = 0
  var totalTime = 0.0
  var totalBytes = 0
  for r in results:
    totalOps += r.iterations
    totalTime += r.totalTime
    totalBytes += r.fileSize * r.iterations

  let avgOpsPerSec = totalOps.float / totalTime
  let throughputMBps = (totalBytes.float / totalTime) / (1024 * 1024)
  echo "Summary:"
  echo &"  Total operations: {totalOps}"
  echo &"  Total time: {formatDuration(totalTime)}"
  echo &"  Average throughput: {formatRate(avgOpsPerSec)}"
  echo &"  Data processed: {formatSize(totalBytes)}"
  echo &"  MB/s: {throughputMBps:.2f}"
  echo ""

proc main() =
  let here = currentSourcePath().parentDir()
  let fixtures = here / "fixtures"
  let conf = here.parentDir() / "tests" / "conformance" / "test_cases" / "input"

  var results: seq[BenchResult]

  # Same files greenm01 uses, same iteration counts, same input bytes.
  let cases = [
    ("Cargo.kdl (small)",       fixtures / "Cargo.kdl",   10_000),
    ("ci.kdl (medium)",         fixtures / "ci.kdl",       5_000),
    ("website.kdl (medium)",    fixtures / "website.kdl",  5_000),
    # Multi-script identifier stress (Greek/Cyrillic/CJK/RTL/combining
    # marks/emoji ZWJ sequences). Exercises the UTF-8 fast-path in the
    # bare-ident lexer; ours-only — greenm01 fails to parse these.
    ("unicode-heavy.kdl",       fixtures / "unicode-heavy.kdl", 5_000),
    ("all_node_fields.kdl",     conf / "all_node_fields.kdl", 20_000),
    ("all_escapes.kdl",         conf / "all_escapes.kdl",     20_000),
  ]

  for (name, path, iters) in cases:
    if not fileExists(path):
      echo &"warning: {path} not found, skipping"
      continue
    let content = readFile(path)
    let res = benchmark(name, content, iters)
    echo &"  {name}: {formatRate(res.opsPerSec)}"
    results.add(res)

  # Synthetic shapes — identical to greenm01's harness.
  let syntheticNodes = """
node1 "arg1" prop1="val1"
node2 123 prop2=456
node3 3.14 prop3="value"
""".repeat(10)
  results.add(benchmark("Synthetic (30 nodes)", syntheticNodes, 10_000))

  # Shallow legacy shape — kept for back-compatibility with greenm01's
  # published numbers.
  var deepNest = ""
  for i in 1..20: deepNest.add(&"level{i} {{\n")
  deepNest.add("leaf \"value\"\n")
  for i in 1..20: deepNest.add("}\n")
  results.add(benchmark("Synthetic (deep nesting, 20)", deepNest, 10_000))

  # Pure deep chain — depth 100, every level has a couple of entries
  # so the parser does non-trivial work per level. This is the shape
  # that stress-tests the hash-call complexity the most: an O(N·d) hash
  # at parse time would be Σ 1..100 = 5050 hash calls; bottom-up is 100.
  var deepChain = ""
  const chainDepth = 100
  for i in 1..chainDepth:
    deepChain.add(&"level{i} arg{i} key{i}={i} {{\n")
  deepChain.add("leaf \"bottom\" depth=" & $chainDepth & "\n")
  for _ in 1..chainDepth: deepChain.add("}\n")
  results.add(benchmark(&"Synthetic (deep chain, {chainDepth})", deepChain, 2_000))

  # Realistic deep+wide tree — branching factor 3, depth 8 → 9841 nodes.
  # Mirrors the shape of a moderately-large config (something like a
  # cargo workspace with nested workspaces and tasks). The previous
  # bench had a 13-node toy.
  proc buildTree(depth, branch: int, prefix: string): string =
    if depth == 0:
      result = &"{prefix}leaf \"{prefix}\" idx=0\n"
      return
    for b in 0 ..< branch:
      let name = &"{prefix}n{b}"
      result.add(&"{prefix}{name} arg=\"v\" depth={depth} {{\n")
      result.add(buildTree(depth - 1, branch, prefix & "  "))
      result.add(&"{prefix}}}\n")
  let bigTree = buildTree(8, 3, "")
  results.add(benchmark("Synthetic (tree d=8 b=3, ~9.8k nodes)", bigTree, 200))

  var wide = ""
  for i in 1..100: wide.add(&"node{i} \"arg\" key=\"val\"\n")
  results.add(benchmark("Synthetic (100 nodes)", wide, 5_000))

  printResults(results)

when isMainModule:
  main()
