## Cycle E.1 — encodeFrom[T] tracer.
##
## Acceptance: encodeFrom[T](v) produces byte-identical output to the
## legacy `encode[T](v, emPretty).get` path (value → KdlNode → KdlDoc →
## string) for a simple object type. Architectural symmetry with the
## decode-side win: parseInto[T] skipped KdlDoc, encodeFrom[T] skips
## KdlNode + KdlDoc.

import std/[strutils, unittest]

import ../src/[ast, codegen, encode, reserved, spans]

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
    check viaDirect.isOk
    check viaLegacy.get == viaDirect.get

  test "Service with default-valued props: direct == legacy":
    let s = Service(name: "api", port: 80)  # replicas + enabled default
    let viaLegacy = encode(s, emPretty)
    check viaLegacy.isOk
    check encodeFrom(s).get == viaLegacy.get

  test "Service with name needing quoting (contains space)":
    let s = Service(name: "my service", port: 443)
    let viaLegacy = encode(s, emPretty)
    check viaLegacy.isOk
    check encodeFrom(s).get == viaLegacy.get

# Cycle E.5 — children blocks
type Action {.kdlNode: "action".} = object
  tmpl {.kdlArg, kdlRename: "template".}: string
type Server {.kdlNode: "server".} = object
  name {.kdlArg.}: string
  actions {.kdlChild.}: seq[Action]

deriveEncode(Action)
deriveEncode(Server)

suite "encodeFrom[T] children blocks (cycle E.5)":

  test "Server with seq[Action] children — direct matches legacy":
    let s = Server(name: "web", actions: @[
      Action(tmpl: "log"),
      Action(tmpl: "alert")])
    let viaLegacy = encode(s, emPretty)
    check viaLegacy.isOk
    check encodeFrom(s).get == viaLegacy.get

  test "Server with empty children seq emits no block":
    let s = Server(name: "minimal", actions: @[])
    let viaLegacy = encode(s, emPretty)
    check viaLegacy.isOk
    check encodeFrom(s).get == viaLegacy.get

# Cycle E.4 — Option[T] fields
type WithOpt {.kdlNode: "task".} = object
  name {.kdlArg.}: string
  retries {.kdlProp.}: Option[int]
  desc {.kdlProp.}: Option[string]

deriveEncode(WithOpt)

suite "encodeFrom[T] Option[T] (cycle E.4)":

  test "Option some(int) emits prop=value":
    let t = WithOpt(name: "build", retries: some(3), desc: none(string))
    let viaLegacy = encode(t, emPretty)
    check viaLegacy.isOk
    check encodeFrom(t).get == viaLegacy.get

  test "Option none — prop is omitted":
    let t = WithOpt(name: "lint", retries: none(int), desc: none(string))
    let viaLegacy = encode(t, emPretty)
    check viaLegacy.isOk
    check encodeFrom(t).get == viaLegacy.get

  test "Option some(string)":
    let t = WithOpt(name: "deploy", retries: none(int),
                    desc: some("rollout"))
    let viaLegacy = encode(t, emPretty)
    check viaLegacy.isOk
    check encodeFrom(t).get == viaLegacy.get

# Cycle E.6 — kdlReserved tag emission + validation
type Tagged {.kdlNode: "tagged".} = object
  bindAddr {.kdlProp, kdlReserved: "ipv4".}: string

deriveEncode(Tagged)

suite "encodeFrom[T] kdlReserved (cycle E.6)":

  test "valid ipv4 emits `(ipv4)` tag prefix":
    let t = Tagged(bindAddr: "192.0.2.1")
    let viaLegacy = encode(t, emPretty)
    check viaLegacy.isOk
    check encodeFrom(t).get == viaLegacy.get

  test "round-trips through parser + decode":
    let t = Tagged(bindAddr: "10.0.0.1")
    let txt = encodeFrom(t).get
    check "(ipv4)" in txt

  test "invalid ipv4 errors (Layer 1 validation fires in direct path)":
    let bad = Tagged(bindAddr: "not-an-ip")
    let r = encodeFrom(bad)
    check r.isErr
    check r.getErr.code == peReservedTypeInvalid

suite "encodeFrom[T] string escaping (cycle E.3)":

  proc roundTripsEqual(s: Service) =
    let viaLegacy = encode(s, emPretty)
    check viaLegacy.isOk
    let viaDirect = encodeFrom(s)
    check viaDirect.isOk
    check viaDirect.get == viaLegacy.get

  test "name with embedded quote — escapes match legacy":
    roundTripsEqual(Service(name: "with \"quote\"", port: 1))

  test "name with backslash":
    roundTripsEqual(Service(name: "back\\slash", port: 2))

  test "name with newline":
    roundTripsEqual(Service(name: "two\nlines", port: 3))

  test "name with tab + cr":
    roundTripsEqual(Service(name: "tab\there\rand cr", port: 4))

  test "name with control byte (\\x07 bell)":
    roundTripsEqual(Service(name: "bell\x07char", port: 5))

  test "name with NUL byte":
    roundTripsEqual(Service(name: "with\x00nul", port: 6))

  test "empty string":
    roundTripsEqual(Service(name: "", port: 7))

  test "name that looks like a reserved keyword (#true literal text)":
    roundTripsEqual(Service(name: "true", port: 8))

  test "name with non-ASCII utf8 (☃ snowman)":
    roundTripsEqual(Service(name: "snow☃man", port: 9))
