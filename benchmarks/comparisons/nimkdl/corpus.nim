## Real-trace replay: parse every file in the kdl-org conformance
## corpus (338 community-curated KDL files, ~1.4 MB total) and report
## aggregate throughput.
##
## The corpus is maintained by kdl-org for spec testing, NOT by us.
## A perf claim on this corpus defends against "your fixtures are
## cherry-picked" — these are the same files every spec-compliant
## parser is held against.
##
## Some files are intentionally-malformed (`*_fail.kdl`) and should
## reject. Time is measured regardless of parse outcome; the metric
## is "how long does this parser take to chew through the whole
## corpus." Rejection speed is part of real-world throughput.
##
## Usage: nimkdl-corpus <corpus-dir>
## Output:
##   nimkdl  corpus  N=<files>  bytes=<KB>  iters=<N>  total=<ms>  MB/s=<X>  ok=<acc>/<all>

import std/[algorithm, monotimes, os, strformat, strutils, times]
import kdl

proc main() =
  if paramCount() < 1:
    echo "usage: nimkdl-corpus <corpus-dir>"
    quit(2)
  let dir = paramStr(1)
  if not dirExists(dir):
    echo &"missing corpus dir: {dir}"
    quit(2)

  var files: seq[tuple[name, content: string]] = @[]
  var totalBytes = 0
  for kind, path in walkDir(dir):
    if kind != pcFile: continue
    let name = path.extractFilename
    if not name.endsWith(".kdl"): continue
    let content = readFile(path)
    files.add((name, content))
    totalBytes += content.len
  files.sort do (a, b: tuple[name, content: string]) -> int:
    cmp(a.name, b.name)

  const iters = 50
  var okCount = 0
  let start = getMonoTime()
  for _ in 0 ..< iters:
    okCount = 0
    for f in files:
      let r = parse(f.content)
      if r.isOk: inc okCount
  let elapsed = (getMonoTime() - start).inNanoseconds.float / 1e9

  # Average file is small (~20 bytes) — fixed parser-call overhead
  # dominates over byte throughput. Lead with per-file timing.
  let totalParses = files.len * iters
  let usPerFile = elapsed * 1_000_000.0 / float(totalParses)
  let filesPerSec = float(totalParses) / elapsed
  let kbsPerSec = (float(totalBytes) * float(iters)) / (elapsed * 1024.0)
  echo &"  nimkdl  corpus  files={files.len}  bytes={totalBytes}  iters={iters}  us/file={usPerFile:.2f}  files/s={filesPerSec/1000:.1f}K  KB/s={kbsPerSec:.0f}  ok={okCount}/{files.len}"

main()
