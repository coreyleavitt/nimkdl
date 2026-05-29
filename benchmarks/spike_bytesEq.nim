## Microbench comparing bytesEq implementations on realistic key
## lengths. Goal: quantify the actual cost of dropping equalMem
## (the C FFI memcmp wrapper) vs keeping it.
##
## Variants:
##   1. equalMem  — what cursor.bytesEq does today (runtime fast path)
##   2. byteLoop  — pure-Nim loop, character-by-character
##   3. swarLoop  — SWAR uint64 chunks + tail (best pure-Nim)
##   4. nimEq     — Nim `==` on toOpenArray slices (compiler-handled)
##
## Compile:
##   nim c -d:release -d:lto --hints:off benchmarks/spike_bytesEq.nim

import std/[monotimes, sequtils, strutils, times]

# ---------------------------------------------------------------------------
# Implementations
# ---------------------------------------------------------------------------

proc bytesEq_equalMem(a: openArray[char], aOff, aLen: int,
                     b: string): bool =
  aLen == b.len and equalMem(unsafeAddr a[aOff], unsafeAddr b[0], aLen)

proc bytesEq_byteLoop(a: openArray[char], aOff, aLen: int,
                     b: string): bool =
  if aLen != b.len: return false
  for i in 0 ..< aLen:
    if a[aOff + i] != b[i]: return false
  true

proc bytesEq_swarLoop(a: openArray[char], aOff, aLen: int,
                     b: string): bool =
  ## SWAR: compare 8 bytes at a time via uint64 unaligned read +
  ## tail. Pure Nim — no FFI, but uses `cast[ptr uint64]` so it
  ## won't run in NimVM.
  if aLen != b.len: return false
  var i = 0
  while i + 8 <= aLen:
    let av = cast[ptr uint64](unsafeAddr a[aOff + i])[]
    let bv = cast[ptr uint64](unsafeAddr b[i])[]
    if av != bv: return false
    i += 8
  while i < aLen:
    if a[aOff + i] != b[i]: return false
    inc i
  true

proc bytesEq_nimEq(a: openArray[char], aOff, aLen: int,
                  b: string): bool =
  ## Let the compiler decide. `==` on openArray slices.
  if aLen != b.len: return false
  a.toOpenArray(aOff, aOff + aLen - 1) == b.toOpenArray(0, b.len - 1)

# ---------------------------------------------------------------------------
# What the OLD codegen did — per-literal inlined byte compares
# ---------------------------------------------------------------------------
#
# Length is known at macro time (it's the length of the literal). Bytes
# are known at macro time too. The compiler sees:
#   if len == 4 and a[0]=='n' and a[1]=='a' and a[2]=='m' and a[3]=='e'
# It can constant-fold the length check, inline the four byte loads,
# and on x86-64 may emit a single 4-byte word compare. No FFI, no
# runtime loop, and works in NimVM trivially.
#
# In real codegen this would be macro-emitted per dispatch site. Here
# we hand-roll one per test key to measure what the compiler does.

template eq4(a: openArray[char], off: int, b0, b1, b2, b3: char): bool =
  a[off+0] == b0 and a[off+1] == b1 and a[off+2] == b2 and a[off+3] == b3

template eq5(a: openArray[char], off: int,
             b0, b1, b2, b3, b4: char): bool =
  eq4(a, off, b0, b1, b2, b3) and a[off+4] == b4

template eq7(a: openArray[char], off: int,
             b0, b1, b2, b3, b4, b5, b6: char): bool =
  eq5(a, off, b0, b1, b2, b3, b4) and a[off+5] == b5 and a[off+6] == b6

template eq8(a: openArray[char], off: int,
             b0, b1, b2, b3, b4, b5, b6, b7: char): bool =
  eq7(a, off, b0, b1, b2, b3, b4, b5, b6) and a[off+7] == b7

template eq10(a: openArray[char], off: int,
              b0, b1, b2, b3, b4, b5, b6, b7, b8, b9: char): bool =
  eq8(a, off, b0, b1, b2, b3, b4, b5, b6, b7) and
    a[off+8] == b8 and a[off+9] == b9

template eq17(a: openArray[char], off: int,
              b0, b1, b2, b3, b4, b5, b6, b7, b8, b9,
              b10, b11, b12, b13, b14, b15, b16: char): bool =
  eq10(a, off, b0, b1, b2, b3, b4, b5, b6, b7, b8, b9) and
    a[off+10] == b10 and a[off+11] == b11 and a[off+12] == b12 and
    a[off+13] == b13 and a[off+14] == b14 and a[off+15] == b15 and
    a[off+16] == b16

proc benchInlined(name: string, source: string,
                  offsets: seq[int], iter: int) =
  ## Dispatch each key via its compile-time-known inlined byte compare.
  ## This mimics what the old codegen emitted: per-key, per-position
  ## byte checks that the compiler can fold/vectorize.
  var sink: int = 0
  let t0 = getMonoTime()
  for _ in 0 ..< iter:
    # Order matches the keys[] above.
    if eq4(source.toOpenArray(0, source.len - 1), offsets[0],  'n','a','m','e'): inc sink
    if eq4(source.toOpenArray(0, source.len - 1), offsets[1],  'p','o','r','t'): inc sink
    if eq4(source.toOpenArray(0, source.len - 1), offsets[2],  'h','o','s','t'): inc sink
    if eq5(source.toOpenArray(0, source.len - 1), offsets[3],  'v','a','l','u','e'): inc sink
    if eq5(source.toOpenArray(0, source.len - 1), offsets[4],  'l','a','b','e','l'): inc sink
    if eq7(source.toOpenArray(0, source.len - 1), offsets[5],  'e','n','a','b','l','e','d'): inc sink
    if eq7(source.toOpenArray(0, source.len - 1), offsets[6],  'd','e','f','a','u','l','t'): inc sink
    if eq8(source.toOpenArray(0, source.len - 1), offsets[7],  'f','r','a','g','m','e','n','t'): inc sink
    if eq8(source.toOpenArray(0, source.len - 1), offsets[8],  'e','n','d','p','o','i','n','t'): inc sink
    if eq10(source.toOpenArray(0, source.len - 1), offsets[9], 'a','n','n','o','t','a','t','i','o','n'): inc sink
    if eq10(source.toOpenArray(0, source.len - 1), offsets[10],'t','r','a','n','s','i','t','i','v','e'): inc sink
    if eq17(source.toOpenArray(0, source.len - 1), offsets[11],'k','u','b','e','r','n','e','t','e','s','s','e','r','v','i','c','e'): inc sink
  let t1 = getMonoTime()
  let ns = (t1 - t0).inNanoseconds.float
  let perCall = ns / float(iter * 12)
  echo name.alignLeft(20), " ", formatFloat(perCall, ffDecimal, 2),
       " ns/call  (sink=", sink, ")"

# ---------------------------------------------------------------------------
# Bench harness
# ---------------------------------------------------------------------------

proc benchVariant(name: string, fn: proc(a: openArray[char], aOff, aLen: int,
                                         b: string): bool {.nimcall.},
                  source: string, keys: seq[string], offsets: seq[int],
                  iter: int) =
  # Warmup
  for _ in 0 ..< 1000:
    for k in keys:
      discard fn(source.toOpenArray(0, source.len - 1), 0, k.len, k)
  # Measure
  var sink: int = 0  # prevent dead-code elimination
  let t0 = getMonoTime()
  for _ in 0 ..< iter:
    for kIdx, k in keys:
      let off = offsets[kIdx]
      if fn(source.toOpenArray(0, source.len - 1), off, k.len, k):
        inc sink
  let t1 = getMonoTime()
  let ns = (t1 - t0).inNanoseconds.float
  let perCall = ns / float(iter * keys.len)
  echo name.alignLeft(20), " ", formatFloat(perCall, ffDecimal, 2),
       " ns/call  (sink=", sink, ")"

# ---------------------------------------------------------------------------
# Workload — realistic KDL key sizes
# ---------------------------------------------------------------------------

when isMainModule:
  # Build a source string containing each key at a known offset.
  let keys = @[
    # 4-char (common short props)
    "name", "port", "host",
    # 5-7 char (mid)
    "value", "label", "enabled", "default",
    # 8-12 char (longer prop / type-tag names)
    "fragment", "endpoint", "annotation", "transitive",
    # 16-char (edge of memcmp's SWAR sweet spot)
    "kubernetesservice",
  ]
  var src = ""
  var offsets: seq[int]
  for k in keys:
    offsets.add(src.len)
    src.add(k)
    src.add(" ")  # separator
  echo "source: ", src.len, " bytes; ", keys.len, " keys"
  echo "lengths: ",
       formatFloat(keys.mapIt(it.len).foldl(a + b, 0).float / keys.len.float,
                   ffDecimal, 1),
       " avg, ", keys.mapIt(it.len).min, " min, ",
       keys.mapIt(it.len).max, " max"
  echo ""
  let iter = 200_000
  echo "iterations: ", iter, " × ", keys.len, " keys = ",
       iter * keys.len, " bytesEq calls each"
  echo ""
  benchVariant("equalMem (FFI)", bytesEq_equalMem, src, keys, offsets, iter)
  benchVariant("byteLoop", bytesEq_byteLoop, src, keys, offsets, iter)
  benchVariant("swarLoop", bytesEq_swarLoop, src, keys, offsets, iter)
  benchVariant("nimEq (==)", bytesEq_nimEq, src, keys, offsets, iter)
  benchInlined("inlinedConst", src, offsets, iter)
