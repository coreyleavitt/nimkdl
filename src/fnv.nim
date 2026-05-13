## fnv — FNV-1a 128-bit hash, with composable add and string-byte hashing.
##
## Used by the AST per-node "freshness" check that drives `emPreserve`:
## at parse time each node records the hash of its canonical content; at
## encode time we recompute. Match → emit source bytes (preserves
## comments, exact whitespace, original number bases, etc.). Mismatch →
## the subtree has been mutated, emit canonical.
##
## ## Why FNV-1a 128
##
## - Tiny implementation (~25 LOC of integer ops), VM-callable so the
##   compile-time decode path keeps working.
## - 128 bits of output → birthday bound ~2^64, effectively zero
##   collision probability for honest workloads.
## - Non-adversarial threat model (we hash our own parser's output, not
##   user-supplied byte streams), so cryptographic strength is overkill.
## - xxh3-128 would be faster on real hardware but adds ~300 LOC + lookup
##   tables and is dramatically more complex. Filed as a follow-on if a
##   profiler ever shows hashing on the critical path.

type
  Hash128* = tuple[hi, lo: uint64]

const
  Fnv128Offset*: Hash128 =
    (hi: 0x6c62272e07bb0142'u64, lo: 0x62b821756295c58d'u64)
  Fnv128Prime*: Hash128 =
    (hi: 0x0000000001000000'u64, lo: 0x000000000000013b'u64)

func mul128(a, b: Hash128): Hash128 {.noSideEffect.} =
  ## 128 × 128 → low 128 bits (mod 2^128). Schoolbook over 32-bit
  ## chunks of `a.lo * b.lo` plus the cross terms.
  let a0 = a.lo and 0xFFFFFFFF'u64
  let a1 = a.lo shr 32
  let b0 = b.lo and 0xFFFFFFFF'u64
  let b1 = b.lo shr 32
  let p00 = a0 * b0
  let p01 = a0 * b1
  let p10 = a1 * b0
  let p11 = a1 * b1
  # p01 + p10 may overflow; track the carry into bit 64.
  let mid = p01 + p10
  let midCarry: uint64 = (if mid < p01: 1'u64 shl 32 else: 0'u64)
  # Build the low 64 bits: p00 plus the bottom 32 bits of `mid` shifted
  # left 32. Track carry into the high half.
  let midLowShift = mid shl 32
  let low = p00 + midLowShift
  let lowCarry: uint64 = (if low < p00: 1'u64 else: 0'u64)
  let high = p11 + (mid shr 32) + midCarry + lowCarry
  # Now (high, low) holds a.lo * b.lo as a 128-bit value.
  # Add the cross terms a.hi * b.lo + a.lo * b.hi (mod 2^64 each — the
  # 2^128 part discards).
  result.lo = low
  result.hi = high + a.hi * b.lo + a.lo * b.hi

func fnv128Update*(h: var Hash128, b: uint8) {.inline, noSideEffect.} =
  ## Mix one byte into the running hash, FNV-1a style: XOR then multiply.
  h.lo = h.lo xor uint64(b)
  h = mul128(h, Fnv128Prime)

func fnv128Init*(): Hash128 {.inline, noSideEffect.} =
  Fnv128Offset

func fnv128Mix*(h: var Hash128, s: string) {.noSideEffect.} =
  ## Mix every byte of `s` into the running hash.
  for c in s:
    fnv128Update(h, uint8(c))

func fnv128Mix*(h: var Hash128, other: Hash128) {.noSideEffect.} =
  ## Fold a sub-hash into the running hash by feeding its 16 bytes (LE).
  ## Lets us build a recursive tree-hash without needing a separate
  ## combine primitive.
  for i in 0 ..< 8:
    fnv128Update(h, uint8((other.lo shr (i * 8)) and 0xff'u64))
  for i in 0 ..< 8:
    fnv128Update(h, uint8((other.hi shr (i * 8)) and 0xff'u64))

func `==`*(a, b: Hash128): bool {.inline, noSideEffect.} =
  a.hi == b.hi and a.lo == b.lo
