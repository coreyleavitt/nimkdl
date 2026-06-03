## test_fieldpath.nim — typed-decode field-path errors (rfc §10).
##
## When decode[T] fails inside a nested child object, the ParseError carries the
## chain of child field names (outermost-first), so a diagnostic can point at
## `outer.sect` rather than just a bare span. Enriched at each child-decode
## boundary as the error unwinds.

import std/[unittest, strutils]
import ../src/api
import ../src/kdl_block
import ../src/pragmas
import ../src/spans     # ParseError.fieldPath / formatError

kdl:
  type Inner {.kdlNode: "inner".} = object
    port {.kdlProp.}: int
  type Outer {.kdlNode: "outer".} = object
    sect {.kdlChild.}: Inner
  type ArgHost {.kdlNode: "argh".} = object
    count {.kdlArg.}: int

suite "decode — field-path errors (rfc §10)":
  test "nested decode failure carries child + leaf field path":
    let r = decode[Outer]("outer {\n  inner port=\"notanint\"\n}")
    check r.isErr
    check r.getErr.fieldPath == @["sect", "port"]

  test "field path renders in formatError":
    let src = "outer {\n  inner port=\"x\"\n}"
    let r = decode[Outer](src)
    check r.isErr
    check "in field: sect.port" in formatError(r.getErr, src)

  test "top-level leaf failure carries just the leaf field":
    let r = decode[Inner]("inner port=\"x\"")
    check r.isErr
    check r.getErr.fieldPath == @["port"]

  test "leaf kdlArg failure carries the arg field name":
    let r = decode[ArgHost]("argh \"notnum\"")
    check r.isErr
    check r.getErr.fieldPath == @["count"]

  test "successful decode leaves the field path empty":
    let r = decode[Outer]("outer {\n  inner port=8\n}")
    check r.isOk
    check r.get.sect.port == 8
