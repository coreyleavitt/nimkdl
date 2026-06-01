## conformance/tests/test_emit_random.nim — Tier-3 random emitter (proptest-gated).
##
## The massive random corpus must be REPRODUCIBLE: the same (seed, n) regenerates
## the identical byte stream, which is what makes it portable by seed rather than
## by shipping millions of files. (Soundness — that nkdl agrees with each random
## fixture — is covered by the adapter's property test over the same generators.)

import std/[unittest, os]
import ../emit_random

suite "Tier-3 — seeded-random corpus emitter":

  test "same (seed, n) regenerates the identical byte stream":
    let d1 = getTempDir() / "nkdl_rand_a"
    let d2 = getTempDir() / "nkdl_rand_b"
    check emitRandom(d1, 24, 0xABCDEF'u64) == 24
    check emitRandom(d2, 24, 0xABCDEF'u64) == 24
    check readFile(d1 / "input" / "000000.kdl") == readFile(d2 / "input" / "000000.kdl")
    check readFile(d1 / "expected" / "000023.json") == readFile(d2 / "expected" / "000023.json")
    check readFile(d1 / "manifest.json") == readFile(d2 / "manifest.json")

  test "a different seed yields a different stream":
    let d1 = getTempDir() / "nkdl_rand_c"
    let d2 = getTempDir() / "nkdl_rand_d"
    discard emitRandom(d1, 24, 0x1111'u64)
    discard emitRandom(d2, 24, 0x2222'u64)
    check readFile(d1 / "input" / "000000.kdl") != readFile(d2 / "input" / "000000.kdl")
