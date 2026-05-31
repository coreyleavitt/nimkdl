## Token compaction tests.
##
## Acceptance: Span ≤ 8 bytes, Token ≤ 32 bytes. These shapes let
## ~5× more tokens fit per L1 cache line vs the prior 128-byte token,
## which is the architectural justification for the refactor.

import std/[strutils, unittest]

import spans
import lexer
import intern


suite "token compaction — size targets":

  test "Span is at most 8 bytes":
    # Prior shape: 48 bytes (two Position{line,col,offset} of 24 each).
    # New shape: (offset: uint32, length: uint16) → 6 bytes natural,
    # padded to 8 for alignment. Line/col reconstructed lazily via LineMap.
    check sizeof(Span) <= 8

  test "Token is at most 32 bytes (half cache line)":
    # Prior shape: 128 bytes (2 cache lines). New shape moves heavy
    # payload (strings, error structs, number text) to lexer-owned side
    # tables and stores a u32 index in the token.
    check sizeof(Token) <= 32


suite "token compaction — boundary mitigations":

  test "source up to uint32.high bytes is accepted":
    # The compact Span stores offsets as uint32 (~4 GiB max source).
    # Sources at or below uint32.high must be accepted.
    check sourceSizeOk(0).isOk
    check sourceSizeOk(1024).isOk
    check sourceSizeOk(int(uint32.high)).isOk

  test "source larger than uint32.high is rejected with a clear error":
    # Past the boundary the lexer must error up front rather than
    # silently truncating offsets and producing corrupted spans.
    let res = sourceSizeOk(int(uint32.high) + 1)
    check res.isErr
    check res.getErr.code == peOther  # or a dedicated code if added
    check "source too large" in res.getErr.hint or
          "exceeds" in res.getErr.hint

  test "single token longer than 64KiB survives":
    # Pre-mitigation: Span.lengthRaw was uint16, capping tokens at
    # 65535 bytes. A multiline string longer than that would silently
    # truncate the length and produce a corrupted span. After promoting
    # to uint32, large tokens parse correctly.
    var s = "\"\"\"\n"
    s.add(repeat("x", 70_000))  # 70 KiB of body, well past the old uint16 cap
    s.add("\n\"\"\"")
    let stream = lex(s)
    # Find the string token. There should be exactly one (plus EOF).
    var stringTok: Token
    var found = false
    for t in stream.tokens:
      if t.kind == tkString:
        stringTok = t
        found = true
        break
    check found
    if found:
      # The span MUST cover the whole token; truncation to uint16 would
      # give length ≤ 65535 and we'd silently lose part of the value.
      check stringTok.span.length >= 70_000
      # And the payload must be the full body bytes.
      check stream.stringPayloads[stringTok.strIdx].len == 70_000
