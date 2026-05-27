## Cycle 1 tracer bullet for the typed-direct path (issue #1).
##
## Tests the visitor-pattern architecture end-to-end with a HAND-WRITTEN
## ServiceBuilder visitor before macro generation lands. This proves the
## protocol works; later cycles replace the hand-written visitor with
## one emitted by deriveDecode[T].
##
## Acceptance for this cycle: parseInto[Service]("...") returns a
## populated Service with default values firing for missing fields.

import std/unittest
import ../src/[lexer, intern, numlit, spans, typed_parser]
import ../src/codegen   # for kdlNode, kdlArg, kdlProp pragmas

# Forward-declared helper for openArray[char] -> string comparisons.
proc toString(s: openArray[char]): string =
  result = newString(s.len)
  for i in 0 ..< s.len: result[i] = s[i]

type Service = object
  name: string
  port: int
  replicas: int
  enabled: bool

# Hand-written visitor for Service. State stack is just one frame
# (no nesting). Macro generation comes in cycle 2.
type ServiceBuilder = object
  result: Service
  inNode: bool

proc visitBeginNode(b: var ServiceBuilder, name: InternedStr,
               nameStr: openArray[char]): Result[void, ParseError] =
  if not (nameStr.len == 7 and nameStr.toString == "service"):
    return err[void, ParseError](initError(peParseUnexpected, pointSpan(StartPosition),
      "expected `service` node"))
  b.inNode = true
  # Defaults
  b.result.replicas = 1
  b.result.enabled = true
  ok(void, ParseError)

proc visitArg(b: var ServiceBuilder, idx: int, tok: Token,
         stream: TokenStream): Result[void, ParseError] =
  case tok.kind
  of tkString:
    b.result.name = stream.stringPayloads[tok.strIdx]
    ok(void, ParseError)
  else:
    err[void, ParseError](initError(peParseExpected, tok.span,
      "expected string visitArg for Service.name"))

proc visitProp(b: var ServiceBuilder, key: InternedStr, keyStr: openArray[char],
          tok: Token, stream: TokenStream): Result[void, ParseError] =
  case keyStr.toString
  of "port":
    if tok.kind != tkNumber:
      return err[void, ParseError](initError(peParseExpected, tok.span,
        "expected int for Service.port"))
    let n = stream.numberPayloads[tok.numIdx]
    let dec = decodeIntFromToken(n, tok.span)
    if dec.isErr: return err[void, ParseError](dec.getErr)
    b.result.port = int(dec.get)
  of "replicas":
    if tok.kind != tkNumber:
      return err[void, ParseError](initError(peParseExpected, tok.span,
        "expected int for Service.replicas"))
    let n = stream.numberPayloads[tok.numIdx]
    let dec = decodeIntFromToken(n, tok.span)
    if dec.isErr: return err[void, ParseError](dec.getErr)
    b.result.replicas = int(dec.get)
  of "enabled":
    if tok.kind != tkKeyword:
      return err[void, ParseError](initError(peParseExpected, tok.span,
        "expected bool for Service.enabled"))
    b.result.enabled = (tok.keyword == kwTrue)
  else:
    return err[void, ParseError](initError(peTypeUnknownField, tok.span,
      "Service has no field: " & keyStr.toString))
  ok(void, ParseError)

proc visitBeginChildren(b: var ServiceBuilder): Result[void, ParseError] =
  ok(void, ParseError)

proc visitEndChildren(b: var ServiceBuilder): Result[void, ParseError] =
  ok(void, ParseError)

proc visitEndNode(b: var ServiceBuilder): Result[void, ParseError] =
  b.inNode = false
  ok(void, ParseError)


suite "typed parser — tracer bullet (hand-written visitor)":
  test "parseInto[ServiceBuilder] decodes one service with all fields":
    let src = "service \"auth\" port=8443 replicas=3 enabled=#true"
    var builder = ServiceBuilder()
    let r = parseWith(src, builder)
    check r.isOk
    check builder.result.name == "auth"
    check builder.result.port == 8443
    check builder.result.replicas == 3
    check builder.result.enabled == true

  test "defaults fire when properties missing":
    let src = "service \"x\" port=80"
    var builder = ServiceBuilder()
    let r = parseWith(src, builder)
    check r.isOk
    check builder.result.name == "x"
    check builder.result.port == 80
    check builder.result.replicas == 1   # default
    check builder.result.enabled == true # default

# Cycle 2: same behavior, but the visitor is macro-generated from the
# type definition instead of hand-written. The user-facing API is
# parseInto[T](src) which constructs the visitor + runs the parser
# internally.

type ServiceTyped {.kdlNode: "service".} = object
  name {.kdlArg.}: string
  port {.kdlProp.}: int
  replicas {.kdlProp.}: int = 1
  enabled {.kdlProp.}: bool = true

deriveVisitor(ServiceTyped)

suite "typed parser — macro-generated visitor (cycle 2)":
  test "parseInto[ServiceTyped] decodes one service":
    let src = "service \"auth\" port=8443 replicas=3 enabled=#true"
    let r = parseInto[ServiceTyped](src)
    check r.isOk
    check r.get.name == "auth"
    check r.get.port == 8443
    check r.get.replicas == 3
    check r.get.enabled == true

  test "macro-generated visitor fires defaults":
    let src = "service \"x\" port=80"
    let r = parseInto[ServiceTyped](src)
    check r.isOk
    check r.get.name == "x"
    check r.get.port == 80
    check r.get.replicas == 1
    check r.get.enabled == true

# Cycle 3: seq[T] entry point — list of homogeneous nodes.
suite "typed parser — seq[T] (cycle 3)":
  test "parseInto[seq[ServiceTyped]] decodes two services":
    let src = "service \"a\" port=1\nservice \"b\" port=2\n"
    let r = parseInto[seq[ServiceTyped]](src)
    check r.isOk
    check r.get.len == 2
    check r.get[0].name == "a"
    check r.get[0].port == 1
    check r.get[1].name == "b"
    check r.get[1].port == 2

  test "parseInto[seq[ServiceTyped]] on empty input returns empty seq":
    let r = parseInto[seq[ServiceTyped]]("")
    check r.isOk
    check r.get.len == 0
