## Cycle E.1 — encodeFrom[T] tracer.
##
## Acceptance: encodeFrom[T](v) produces byte-identical output to the
## legacy `encode[T](v, emPretty).get` path (value → KdlNode → KdlDoc →
## string) for a simple object type. Architectural symmetry with the
## decode-side win: parseInto[T] skipped KdlDoc, encodeFrom[T] skips
## KdlNode + KdlDoc.

import std/unittest

import ../src/[ast, codegen, encode, spans]

type Service {.kdlNode: "service".} = object
  name {.kdlArg.}: string
  port {.kdlProp.}: int
  replicas {.kdlProp.}: int = 1
  enabled {.kdlProp.}: bool = true

deriveEncode(Service)

suite "encodeFrom[T] tracer (cycle E.1)":

  test "single Service value: direct encode matches legacy KdlDoc encode":
    let s = Service(name: "web", port: 8080, replicas: 2, enabled: true)
    let viaLegacy = encode(s, emPretty)
    check viaLegacy.isOk
    let viaDirect = encodeFrom(s)
    check viaLegacy.get == viaDirect

  test "Service with default-valued props: direct == legacy":
    let s = Service(name: "api", port: 80)  # replicas + enabled default
    let viaLegacy = encode(s, emPretty)
    check viaLegacy.isOk
    check encodeFrom(s) == viaLegacy.get

  test "Service with name needing quoting (contains space)":
    let s = Service(name: "my service", port: 443)
    let viaLegacy = encode(s, emPretty)
    check viaLegacy.isOk
    check encodeFrom(s) == viaLegacy.get
