## Tests for embed[T] — compile-time staticRead + module-init parse.

import std/unittest

import ../src/ast
import ../src/codegen
import ../src/spans

type
  Rule {.kdlNode: "rule".} = object
    id {.kdlArg.}: string
    enabled {.kdlAttr.}: bool = false   # optional → defaults when absent

deriveDecode(Rule)

# Files referenced are resolved relative to this .nim file's directory
# (same rule as staticRead's lookup behavior).
let oneRule = embed[Rule]("fixtures/rule_simple.kdl")
let manyRules = embed[seq[Rule]]("fixtures/rules_many.kdl")
let anotherRule = embed[Rule]("fixtures/rule_with_action.kdl")

suite "embed: single file":
  test "rule with arg + attr round-trips":
    check oneRule.isOk
    if oneRule.isOk:
      check oneRule.get.id == "compaction"
      check oneRule.get.enabled

  test "second fixture decodes independently":
    check anotherRule.isOk
    if anotherRule.isOk:
      check anotherRule.get.id == "permission"
      check not anotherRule.get.enabled

suite "embed: multi-rule file via seq[T]":
  test "three rules accumulate in source order":
    check manyRules.isOk
    if manyRules.isOk:
      let rules = manyRules.get
      check rules.len == 3
      check rules[0].id == "a"
      check rules[1].id == "b"
      check rules[1].enabled
      check rules[2].id == "c"
