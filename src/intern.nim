## intern — small-buffer-optimized string interner.
##
## ## Why this exists
##
## Builtin rules + workspace config + scorecards + manifests all parse on
## daemon start. A typical KDL document has dozens to hundreds of distinct
## identifiers (node names, attribute keys), almost all <22 bytes — and
## most of them repeat (`rule`, `action`, `kind`, `template`, …). A naive
## representation heap-allocates a fresh `string` per token.
##
## This module gives the lexer and AST a uniform handle (`InternedStr`)
## that holds inline storage for short bytes and dedups longer ones by
## hash. The handle is a `distinct uint32` so it can never be confused
## with an owned `string`, and so equality on handles is cheap regardless
## of the underlying length.
##
## ## Layout
##
## `Entry` is an object variant with two branches:
##
##   ekInline:  22 bytes of inline data + 1 byte length
##   ekHeap:    16-byte string header + 8-byte hash
##
## Plus 1-byte discriminator → 32 bytes total per cell, half a cache line.
## Inline entries never touch the heap; heap entries dedup by hash so
## repeated identifiers reuse the same cell.
##
## ## Threading
##
## The interner is not thread-safe. Each parse runs on a single thread
## with its own interner; AST values referencing those interned handles
## must stay on that thread (or be deep-copied if crossing a boundary,
## which is what the daemon already does via the writer-loop pattern).

import std/[hashes, tables]

import ./fnv

const
  InlineCapacity* = 22
    ## Bytes available for inline storage. Picked so the case-object
    ## cell sits inside half a cache line (32 bytes) on 64-bit targets.

type
  InternedStr* = distinct uint32
    ## Handle into an Interner's entry table. `distinct` enforces that
    ## "interned" is a different concept from "owned string" — you can't
    ## accidentally pass an InternedStr where a `string` is expected.

  EntryKind = enum
    ekInline, ekHeap

  Entry = object
    case kind: EntryKind
    of ekInline:
      ## Inline branch. `length` ≤ InlineCapacity. Data past `length`
      ## is undefined and must not be read.
      data: array[InlineCapacity, char]
      length: uint8
    of ekHeap:
      ## Heap branch. `payload` is owned by the Entry; lifetime is the
      ## Interner's lifetime.
      payload: string
      heapHash: Hash

  Interner* = object
    entries: seq[Entry]
    # Dedup lookup. Keyed by hash; value is the seq of entry indices
    # that hash to that bucket. Single-element seqs are the common case
    # (collision rare); we walk the seq linearly on collision.
    byHash: Table[Hash, seq[uint32]]
    disabled*: bool
      ## When true, `intern()` no-ops and returns `InvalidInterned`.
      ## Set by callers (typed-direct parse) that read bytes from the
      ## source string directly and never need the InternedStr handle.
      ## Saves ~13% of CPU on typed parse (per perf record).

const InvalidInterned* = InternedStr(uint32.high)
  ## Sentinel handle. Lookups return this from invalid handles
  ## (zero-initialized struct, out-of-range index).

func `==`*(a, b: InternedStr): bool {.inline.} =
  uint32(a) == uint32(b)

func hash*(s: InternedStr): Hash {.inline.} =
  ## Handle hash. Cheap; not a content hash. Use `lookup` first if you
  ## need to hash the string value.
  hash(uint32(s))

func initInterner*(): Interner =
  ## A fresh empty interner. No pre-allocation — caller controls capacity
  ## via the surrounding allocator if it matters.
  ##
  ## Pre-sizing tried (commit 8e397a0+1) — `newSeqOfCap[Entry](source/16)`
  ## was net-neutral or worse: alloc cost cancels realloc savings on
  ## small/medium docs. Re-test if/when interner.entries grows to be
  ## a bigger fraction of profile.
  Interner(entries: @[], byHash: initTable[Hash, seq[uint32]]())

# ---------------------------------------------------------------------------
# Inline storage helpers
# ---------------------------------------------------------------------------

func inlineEquals(entry: Entry, s: openArray[char]): bool =
  ## Compare an inline-kind entry to a byte slice.
  if int(entry.length) != s.len: return false
  for i in 0 ..< s.len:
    if entry.data[i] != s[i]: return false
  true

func makeInline(s: openArray[char]): Entry =
  ## Build an inline entry. Caller must ensure `s.len <= InlineCapacity`.
  result = Entry(kind: ekInline, length: uint8(s.len))
  for i in 0 ..< s.len:
    result.data[i] = s[i]

# ---------------------------------------------------------------------------
# intern + lookup
# ---------------------------------------------------------------------------

proc intern*(interner: var Interner, s: openArray[char]): InternedStr =
  ## Insert `s` (or return the existing handle if already interned).
  ## O(1) amortized for unique strings; O(k) on hash collisions where k
  ## is the collision-bucket size (rare in practice).
  ##
  ## Takes `openArray[char]` so callers can pass a slice into the lexer
  ## source without allocating an intermediate string. The heap path
  ## still allocates one string for the Entry payload.
  ##
  ## When `interner.disabled` is true, returns `InvalidInterned`
  ## immediately. Used by the typed-direct path where the consumer
  ## reads bytes from source directly and never needs the handle.
  if interner.disabled: return InvalidInterned
  let h = hash(s)
  if h in interner.byHash:
    for idx in interner.byHash[h]:
      let entry = interner.entries[int(idx)]
      case entry.kind
      of ekInline:
        if inlineEquals(entry, s):
          return InternedStr(idx)
      of ekHeap:
        if entry.heapHash == h and entry.payload.len == s.len:
          var same = true
          for i in 0 ..< s.len:
            if entry.payload[i] != s[i]:
              same = false
              break
          if same: return InternedStr(idx)

  doAssert interner.entries.len < int(uint32.high),
    "Interner exhausted: 4G distinct strings interned. The next handle " &
    "would alias InvalidInterned and silently corrupt lookups."
  let newIdx = uint32(interner.entries.len)
  if s.len <= InlineCapacity:
    interner.entries.add(makeInline(s))
  else:
    var payload = newString(s.len)
    for i in 0 ..< s.len: payload[i] = s[i]
    interner.entries.add(Entry(kind: ekHeap, payload: payload, heapHash: h))
  # `mgetOrPut(h, @[]).add(newIdx)` eagerly evaluates the `@[]` default
  # on every call — even when the key is already present — turning each
  # intern() into one extra dead seq allocation. Split into existence
  # check + targeted insert/append to skip that.
  if h in interner.byHash:
    interner.byHash[h].add(newIdx)
  else:
    interner.byHash[h] = @[newIdx]
  result = InternedStr(newIdx)

func lookup*(interner: Interner, handle: InternedStr): string =
  ## Return the string value behind `handle`. Allocates a fresh string
  ## for inline entries (copies inline bytes out); heap entries return a
  ## copy too — both because the result is a normal Nim string and
  ## holding a reference into the entry would be lifetime-coupled to
  ## the interner.
  let idx = int(uint32(handle))
  if handle == InvalidInterned or idx >= interner.entries.len:
    return ""
  let entry = interner.entries[idx]
  case entry.kind
  of ekInline:
    let n = int(entry.length)
    result = newString(n)
    if n > 0:
      # Bulk copy at runtime; byte-loop fallback inside Nim's VM
      # because `copyMem` is `importc`'d from C and isn't VM-callable
      # — `embed[T]` runs `lookup` at compile time and would otherwise
      # error with "cannot 'importc' variable at compile time".
      when nimvm:
        for i in 0 ..< n: result[i] = entry.data[i]
      else:
        copyMem(addr result[0], unsafeAddr entry.data[0], n)
  of ekHeap:
    result = entry.payload

func entryByteLenOf*(interner: Interner, handle: InternedStr): int {.inline.} =
  ## Length of the interned bytes — zero alloc.
  let idx = int(uint32(handle))
  if handle == InvalidInterned or idx >= interner.entries.len: return 0
  case interner.entries[idx].kind
  of ekInline: int(interner.entries[idx].length)
  of ekHeap:   interner.entries[idx].payload.len

func entryByteAtOf*(interner: Interner, handle: InternedStr,
                    i: int): char {.inline.} =
  ## Byte at index `i` — zero alloc.
  let idx = int(uint32(handle))
  case interner.entries[idx].kind
  of ekInline: interner.entries[idx].data[i]
  of ekHeap:   interner.entries[idx].payload[i]

func len*(interner: Interner): int {.inline.} =
  ## Number of distinct interned strings.
  interner.entries.len

func entryByteLen(e: Entry): int {.inline.} =
  case e.kind
  of ekInline: int(e.length)
  of ekHeap:   e.payload.len

func entryByteAt(e: Entry, i: int): char {.inline.} =
  case e.kind
  of ekInline: e.data[i]
  of ekHeap:   e.payload[i]

func feedHash*(interner: Interner, handle: InternedStr,
               h: var Hash128) =
  ## Fold an interned string's bytes into `h` (FNV-1a 128) without
  ## allocating an intermediate `string`. Use in hot paths where
  ## `fnv128Mix(h, lookup(handle))` would build and discard a temp.
  ## InvalidInterned (and any out-of-range handle) is a no-op — same
  ## semantics as `equals(handle, "")`.
  let idx = int(uint32(handle))
  if handle == InvalidInterned or idx >= interner.entries.len:
    return
  let e = interner.entries[idx]
  case e.kind
  of ekInline:
    for i in 0 ..< int(e.length):
      fnv128Update(h, uint8(e.data[i]))
  of ekHeap:
    for c in e.payload:
      fnv128Update(h, uint8(c))

func equals*(interner: Interner, handle: InternedStr,
             s: openArray[char]): bool =
  ## Compare `handle`'s interned bytes against `s` without allocating.
  ## Use in hot paths where `lookup(...) == s` would build a temporary
  ## string just to compare against a literal/known buffer.
  let idx = int(uint32(handle))
  if handle == InvalidInterned or idx >= interner.entries.len:
    return s.len == 0
  let e = interner.entries[idx]
  if entryByteLen(e) != s.len: return false
  for i in 0 ..< s.len:
    if entryByteAt(e, i) != s[i]: return false
  true

func equalsAcross*(aInterner: Interner, aHandle: InternedStr,
                  bInterner: Interner, bHandle: InternedStr): bool =
  ## Compare two handles drawn from different interners without
  ## allocating an intermediate `string`. The hot path in
  ## `ast.nodeEqual` / `docEqual` calls this once per cross-doc
  ## name/property/type-annotation comparison.
  let aIdx = int(uint32(aHandle))
  let bIdx = int(uint32(bHandle))
  let aValid = aHandle != InvalidInterned and aIdx < aInterner.entries.len
  let bValid = bHandle != InvalidInterned and bIdx < bInterner.entries.len
  if not aValid or not bValid:
    return aValid == bValid  # both invalid → equal (both "")
  let aE = aInterner.entries[aIdx]
  let bE = bInterner.entries[bIdx]
  let n = entryByteLen(aE)
  if entryByteLen(bE) != n: return false
  for i in 0 ..< n:
    if entryByteAt(aE, i) != entryByteAt(bE, i): return false
  true

func isInline*(interner: Interner, handle: InternedStr): bool =
  ## True if the entry is stored inline (no heap allocation for its bytes).
  ## Used by tests to verify the SBO is actually firing.
  let idx = int(uint32(handle))
  if idx >= interner.entries.len: return false
  interner.entries[idx].kind == ekInline
