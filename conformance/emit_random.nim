## conformance/emit_random.nim — Tier-3 massive seeded-random corpus.
##
## The covering array (emit.nim) is the deterministic, explainable certification
## FLOOR. This is the other side: the same by-construction generators (gen.nim)
## sampled at scale with a pinned master seed → an arbitrarily large stream of
## `(input, expected)` fixtures. STATISTICAL breadth beyond the covering array's
## structure. Portable two ways: by value (ship the files) or by seed (ship this
## tool + the seed; every impl regenerates the identical stream).
##
## It is the oracle's reach made cheap: because `gen.nim` produces the expected
## value BY CONSTRUCTION (no parser in the loop), N can be 10⁷ and every pair is
## still a valid cross-language oracle. The same generators back the nkdl
## adapter's property test, so agreement there means this stream is sound.
##
## Kept separate from emit.nim so the deterministic floor stays stdlib-only;
## this tier imports gen.nim (→ proptest). Output is gitignored — regenerate on
## demand. NOTHING from `../src`.

import std/[os, json, strutils, parseopt]
import ./model
import ./gen

const DefaultSeed = 0xC0FFEE0001'u64

proc emitRandom*(outDir: string, n: int, seed: uint64): int =
  ## Emit `n` deterministic-from-`seed` random `(input, expected)` fixtures into
  ## `outDir/input/NNNNNN.kdl` + `outDir/expected/NNNNNN.json`. Returns the count.
  removeDir(outDir)
  createDir(outDir / "input")
  createDir(outDir / "expected")
  let docs = docSurface().sampleN(n, seed)
  for i in 0 ..< docs.len:
    let name = intToStr(i, 6)
    writeFile(outDir / "input" / name & ".kdl", docs[i].text)
    writeFile(outDir / "expected" / name & ".json", pretty(toJson(docs[i].doc)) & "\n")
  # a tiny manifest pins the provenance so a consumer can reproduce byte-for-byte
  writeFile(outDir / "manifest.json", pretty(%*{
    "tier": "random", "count": docs.len,
    "seed": "0x" & toHex(seed.BiggestInt, 12), "generator": "gen.docSurface",
  }) & "\n")
  docs.len

when isMainModule:
  # Usage: emit_random [--n=1000] [--seed=0x...] [--out=conformance/corpus/random]
  var n = 1000
  var seed = DefaultSeed
  var outDir = "conformance/corpus/random"
  for kind, key, val in getopt():
    if kind == cmdLongOption:
      case key
      of "n":    n = parseInt(val)
      of "seed": seed = cast[uint64](parseBiggestInt(val))
      of "out":  outDir = val
      else: discard
  let c = emitRandom(outDir, n, seed)
  echo "emitted ", c, " random fixtures (seed 0x", toHex(seed.BiggestInt, 12),
       ") to ", outDir
