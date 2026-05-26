## Opt-in parseHash — verifies the new `preserveFormat` parameter on
## `parse()` skips ~all FNV-128 work when false (the default), and
## that `encode(doc, emPreserve)` fails loud when the consumer asks
## for preservation on a doc that wasn't parsed with hashes.

import std/[unittest, strutils]
import ../src/[parser, encode, ast, spans]

when defined(kdlHashStats):
  suite "parseHash opt-in — default skips hashing":
    test "parse(src) default sets ~0 hash work":
      kdlHashCallCount = 0
      let r = parse("rule \"a\" {\n  child \"b\"\n}")
      check r.isOk
      check kdlHashCallCount == 0

    test "parse(src, preserveFormat = true) DOES hash":
      kdlHashCallCount = 0
      let r = parse("rule \"a\" {\n  child \"b\"\n}", preserveFormat = true)
      check r.isOk
      check kdlHashCallCount > 0

suite "parseHash opt-in — encode emPreserve":
  test "emPreserve on no-hash doc fails loud":
    let r = parse("rule \"a\"\nrule \"b\"")    # default: no hashes
    check r.isOk
    var doc = r.get
    expect AssertionDefect:
      discard encode(doc, emPreserve)

  test "emPreserve on with-hash doc works":
    let r = parse("rule \"a\"\nrule \"b\"", preserveFormat = true)
    check r.isOk
    var doc = r.get
    let text = encode(doc, emPreserve)
    check text == "rule \"a\"\nrule \"b\""

  test "encode emPretty on no-hash doc still works":
    # emPretty / emCompact are canonical-only — don't need parseHashes.
    let r = parse("rule \"a\"")
    check r.isOk
    let text = encode(r.get, emPretty)
    check "rule" in text
