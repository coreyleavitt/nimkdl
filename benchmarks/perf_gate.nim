## Deterministic perf gate for the decode/parse path.
##
## WSL2 has no hardware PMU (`perf stat` instructions = "not supported")
## and wall-clock carries ±13% noise even over 120k iters — both useless
## for gating sub-10% code changes. callgrind is a CPU *simulator*, so its
## instruction count ("I refs") is exact and frequency-independent. That is
## the gate: measure I refs before and after a change; the delta is the
## change, with no noise floor.
##
## Build the container once:
##   podman build -t localhost/nim-perf-vg:2.2.0 -  # nim-perf:2.2.0 + `apt install valgrind`
##
## Run the gate (callgrind mode — pass a fixed iter count so startup
## instructions are a constant baseline that cancels in the delta):
##   nim c -d:release -d:danger --debugger:native \
##         --passC:-fno-omit-frame-pointer -o:/tmp/perf_gate benchmarks/perf_gate.nim
##   valgrind --tool=callgrind --callgrind-out-file=/tmp/cg.out /tmp/perf_gate 800
##   callgrind_annotate /tmp/cg.out | head   # total "I refs"
##
## Reference baseline (N=800):
##   961,428,231 I refs @ commit d644785 (self-contained-node core +
##   derive-vocabulary RFC). The derive-vocabulary RFC added 0 I refs vs the
##   pre-RFC commit 54676c8 — identical count, since a type using no new
##   pragmas compiles to identical code. Historical: 1,054,947,168 @ 9d6b4ba
##   (pre self-contained-node rebuild); 1,462,759,900 clean Phase-3. A
##   regression shows up as a rise in this number.
##
## With no arg the binary instead runs a wall-clock loop (120k iters) — only
## a rough sanity check, NOT the gate. See [[nkdl_perf_profile]].

import std/[os, monotimes, times, strutils]
import ../src/parser
import ../src/api
import ../src/kdl_block
import ../src/pragmas

kdl:
  type Service {.kdlNode: "service".} = object
    name {.kdlArg.}: string
    port {.kdlProp.}: int
    replicas {.kdlProp.}: int
    enabled {.kdlProp.}: bool

let svc = readFile(currentSourcePath().parentDir / "fixtures" /
                   "homogeneous-services-100.kdl")
let cfg = readFile(currentSourcePath().parentDir / "fixtures" /
                   "realistic-config.kdl")

proc work(iters: int): int =
  for i in 0 ..< iters:
    let r = decode[seq[Service]](svc)
    doAssert r.isOk
    result += r.get.len
    let p = parse(cfg)
    doAssert p.isOk
    result += p.get.nodes.len

let args = commandLineParams()
if args.len > 0:
  # callgrind mode: a single work(N) at fixed N — startup instructions
  # are constant, so the Ir delta between builds reflects the code change.
  echo "acc=", work(parseInt(args[0]))
else:
  discard work(12_000)                      # warmup
  let t0 = getMonoTime()
  let acc = work(120_000)
  let t1 = getMonoTime()
  let ms = (t1 - t0).inNanoseconds.float / 1e6
  echo "acc=", acc, "  total=", formatFloat(ms, ffDecimal, 1),
       " ms  per-pair=", formatFloat(ms * 1000.0 / 120_000.0, ffDecimal, 2), " us"
