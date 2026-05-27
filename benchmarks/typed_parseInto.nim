## Cycle 11 perf acceptance bench for issue #1.
##
## Compares the new visitor-based parseInto[T] against the existing
## AST-based decode[seq[T]] on the same homogeneous-services-100.kdl
## fixture knus benches against. Acceptance criterion: parseInto[T]
## matches or beats knus's 23.2K ops/s.
import std/[os, times, strformat, monotimes]
import kdl

type Service {.kdlNode: "service".} = object
  name {.kdlArg.}: string
  port {.kdlProp.}: int
  replicas {.kdlProp.}: int = 1
  enabled {.kdlProp.}: bool = true

deriveDecode(Service)
deriveVisitor(Service)

proc bench(name: string, iters: int, body: proc()): float =
  for _ in 1..min(100, iters div 10): body()
  let start = getMonoTime()
  for _ in 1..iters: body()
  result = (getMonoTime() - start).inNanoseconds.float / 1e9

proc main() =
  let path = currentSourcePath().parentDir() / "fixtures" / "homogeneous-services-100.kdl"
  let src = readFile(path)
  const iters = 5_000

  let oldT = bench("decode[seq[T]]  (AST + walk)", iters,
                   proc() = discard decode[seq[Service]](src))
  let oldOps = iters.float / oldT
  let oldUs = oldT / iters.float * 1e6

  let newT = bench("parseInto[seq[T]] (visitor)", iters,
                   proc() = discard parseInto[seq[Service]](src))
  let newOps = iters.float / newT
  let newUs = newT / iters.float * 1e6

  echo &""
  echo &"  fixture: homogeneous-services-100.kdl ({src.len} bytes)"
  echo &"  iters:   {iters}"
  echo &""
  echo &"  decode[seq[Service]]   (AST + walk):  {oldUs:>7.1f}us  {oldOps/1000:>6.1f}K ops/s"
  echo &"  parseInto[seq[Service]] (visitor):   {newUs:>7.1f}us  {newOps/1000:>6.1f}K ops/s"
  echo &""
  echo &"  speedup:  {oldT/newT:.2f}x"
  echo &""
  echo &"  knus typed Vec<Service> reference:    ~43us       ~23.2K ops/s"
  if newOps >= 23_000:
    echo &"  ACCEPTANCE: matches/beats knus ({newOps/1000:.1f}K >= 23.2K)"
  else:
    let gap = 23200.0 / newOps
    echo &"  ACCEPTANCE: still behind knus by {gap:.2f}x ({newOps/1000:.1f}K vs 23.2K)"

main()
