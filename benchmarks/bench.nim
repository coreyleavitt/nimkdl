## nkdl benchmark harness.
##
## Three sections, each reported separately so the headline averages
## reflect what they're actually measuring:
##
##   1. Real-world configs — files of the shape humans actually write.
##      Cargo.kdl, ci.kdl, website.kdl are real KDL samples curated
##      by kdl-org. realistic-config.kdl is a dense ~5.6KB config that
##      exercises every language feature in realistic proportions:
##      all 6 keywords, type annotations, comments (line + block + /-),
##      all number bases, multi-line + raw strings, repeated property
##      keys, unicode identifiers. This is the headline workload —
##      "how fast do we parse the kind of KDL people write."
##
##   2. Large workloads — synthetic but realistic shapes for big configs:
##      a flat list of ~100 nodes (deps/services/route table) and a
##      deep+wide tree (~9.8k nodes, monorepo workspace shape).
##
##   3. Regression guards — NOT representative of real workloads. These
##      stress-test specific code paths and exist to catch perf
##      regressions. Each one corresponds to a past bug:
##        - deep-chain (100): guards the O(N²) recursion fixed in 660fe7a
##        - unicode-heavy: guards the multi-script identifier path
##          (greenm01 fails this entirely)
##
## Run with:
##   nim c -r -d:release benchmarks/bench.nim
##
## For comparison-grade numbers, run in a container (musl differences
## are real — see commit messages around 660fe7a for the kdl-rs reproduction
## investigation):
##   podman run --rm -v "$PWD:/work:Z" -w /work docker.io/nimlang/nim:2.2.0 \
##     nim c -r -d:release -p:src benchmarks/bench.nim

import std/[times, strformat, monotimes, os, strutils, sequtils]
import nkdl

type
  BenchResult = object
    name: string
    section: string
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

proc benchmark(name, section: string, content: string,
               iterations: int): BenchResult =
  for i in 1..min(100, iterations div 10): discard parse(content)
  let start = getMonoTime()
  for i in 1..iterations: discard parse(content)
  let elapsed = (getMonoTime() - start).inNanoseconds.float / 1_000_000_000.0
  result = BenchResult(name: name, section: section,
    totalTime: elapsed, iterations: iterations,
    avgTime: elapsed / iterations.float,
    opsPerSec: iterations.float / elapsed,
    fileSize: content.len)

proc benchmarkEncode(name, section: string, content: string,
                     mode: EncodeMode, preserveFormat: bool,
                     iterations: int): BenchResult =
  ## Encode-side bench. Parses once up front (with the right
  ## preserveFormat flag for the target mode) and times only the
  ## encode loop. Output: parses-per-second of the encode pass.
  let r = parse(content, preserveFormat = preserveFormat)
  if r.isErr:
    echo &"parse failed for {name}: {r.getErr.hint}"
    return BenchResult(name: name, section: section, fileSize: content.len)
  let doc = r.get
  for i in 1..min(100, iterations div 10): discard encode(doc, mode)
  let start = getMonoTime()
  for i in 1..iterations: discard encode(doc, mode)
  let elapsed = (getMonoTime() - start).inNanoseconds.float / 1_000_000_000.0
  result = BenchResult(name: name, section: section,
    totalTime: elapsed, iterations: iterations,
    avgTime: elapsed / iterations.float,
    opsPerSec: iterations.float / elapsed,
    fileSize: content.len)

proc printSection(results: seq[BenchResult], section: string) =
  let rs = results.filterIt(it.section == section)
  if rs.len == 0: return
  echo ""
  echo "  " & section
  echo "  " & "-".repeat(78)
  echo "  " & alignLeft("benchmark", 32) & alignLeft("size", 8) &
       alignLeft("iters", 10) & alignLeft("avg time", 12) &
       "throughput"
  for r in rs:
    echo "  " & alignLeft(r.name, 32) & alignLeft(formatSize(r.fileSize), 8) &
         alignLeft($r.iterations, 10) & alignLeft(formatDuration(r.avgTime), 12) &
         formatRate(r.opsPerSec)
  var totalBytes = 0
  var totalTime = 0.0
  for r in rs:
    totalBytes += r.fileSize * r.iterations
    totalTime += r.totalTime
  let mbps = totalBytes.float / totalTime / (1024.0 * 1024.0)
  echo &"  section avg: {mbps:.1f} MB/s"

proc printEncodeSection(results: seq[BenchResult], section: string) =
  ## Same layout as printSection but throughput is bytes-out per second
  ## (the encoded size, not the input size) so the MB/s number reflects
  ## actual output produced. Reported alongside ops/s.
  let rs = results.filterIt(it.section == section)
  if rs.len == 0: return
  echo ""
  echo "  " & section
  echo "  " & "-".repeat(78)
  echo "  " & alignLeft("benchmark", 36) & alignLeft("size", 8) &
       alignLeft("iters", 10) & alignLeft("avg time", 12) &
       "throughput"
  for r in rs:
    echo "  " & alignLeft(r.name, 36) & alignLeft(formatSize(r.fileSize), 8) &
         alignLeft($r.iterations, 10) & alignLeft(formatDuration(r.avgTime), 12) &
         formatRate(r.opsPerSec)

proc printResults(results: seq[BenchResult]) =
  echo ""
  echo "=".repeat(80)
  echo "  nkdl benchmarks — coreyleavitt/nimkdl"
  echo "=".repeat(80)
  printSection(results, "real-world")
  printSection(results, "large")
  printSection(results, "regression-guard")
  printEncodeSection(results, "encode-preserve")
  printEncodeSection(results, "encode-pretty")
  printEncodeSection(results, "encode-compact")
  echo ""

proc main() =
  let here = currentSourcePath().parentDir()
  let fixtures = here / "fixtures"
  var results: seq[BenchResult]

  # ---- Real-world configs --------------------------------------------------
  # The headline section. realistic-config.kdl is the most representative
  # single file — dense use of every language feature. The three kdl-org
  # samples (Cargo.kdl / ci.kdl / website.kdl) are real KDL but barely
  # exercise the parser (almost all strings, no annotations, ~0 keywords).
  let realCases = [
    ("realistic-config.kdl", fixtures / "realistic-config.kdl", 5_000),
    ("Cargo.kdl",            fixtures / "Cargo.kdl",            10_000),
    ("ci.kdl",               fixtures / "ci.kdl",                5_000),
    ("website.kdl",          fixtures / "website.kdl",           5_000),
  ]
  # Every fixture is now a real file on disk under benchmarks/fixtures/.
  # The synthetic shapes (deep-chain, tree, flat-deps) are checked in
  # so all four comparison harnesses can parse byte-identical inputs.
  # Re-generate from benchmarks/fixtures/generate.nim if shapes change.
  let largeCases = [
    ("flat-deps (~100 nodes)",       fixtures / "flat-deps-100.kdl",  2_000),
    ("tree d=8 b=3 (~9.8k nodes)",   fixtures / "tree-d8-b3.kdl",       200),
  ]
  let guardCases = [
    ("deep-chain (100)",             fixtures / "deep-chain-100.kdl", 1_000),
    ("unicode-heavy.kdl",            fixtures / "unicode-heavy.kdl",  2_000),
  ]

  for (name, path, iters) in realCases:
    if not fileExists(path):
      echo &"warn: {path} not found, skipping"; continue
    results.add(benchmark(name, "real-world", readFile(path), iters))
  for (name, path, iters) in largeCases:
    if not fileExists(path):
      echo &"warn: {path} not found, skipping"; continue
    results.add(benchmark(name, "large", readFile(path), iters))
  for (name, path, iters) in guardCases:
    if not fileExists(path):
      echo &"warn: {path} not found, skipping"; continue
    results.add(benchmark(name, "regression-guard", readFile(path), iters))

  # ---- Encode -------------------------------------------------------------
  # Three modes, three signal flavors.
  #
  #   emPreserve  byte-lossless: returns doc.sourceText verbatim when the
  #               doc hasn't been mutated. The fast-path is essentially a
  #               string return. Slower path is per-node hash check +
  #               surgical splice on edited subtrees.
  #   emPretty    canonical multi-line with indentation. Allocates and
  #               formats every node.
  #   emCompact   canonical single-line with `;` separators. Same work
  #               as emPretty without the indentation/newline padding.
  #
  # Bench on the real-world fixtures + the big tree. preserveFormat
  # is true for emPreserve, false otherwise (the canonical modes
  # don't need parseHash).
  let encodeCases = [
    ("realistic-config.kdl",       fixtures / "realistic-config.kdl",  5_000),
    ("ci.kdl",                     fixtures / "ci.kdl",                5_000),
    ("website.kdl",                fixtures / "website.kdl",           5_000),
    ("tree-d8-b3.kdl",             fixtures / "tree-d8-b3.kdl",          200),
  ]
  for (name, path, iters) in encodeCases:
    if not fileExists(path):
      echo &"warn: {path} not found, skipping"; continue
    let src = readFile(path)
    results.add(benchmarkEncode(name, "encode-preserve", src, emPreserve, true,  iters))
    results.add(benchmarkEncode(name, "encode-pretty",   src, emPretty,   false, iters))
    results.add(benchmarkEncode(name, "encode-compact",  src, emCompact,  false, iters))

  printResults(results)

when isMainModule:
  main()
