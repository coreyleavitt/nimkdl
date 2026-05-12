## Tests for the `kdlReserved` pragma on `deriveDecode` fields.
##
## Layer 3 of the reserved-type story: typed schemas declare the tag
## they expect on a value, and the macro emits a check that the source
## value's typeAnnotation matches. Layer 1 already validates the tag's
## content at parse time; Layer 3 asserts the consumer's expected
## namespace.

import std/[strutils, unittest]

import ../src/codegen
import ../src/spans

type
  Cfg {.kdlNode: "cfg".} = object
    endpoint {.kdlAttr, kdlReserved: "url".}: string

  Server {.kdlNode: "server".} = object
    host {.kdlArg, kdlReserved: "ipv4".}: string

  Mixed {.kdlNode: "mixed".} = object
    id {.kdlAttr, kdlReserved: "uuid".}: string
    plain {.kdlAttr.}: string   ## no kdlReserved → any tag (or none) OK

deriveDecode(Cfg)
deriveDecode(Server)
deriveDecode(Mixed)

suite "kdlReserved pragma (Layer 3)":
  test "field with declared (url) decodes when source carries it":
    let r = decode[Cfg]("cfg endpoint=(url)\"http://example.com\"")
    check r.isOk
    if r.isOk:
      check r.get.endpoint == "http://example.com"

  test "field with declared (url) errors when source has bare value":
    # No tag on the source → consumer's expected tag is missing.
    let r = decode[Cfg]("cfg endpoint=\"http://example.com\"")
    check r.isErr
    if r.isErr:
      check r.getErr.code == peTypeReservedMismatch
      check "url" in r.getErr.hint

  test "field with declared (url) errors when source has wrong tag":
    let r = decode[Cfg]("cfg endpoint=(uri)\"http://example.com\"")
    check r.isErr
    if r.isErr:
      check r.getErr.code == peTypeReservedMismatch
      check "url" in r.getErr.hint
      check "uri" in r.getErr.hint

  test "pragma applies on positional args (kdlArg)":
    let okay = decode[Server]("server (ipv4)\"192.0.2.1\"")
    check okay.isOk
    let bad = decode[Server]("server \"192.0.2.1\"")
    check bad.isErr
    if bad.isErr:
      check bad.getErr.code == peTypeReservedMismatch

  test "fields without kdlReserved accept any tag (or none)":
    # `plain` has no pragma → caller can put anything there.
    let r = decode[Mixed](
      "mixed id=(uuid)\"f81d4fae-7dec-11d0-a765-00a0c91e6bf6\" plain=\"x\"")
    check r.isOk

  test "layer-1 invalid content still fires before layer-3 check":
    # `(ipv4)"banana"` is layer-1-invalid; the parse-time validator
    # rejects before we ever reach the pragma check.
    let r = decode[Server]("server (ipv4)\"banana\"")
    check r.isErr
    if r.isErr:
      check r.getErr.code == peReservedTypeInvalid

  test "embed[T] surfaces pragma mismatches at compile time":
    # Sanity: the macro emits a `{.noSideEffect.}` proc and the
    # check uses standard Nim conditional branches, so the whole
    # decode chain remains VM-callable. We can't test compile-time
    # FAILURE within unittest, but we can prove a passing compile-time
    # decode works to anchor the property.
    const cfgSrc = "cfg endpoint=(url)\"http://example.com\""
    const decoded = decode[Cfg](cfgSrc)
    check decoded.isOk
    if decoded.isOk:
      check decoded.get.endpoint == "http://example.com"
