## Option[CustomObject] kdlChild through the typed-direct visitor path.
##
## Until gap 2 closed, the visitor silently dropped Option[Inner] children
## (always left as `none(Inner)`); only decode[T]'s AST-walk path honored
## them. Now the visitor tracks per-slot `<field>_present` and commits
## `some(slot.result)` on visitEndChildren if the child block was seen.

import std/[options, unittest]
import ../src/[codegen, nkdl, typed_parser]

kdl:
  type Action {.kdlNode: "action".} = object
    tmpl {.kdlArg, kdlRename: "template".}: string

  type Rule {.kdlNode: "rule".} = object
    id {.kdlArg.}: string
    action {.kdlChild.}: Option[Action]

suite "Option[CustomObject] kdlChild via visitor":

  test "present child: parseInto wraps in some(...)":
    let src = "rule \"compaction\" {\n  action \"log\"\n}"
    let r = parseInto[Rule](src)
    check r.isOk
    check r.get.action.isSome
    check r.get.action.get.tmpl == "log"

  test "absent child: parseInto leaves none(Action)":
    let r = parseInto[Rule]("rule \"compaction\"")
    check r.isOk
    check r.get.action.isNone

  test "empty children block: still none":
    let r = parseInto[Rule]("rule \"compaction\" {\n}")
    check r.isOk
    check r.get.action.isNone

  test "decode[T] and parseInto[T] agree when child present":
    let src = "rule \"x\" {\n  action \"alert\"\n}"
    let viaAst    = decode[Rule](src).get
    let viaDirect = parseInto[Rule](src).get
    check viaAst.action.isSome
    check viaDirect.action.isSome
    check viaAst.action.get == viaDirect.action.get

  test "decode[T] and parseInto[T] agree when child absent":
    let src = "rule \"x\""
    let viaAst    = decode[Rule](src).get
    let viaDirect = parseInto[Rule](src).get
    check viaAst.action.isNone
    check viaDirect.action.isNone

# Mixed: required seq[Child] + optional singular Child in the same type.
kdl:
  type Hook {.kdlNode: "hook".} = object
    cmd {.kdlArg.}: string

  type Cleanup {.kdlNode: "cleanup".} = object
    cmd {.kdlArg.}: string

  type Job {.kdlNode: "job".} = object
    name {.kdlArg.}: string
    hooks {.kdlChild.}: seq[Hook]
    cleanup {.kdlChild.}: Option[Cleanup]

suite "mixed seq + Option children":

  test "both present":
    let src = """
job "build" {
  hook "compile"
  hook "test"
  cleanup "rm -rf /tmp/build"
}
"""
    let r = parseInto[Job](src)
    check r.isOk
    check r.get.hooks.len == 2
    check r.get.hooks[0].cmd == "compile"
    check r.get.cleanup.isSome
    check r.get.cleanup.get.cmd == "rm -rf /tmp/build"

  test "only seq present, optional absent":
    let src = """
job "build" {
  hook "compile"
}
"""
    let r = parseInto[Job](src)
    check r.isOk
    check r.get.hooks.len == 1
    check r.get.cleanup.isNone
