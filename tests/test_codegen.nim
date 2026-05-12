## Tests for codegen.nim — deriveDecode + parse[T] across primitive
## fields, nested objects, seqs, defaults, renames, skips, and at the
## seq[T] top-level shape.

import std/[strutils, unittest]

import ../src/ast
import ../src/codegen
import ../src/spans

# ---------------------------------------------------------------------------
# Type fixtures
# ---------------------------------------------------------------------------

type
  SimpleAttrs {.kdlNode: "simple".} = object
    name {.kdlAttr.}: string
    count {.kdlAttr.}: int
    enabled {.kdlAttr.}: bool

  WithArg {.kdlNode: "rule".} = object
    id {.kdlArg.}: string
    enabled {.kdlAttr.}: bool = false   # default → optional

  WithDefault {.kdlNode: "config".} = object
    threshold {.kdlAttr.}: int = 50
    label {.kdlAttr.}: string = "unset"

  WithRename {.kdlNode: "renamed".} = object
    apiKey {.kdlAttr, kdlRename: "api-key".}: string

  WithSkip {.kdlNode: "skipme".} = object
    keep {.kdlAttr.}: string
    nope {.kdlSkip.}: int

  Inner {.kdlNode: "inner".} = object
    value {.kdlAttr.}: int

  WithChild {.kdlNode: "outer".} = object
    label {.kdlAttr.}: string
    inner: Inner

  WithSeqChild {.kdlNode: "container".} = object
    label {.kdlAttr.}: string
    inner: seq[Inner]

deriveDecode(SimpleAttrs)
deriveDecode(WithArg)
deriveDecode(WithDefault)
deriveDecode(WithRename)
deriveDecode(WithSkip)
deriveDecode(Inner)
deriveDecode(WithChild)
deriveDecode(WithSeqChild)

template parseOk[T](src: string, body: untyped) =
  let r = decode[T](src)
  check r.isOk
  if r.isOk:
    let value {.inject.} = r.get
    body

suite "codegen: primitives as attributes":
  test "string + int + bool":
    parseOk[SimpleAttrs]("simple name=\"abc\" count=42 enabled=#true"):
      check value.name == "abc"
      check value.count == 42
      check value.enabled

  test "missing required attr surfaces as Err":
    let r = decode[SimpleAttrs]("simple name=\"abc\"")
    check r.isErr
    if r.isErr:
      check "missing required property" in r.getErr.hint

suite "codegen: positional args":
  test "node \"id\" enabled=true → id is the arg, enabled is the attr":
    parseOk[WithArg]("rule \"compaction\" enabled=#true"):
      check value.id == "compaction"
      check value.enabled

suite "codegen: pragma-supplied defaults":
  test "missing field uses the {.default.}":
    parseOk[WithDefault]("config"):
      check value.threshold == 50
      check value.label == "unset"

  test "supplied value overrides the default":
    parseOk[WithDefault]("config threshold=80 label=\"prod\""):
      check value.threshold == 80
      check value.label == "prod"

suite "codegen: kdlRename":
  test "kdl-side name differs from Nim field":
    parseOk[WithRename]("renamed api-key=\"sk-123\""):
      check value.apiKey == "sk-123"

suite "codegen: kdlSkip":
  test "skipped field is not parsed":
    parseOk[WithSkip]("skipme keep=\"hello\""):
      check value.keep == "hello"
      check value.nope == 0

suite "codegen: nested child node":
  test "single child is decoded":
    parseOk[WithChild]("outer label=\"x\" {\n  inner value=7\n}"):
      check value.label == "x"
      check value.inner.value == 7

  test "missing child stays at default":
    parseOk[WithChild]("outer label=\"x\""):
      check value.label == "x"
      check value.inner.value == 0

suite "codegen: seq[T] child":
  test "multiple inner nodes accumulate":
    let src = """
container label="dock" {
  inner value=1
  inner value=2
  inner value=3
}
"""
    parseOk[WithSeqChild](src):
      check value.label == "dock"
      check value.inner.len == 3
      check value.inner[0].value == 1
      check value.inner[1].value == 2
      check value.inner[2].value == 3

  test "zero inner nodes → empty seq":
    parseOk[WithSeqChild]("container label=\"empty\""):
      check value.label == "empty"
      check value.inner.len == 0

suite "codegen: parse[seq[T]] at top level":
  test "multiple sibling rules":
    let src = """
rule "a"
rule "b" enabled=#true
rule "c"
"""
    parseOk[seq[WithArg]](src):
      check value.len == 3
      check value[0].id == "a"
      check value[1].id == "b"
      check value[1].enabled
      check value[2].id == "c"

  test "zero sibling rules → empty seq":
    parseOk[seq[WithArg]](""):
      check value.len == 0

  test "non-matching nodes ignored":
    parseOk[seq[WithArg]]("other \"x\"\nrule \"y\""):
      check value.len == 1
      check value[0].id == "y"

# H8 fixture types must live at module scope: `deriveDecode` emits an
# exported proc, and `proc ... *` is invalid inside a `suite` block.
type
  Natural16 = uint16
  WidePrims {.kdlNode: "wide".} = object
    a {.kdlAttr.}: uint8
    b {.kdlAttr.}: int16
    c {.kdlAttr.}: Natural16   # alias

deriveDecode(WidePrims)

suite "codegen: H8 — non-string-allowlist primitives":
  # The previous typeNodeIsObject string-name allowlist missed types
  # like uint8 / Natural / int16 / aliases. After H8 they all classify
  # as primitives (fkAttr default) via getTypeImpl resolution.

  test "byte-/short-width primitives compile and decode":
    # Whether the kdlDecodeValue overload set covers each width is a
    # separate concern (we currently only ship int / int64 / float /
    # bool / string overloads). The C3-style "missing required"
    # behavior + the H8 classification just need to NOT route these
    # through fkChild (which would call kdlDecodeImpl on a primitive).
    # That misroute compiles only because of the bad classification;
    # post-H8, a missing value path reaches fkAttr and surfaces the
    # value-type mismatch cleanly. So a missing-everything input
    # surfaces missing-required errors (not an object-recursion mess).
    let r = decode[WidePrims]("wide")
    check r.isErr
    if r.isErr:
      check r.getErr.code == peTypeMissingRequired

suite "codegen: error reporting":
  test "type mismatch surfaces as Err":
    # `count` should be int; passing a string should fail
    let r = decode[SimpleAttrs]("simple name=\"x\" count=\"not-a-number\"")
    check r.isErr

  test "missing top-level node":
    let r = decode[WithArg]("notarule \"x\"")
    check r.isErr
