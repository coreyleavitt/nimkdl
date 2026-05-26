## nimkdl benchmark harness.
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
import kdl

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

proc printResults(results: seq[BenchResult]) =
  echo ""
  echo "=".repeat(80)
  echo "  nimkdl benchmarks — coreyleavitt/nimkdl"
  echo "=".repeat(80)
  printSection(results, "real-world")
  printSection(results, "large")
  printSection(results, "regression-guard")
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
  for (name, path, iters) in realCases:
    if not fileExists(path):
      echo &"warn: {path} not found, skipping"; continue
    results.add(benchmark(name, "real-world", readFile(path), iters))

  # ---- Large workloads -----------------------------------------------------
  # Flat-deps: shape of a typical dependency or service list. ~100 nodes,
  # one level deep.
  var flatDeps = "// flat list of ~100 services, common config shape\n"
  for i in 1..100:
    flatDeps.add(&"service \"svc-{i}\" port=(tcp){{8000 + i}} replicas={(i mod 5) + 1}\n")
  flatDeps = flatDeps.replace("{{8000 + i}}", "8042")  # quick literal
  results.add(benchmark("flat-deps (~100 nodes)", "large", flatDeps, 2_000))

  # Tree d=8 b=3 — branching ~9.8k nodes, monorepo workspace shape.
  proc buildTree(depth, branch: int, prefix: string): string =
    if depth == 0:
      return &"{prefix}leaf \"x\" idx=0\n"
    for b in 0 ..< branch:
      let name = &"{prefix}n{b}"
      result.add(&"{prefix}{name} arg=\"v\" depth={depth} {{\n")
      result.add(buildTree(depth - 1, branch, prefix & "  "))
      result.add(&"{prefix}}}\n")
  let bigTree = buildTree(8, 3, "")
  results.add(benchmark("tree d=8 b=3 (~9.8k nodes)", "large", bigTree, 200))

  # ---- Regression guards ---------------------------------------------------
  # These are PATHOLOGICAL shapes — not representative of real workloads.
  # They exist to catch perf regressions on the code paths they hit.
  # Each one's slow case corresponds to a real bug we've fixed before.

  # deep-chain (100): the shape that caught the O(N²) Result.get deep-copy
  # in commit 660fe7a. If this throughput regresses materially, someone
  # introduced another `.get` instead of `.take` (or a for-loop value-copy).
  var deep = ""
  for i in 1..100: deep.add(&"level{i} arg{i} key{i}={i} {{\n")
  deep.add("leaf \"bottom\" depth=100\n")
  for _ in 1..100: deep.add("}\n")
  results.add(benchmark("deep-chain (100)", "regression-guard", deep, 1_000))

  # unicode-heavy: multi-script identifiers + combining marks + emoji ZWJ.
  # Guards the lexBareIdent unicode codepoint classification path.
  # greenm01/nimkdl outright FAILS to parse this — claims "100% v2"
  # but rejects valid v2 multi-script idents.
  let unicode = readFile(fixtures / "unicode-heavy.kdl")
  results.add(benchmark("unicode-heavy.kdl", "regression-guard", unicode, 2_000))

  printResults(results)

when isMainModule:
  main()
