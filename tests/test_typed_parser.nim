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

proc beginNode(b: var ServiceBuilder, name: InternedStr,
               nameStr: openArray[char]): Result[void, ParseError] =
  if not (nameStr.len == 7 and nameStr.toString == "service"):
    return err[void, ParseError](initError(peParseUnexpected, pointSpan(StartPosition),
      "expected `service` node"))
  b.inNode = true
  # Defaults
  b.result.replicas = 1
  b.result.enabled = true
  ok(void, ParseError)

proc arg(b: var ServiceBuilder, idx: int, tok: Token,
         stream: TokenStream): Result[void, ParseError] =
  case tok.kind
  of tkString:
    b.result.name = stream.stringPayloads[tok.strIdx]
    ok(void, ParseError)
  else:
    err[void, ParseError](initError(peParseExpected, tok.span,
      "expected string arg for Service.name"))

proc prop(b: var ServiceBuilder, key: InternedStr, keyStr: openArray[char],
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

proc beginChildren(b: var ServiceBuilder): Result[void, ParseError] =
  ok(void, ParseError)

proc endChildren(b: var ServiceBuilder): Result[void, ParseError] =
  ok(void, ParseError)

proc endNode(b: var ServiceBuilder): Result[void, ParseError] =
  b.inNode = false
  ok(void, ParseError)


suite "typed parser — tracer bullet":
  test "parseInto[ServiceBuilder] decodes one service with all fields":
    let src = "service \"auth\" port=8443 replicas=3 enabled=#true"
    var builder = ServiceBuilder()
    let r = parseInto(src, builder)
    check r.isOk
    check builder.result.name == "auth"
    check builder.result.port == 8443
    check builder.result.replicas == 3
    check builder.result.enabled == true

  test "defaults fire when properties missing":
    let src = "service \"x\" port=80"
    var builder = ServiceBuilder()
    let r = parseInto(src, builder)
    check r.isOk
    check builder.result.name == "x"
    check builder.result.port == 80
    check builder.result.replicas == 1   # default
    check builder.result.enabled == true # default
