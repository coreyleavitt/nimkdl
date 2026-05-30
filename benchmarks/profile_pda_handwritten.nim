## PDA spike: hand-written single-pass fused parser for the Service
## shape on homogeneous-services-100.kdl. NO lexer pass, NO cursor,
## NO event stream, NO interner, NO Result wrapping. Just bytes →
## typed Service slots in one tight loop.
##
## This measures the architectural ceiling for what a macro-generated
## PDA could deliver. If hand-written can't hit ~30-38μs on the same
## fixture, the PDA approach is the wrong lever.
##
## Limits: handles only the exact homogeneous-services-100 shape
## (service "name" port=N replicas=N enabled=#true|#false). No escapes,
## no annotations, no children, no slashdash. Macro-generated PDA
## would be general; this hand-written stub is the ceiling check.

import std/[os, monotimes, times]

type
  Service = object
    name: string
    port: int
    replicas: int
    enabled: bool

  ParseError = object of CatchableError

template skipSpaces(src, pos: untyped) =
  while pos < src.len and src[pos] in {' ', '\t'}: inc pos

template skipNewlines(src, pos: untyped) =
  while pos < src.len and src[pos] in {' ', '\t', '\n', '\r'}: inc pos

proc parseInt(src: string, pos: var int): int {.inline.} =
  result = 0
  while pos < src.len and src[pos] in {'0'..'9'}:
    result = result * 10 + (src[pos].int - '0'.int)
    inc pos

proc parseServices(src: string): seq[Service] =
  var pos = 0
  result = newSeqOfCap[Service](100)
  while pos < src.len:
    skipNewlines(src, pos)
    if pos >= src.len: break
    # Expect bareword "service"
    let nameStart = pos
    while pos < src.len and src[pos] notin {' ', '\t', '\n', '\r', '=', '"'}:
      inc pos
    # Skip the space after the node name
    skipSpaces(src, pos)
    # Expect opening quote
    if pos >= src.len or src[pos] != '"':
      raise newException(ParseError, "expected string arg")
    inc pos
    let argStart = pos
    while pos < src.len and src[pos] != '"': inc pos
    let argEnd = pos
    inc pos  # closing quote
    var svc: Service
    svc.name = src[argStart..<argEnd]
    # Read 3 props in any order; dispatch by key first byte (p / r / e)
    while pos < src.len and src[pos] notin {'\n', '\r'}:
      skipSpaces(src, pos)
      if pos >= src.len or src[pos] in {'\n', '\r'}: break
      let keyFirst = src[pos]
      # advance past key bytes until '='
      while pos < src.len and src[pos] != '=': inc pos
      inc pos  # past '='
      case keyFirst
      of 'p':
        svc.port = parseInt(src, pos)
      of 'r':
        svc.replicas = parseInt(src, pos)
      of 'e':
        # Expect #true or #false
        if pos + 4 < src.len and src[pos..pos+4] == "#true":
          svc.enabled = true
          pos += 5
        elif pos + 5 < src.len and src[pos..pos+5] == "#false":
          svc.enabled = false
          pos += 6
      else: discard
    result.add(svc)
    # Skip to next newline
    while pos < src.len and src[pos] != '\n': inc pos

const Iters = 100_000

proc main() =
  let path = if paramCount() > 0: paramStr(1)
             else: "benchmarks/fixtures/homogeneous-services-100.kdl"
  let src = readFile(path)
  echo "fixture: ", path, " (", src.len, " bytes)"
  # Warmup
  for _ in 0 ..< 1000: discard parseServices(src)
  let t0 = getMonoTime()
  for _ in 0 ..< Iters: discard parseServices(src)
  let t1 = getMonoTime()
  let dt = inNanoseconds(t1 - t0).float / 1e9
  let usPer = dt / Iters.float * 1e6
  echo Iters, " iters in ", dt, "s = ", usPer, " μs/decode"
  # Sanity check
  let svcs = parseServices(src)
  echo "decoded ", svcs.len, " services; first = ", svcs[0]

main()
