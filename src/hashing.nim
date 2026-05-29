## hashing — canonical-content fingerprints for KdlEntry / KdlNode.
##
## Stored at parse time on KdlEntry.parseHash / KdlNode.parseHash so
## the preserve-mode emitter can detect unmodified subtrees in O(1)
## per node and reuse their original source bytes verbatim.
##
## Lives in its own module because both the parse path (cursor.nim
## populates parseHash via `hashEntry` + `hashNodeFromChildHashes`)
## and the emit path (Stage A/B KdlEmitter compares stored hash to
## fresh hash to decide splice-or-canonical) need it. Hosting in
## either parser or emitter creates a circular dependency.

import ./ast
import ./fnv
import ./intern

func feedValue(h: var Hash128, v: KdlValue, interner: Interner) =
  ## Zero-alloc fingerprint of a KdlValue. Hashes AST structure
  ## directly (kind discriminant + raw payload bytes) rather than
  ## rendering to a canonical string and hashing that.
  fnv128Update(h, 0x10'u8 + uint8(ord(v.kind)))  # kind discriminant
  if v.typeAnnotation != InvalidInterned:
    fnv128Update(h, 0x02'u8)
    interner.feedHash(v.typeAnnotation, h)
    fnv128Update(h, 0x03'u8)
  case v.kind
  of kvString:
    let n = uint64(v.strVal.len)
    for i in 0 ..< 8:
      fnv128Update(h, uint8((n shr (i * 8)) and 0xff'u64))
    for c in v.strVal: fnv128Update(h, uint8(c))
  of kvInt:
    let u = cast[uint64](v.intVal)
    for i in 0 ..< 8: fnv128Update(h, uint8((u shr (i * 8)) and 0xff'u64))
  of kvBigInt:
    for i in 0 ..< 8: fnv128Update(h, uint8((v.bigHi shr (i * 8)) and 0xff'u64))
    for i in 0 ..< 8: fnv128Update(h, uint8((v.bigLo shr (i * 8)) and 0xff'u64))
    fnv128Update(h, if v.bigNegative: 1'u8 else: 0'u8)
  of kvFloat:
    let u = cast[uint64](v.floatVal)
    for i in 0 ..< 8: fnv128Update(h, uint8((u shr (i * 8)) and 0xff'u64))
  of kvBool:
    fnv128Update(h, if v.boolVal: 1'u8 else: 0'u8)
  of kvNull:
    discard

func feedEntryInto*(h: var Hash128, e: KdlEntry, interner: Interner) =
  ## Fold an entry's content into a running hash.
  fnv128Update(h, 0x1f'u8)                       # US — entry framing
  case e.kind
  of keArgument:
    fnv128Update(h, 0x00'u8)
    feedValue(h, e.argValue, interner)
  of keProperty:
    fnv128Update(h, 0x01'u8)
    interner.feedHash(e.propName, h)
    fnv128Update(h, 0x3d'u8)
    feedValue(h, e.propValue, interner)

func hashEntry*(e: KdlEntry, interner: Interner): Hash128 =
  ## Canonical-content fingerprint of `e`. Stored on KdlEntry.parseHash
  ## at parse time; the preserving emitter compares against a fresh
  ## hash to decide whether the original source bytes are still valid.
  result = fnv128Init()
  feedEntryInto(result, e, interner)

func hashNodeFromChildHashes*(n: KdlNode, interner: Interner,
                              childHashes: openArray[Hash128]): Hash128 =
  ## Bottom-up node fingerprint using already-computed `childHashes`.
  ## Lets the parser hash each node once (linear cost across an entire
  ## parse pass) instead of recursing every time.
  result = fnv128Init()
  if n.typeAnnotation != InvalidInterned:
    fnv128Update(result, 0x02'u8)
    interner.feedHash(n.typeAnnotation, result)
    fnv128Update(result, 0x03'u8)
  interner.feedHash(n.name, result)
  for e in n.entries:
    feedEntryInto(result, e, interner)
  for ch in childHashes:
    fnv128Update(result, 0x1e'u8)
    fnv128Mix(result, ch)
