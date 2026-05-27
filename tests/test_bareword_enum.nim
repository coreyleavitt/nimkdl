## Bareword enum values through the typed-direct visitor path.
##
## KDL allows bareword values: `action inject` is equivalent to
## `action "inject"`. The AST-walk decode path has always accepted both;
## the visitor path used to reject barewords (visitArg didn't have access
## to the source slice). The visitor now reads the bareword bytes from
## `stream.source` via the token span. Decoded result must match the
## quoted form byte-for-byte.

import std/unittest
import ../src/[codegen, nkdl, typed_parser]

kdl:
  type ActionKind = enum
    akInject = "inject"
    akDeny   = "deny"
    akWarn   = "warn"

  type Action {.kdlNode: "action".} = object
    kind {.kdlArg.}: ActionKind

suite "bareword enum values through visitor":

  test "arg position: bareword resolves to enum":
    let r = parseInto[Action]("action inject")
    check r.isOk
    check r.get.kind == akInject

  test "arg position: bareword matches quoted":
    let viaBareword = parseInto[Action]("action deny").get
    let viaQuoted   = parseInto[Action]("action \"deny\"").get
    check viaBareword == viaQuoted

  test "decode[T] also accepts barewords (regression for AST path)":
    let r = decode[Action]("action warn")
    check r.isOk
    check r.get.kind == akWarn

  test "decode[T] and parseInto[T] agree on bareword":
    let viaAst    = decode[Action]("action inject").get
    let viaDirect = parseInto[Action]("action inject").get
    check viaAst == viaDirect

  test "unknown bareword fails with peTypeEnumInvalid":
    let r = parseInto[Action]("action sideways")
    check r.isErr
    check r.getErr.code == peTypeEnumInvalid

kdl:
  type Mode = enum
    mRead  = "read"
    mWrite = "write"

  type Channel {.kdlNode: "channel".} = object
    name {.kdlArg.}: string
    mode {.kdlProp.}: Mode

suite "bareword enum values in prop position":

  test "prop bareword":
    let r = parseInto[Channel]("channel \"events\" mode=read")
    check r.isOk
    check r.get.mode == mRead

  test "prop bareword matches prop quoted":
    let bw = parseInto[Channel]("channel \"x\" mode=write").get
    let qq = parseInto[Channel]("channel \"x\" mode=\"write\"").get
    check bw == qq
