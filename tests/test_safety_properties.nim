## Stage F1-F2 — safety properties.
##
## - **P11: deriveDecode never crashes on arbitrary bytes.** Random
##   string input goes through `decode[T]`; the contract is: returns
##   Ok or Err, never raises, never IndexDefects, never infinite-
##   loops.
## - **P12: emitter never produces unparseable bytes** (lands in F2).
##
## These tests run only when `NKDL_PROPTEST=1` is set so the default
## `nimble test` (and CI without the proptest dep) stays self-
## contained. Local dev: `milpa fetch` then
## `NKDL_PROPTEST=1 nimble test`.

import std/unittest

import proptest

import ../src/api
import ../src/kdl_block
import ../src/pragmas

kdl:
  type Service {.kdlNode: "service".} = object
    name {.kdlArg.}: string
    port {.kdlProp.}: int
    enabled {.kdlProp.}: bool

suite "P11 — deriveDecode never crashes on arbitrary bytes":

  property "decode[Service] returns Ok or Err for any string input":
    with Settings(maxExamples: 200, testId: "p11-decode-service")
    given src in strings(0, 200)
    let r = decode[Service](src)
    ensure r.isOk or r.isErr

  property "decode[Service] survives KDL-syntax-rich byte alphabets":
    # Bias the alphabet toward characters that trigger KDL-special
    # lex paths: whitespace control codes, braces, slashes, quotes,
    # backslashes, equals, hash, semicolons, parens. This is where
    # crashes hide if any error-path is missing.
    with Settings(maxExamples: 300, testId: "p11-decode-service-kdl-rich")
    given src in strings(intervals([
      (0x09'i32, 0x0d'i32),    # TAB, LF, VT, FF, CR
      (0x20'i32, 0x7e'i32),    # printable ASCII (brackets, quotes, etc.)
      (0x00a0'i32, 0x00ff'i32) # Latin-1 supplement
    ]), 0, 200)
    let r = decode[Service](src)
    ensure r.isOk or r.isErr

  property "decode[seq[Service]] never crashes on arbitrary input":
    with Settings(maxExamples: 200, testId: "p11-decode-seq-service")
    given src in strings(0, 200)
    let r = decode[seq[Service]](src)
    ensure r.isOk or r.isErr

  property "decodeAll[seq[Service]] never crashes on arbitrary input":
    # decodeAll's recovery loop adds an additional crash surface
    # (checkpoint replay + skip mid-stream). Cover it explicitly.
    with Settings(maxExamples: 200, testId: "p11-decode-all")
    given src in strings(0, 200)
    let pair = decodeAll[seq[Service]](src)
    ensure pair.value.len >= 0  # no exception escaped the recovery loop
