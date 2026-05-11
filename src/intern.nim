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

proc intern*(interner: var Interner, s: string): InternedStr =
  ## Insert `s` (or return the existing handle if already interned).
  ## O(1) amortized for unique strings; O(k) on hash collisions where k
  ## is the collision-bucket size (rare in practice).
  let h = hash(s)
  if h in interner.byHash:
    for idx in interner.byHash[h]:
      let entry = interner.entries[int(idx)]
      case entry.kind
      of ekInline:
        if inlineEquals(entry, s):
          return InternedStr(idx)
      of ekHeap:
        if entry.heapHash == h and entry.payload == s:
          return InternedStr(idx)

  let newIdx = uint32(interner.entries.len)
  if s.len <= InlineCapacity:
    interner.entries.add(makeInline(s.toOpenArray(0, s.high)))
  else:
    interner.entries.add(Entry(kind: ekHeap, payload: s, heapHash: h))
  interner.byHash.mgetOrPut(h, @[]).add(newIdx)
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
    result = newString(int(entry.length))
    for i in 0 ..< int(entry.length):
      result[i] = entry.data[i]
  of ekHeap:
    result = entry.payload

func len*(interner: Interner): int {.inline.} =
  ## Number of distinct interned strings.
  interner.entries.len

func isInline*(interner: Interner, handle: InternedStr): bool =
  ## True if the entry is stored inline (no heap allocation for its bytes).
  ## Used by tests to verify the SBO is actually firing.
  let idx = int(uint32(handle))
  if idx >= interner.entries.len: return false
  interner.entries[idx].kind == ekInline
