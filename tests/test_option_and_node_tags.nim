## Tests for two extensions to the typed-schema layer:
##
## 1. `Option[T]` as a first-class field type. Supports any T —
##    primitive, enum, or nested object. Absent → `none`. Present →
##    `some(decoded)`. Encode: `some` emits normally; `none` omits.
##
## 2. `kdlReserved` extended to:
##    - kdlChild fields (assert child node carries declared tag)
##    - type-level pragma (top-level decode asserts the doc's node
##      carries the declared tag; encode emits with it)

import std/[options, strutils, unittest]

import ../src/ast
import ../src/codegen
import ../src/parser
import ../src/spans

# Test types ---------------------------------------------------------------

type
  OptPrim {.kdlNode: "opt".} = object
    name {.kdlAttr.}: string
    alias {.kdlAttr.}: Option[string]
    port {.kdlAttr.}: Option[int]
    flag {.kdlAttr.}: Option[bool]

  Inner {.kdlNode: "inner".} = object
    label {.kdlAttr.}: string

  OptChild {.kdlNode: "wrapper".} = object
    name {.kdlAttr.}: string
    extra {.kdlChild.}: Option[Inner]

  TaggedInner {.kdlNode: "ti".} = object
    note {.kdlAttr.}: string

  WithTaggedChild {.kdlNode: "outer".} = object
    spec {.kdlChild, kdlReserved: "version".}: TaggedInner

  Versioned {.kdlNode: "module", kdlReserved: "v2".} = object
    field {.kdlAttr.}: string

  TaggedOpt {.kdlNode: "tagged".} = object
    address {.kdlAttr, kdlReserved: "ipv4".}: Option[string]

deriveDecode(OptPrim)
deriveDecode(Inner)
deriveDecode(OptChild)
deriveDecode(TaggedInner)
deriveDecode(WithTaggedChild)
deriveDecode(Versioned)
deriveDecode(TaggedOpt)

deriveEncode(OptPrim)
deriveEncode(Inner)
deriveEncode(OptChild)
deriveEncode(TaggedInner)
deriveEncode(WithTaggedChild)
deriveEncode(Versioned)
deriveEncode(TaggedOpt)

# Option[T] -----------------------------------------------------------------

suite "Option[T] — primitives":
  test "absent attribute decodes to none":
    let r = decode[OptPrim]("opt name=\"x\"")
    check r.isOk
    if r.isOk:
      check r.get.alias.isNone
      check r.get.port.isNone
      check r.get.flag.isNone

  test "present attribute decodes to some":
    let r = decode[OptPrim](
      "opt name=\"x\" alias=\"a\" port=42 flag=#true")
    check r.isOk
    if r.isOk:
      check r.get.alias == some("a")
      check r.get.port == some(42)
      check r.get.flag == some(true)

  test "wrong-type present errors (not silent none)":
    let r = decode[OptPrim]("opt name=\"x\" port=\"not a number\"")
    check r.isErr

  test "encode emits some, omits none":
    let v = OptPrim(name: "x", alias: some("a"), port: none(int),
                    flag: some(false))
    let enc = encode(v)
    check enc.isOk
    if enc.isOk:
      check "name=x" in enc.get
      check "alias=a" in enc.get
      check "port" notin enc.get          # none → omitted
      check "flag=#false" in enc.get

  test "round-trip preserves none":
    let v = OptPrim(name: "x", alias: none(string),
                    port: none(int), flag: none(bool))
    let enc = encode(v)
    check enc.isOk
    if enc.isOk:
      let back = decode[OptPrim](enc.get)
      check back.isOk
      if back.isOk:
        check back.get.alias.isNone
        check back.get.port.isNone
        check back.get.flag.isNone

suite "Option[T] — nested object (kdlChild)":
  test "absent child decodes to none":
    let r = decode[OptChild]("wrapper name=\"x\"")
    check r.isOk
    if r.isOk:
      check r.get.extra.isNone

  test "present child decodes to some":
    let r = decode[OptChild]("wrapper name=\"x\" {\n  inner label=\"hi\"\n}")
    check r.isOk
    if r.isOk:
      check r.get.extra.isSome
      check r.get.extra.get.label == "hi"

  test "encode none omits child block contribution":
    let v = OptChild(name: "x", extra: none(Inner))
    let enc = encode(v)
    check enc.isOk
    if enc.isOk:
      check "inner" notin enc.get

  test "encode some emits child":
    let v = OptChild(name: "x", extra: some(Inner(label: "hi")))
    let enc = encode(v)
    check enc.isOk
    if enc.isOk:
      check "inner" in enc.get
      check "label=hi" in enc.get

suite "Option[T] + kdlReserved":
  test "absent option skips both tag check and content validation":
    let r = decode[TaggedOpt]("tagged")
    check r.isOk
    if r.isOk:
      check r.get.address.isNone

  test "present option triggers tag check":
    let bad = decode[TaggedOpt]("tagged address=\"1.2.3.4\"")  # no tag
    check bad.isErr
    if bad.isErr:
      check bad.getErr.code == peTypeReservedMismatch

  test "present option with correct tag + content passes":
    let r = decode[TaggedOpt]("tagged address=(ipv4)\"1.2.3.4\"")
    check r.isOk
    if r.isOk:
      check r.get.address == some("1.2.3.4")

  test "present option with bad content fails at Layer 1":
    let r = decode[TaggedOpt]("tagged address=(ipv4)\"banana\"")
    check r.isErr
    if r.isErr:
      check r.getErr.code == peReservedTypeInvalid

# kdlReserved on kdlChild ---------------------------------------------------

suite "kdlReserved on kdlChild":
  test "child node with matching tag decodes":
    let r = decode[WithTaggedChild](
      "outer {\n  (version)ti note=\"ok\"\n}")
    check r.isOk
    if r.isOk:
      check r.get.spec.note == "ok"

  test "child node without tag is rejected":
    let r = decode[WithTaggedChild](
      "outer {\n  ti note=\"ok\"\n}")
    check r.isErr
    if r.isErr:
      check r.getErr.code == peTypeReservedMismatch

  test "child node with wrong tag is rejected":
    let r = decode[WithTaggedChild](
      "outer {\n  (other)ti note=\"ok\"\n}")
    check r.isErr
    if r.isErr:
      check r.getErr.code == peTypeReservedMismatch

  test "encode emits child with declared tag":
    let v = WithTaggedChild(spec: TaggedInner(note: "ok"))
    let enc = encode(v)
    check enc.isOk
    if enc.isOk:
      check "(version)ti" in enc.get

# Type-level kdlReserved ----------------------------------------------------

suite "kdlReserved on type":
  test "decode requires top-level node to carry the declared tag":
    let r = decode[Versioned]("(v2)module field=\"ok\"")
    check r.isOk
    if r.isOk:
      check r.get.field == "ok"

  test "decode rejects untagged top-level":
    let r = decode[Versioned]("module field=\"ok\"")
    check r.isErr
    if r.isErr:
      check r.getErr.code == peTypeReservedMismatch

  test "decode rejects wrongly-tagged top-level":
    let r = decode[Versioned]("(v1)module field=\"ok\"")
    check r.isErr
    if r.isErr:
      check r.getErr.code == peTypeReservedMismatch

  test "encode emits the declared tag on the top-level node":
    let v = Versioned(field: "ok")
    let enc = encode(v)
    check enc.isOk
    if enc.isOk:
      check "(v2)module" in enc.get
