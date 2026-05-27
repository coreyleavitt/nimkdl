## Tests for embed[T] — compile-time staticRead + module-init parse.

import std/unittest

import ../src/ast
import ../src/codegen
import ../src/spans

kdl:
  type
    Rule {.kdlNode: "rule".} = object
      id {.kdlArg.}: string
      enabled {.kdlProp.}: bool = false   # optional → defaults when absent

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

suite "embed: malformed files fail the build, not the runtime":
  test "embed of a malformed KDL file does not compile":
    # `compiles()` returns false iff the contained expression fails
    # compilation. With the M5 fix in place, embed[Rule] on a file
    # whose parse produces Err must emit a {.error: ...} pragma at
    # compile time — making this expression non-compilable.
    # Before the fix, the file's parse error was silently embedded
    # as data and surfaced only at runtime via .get, which defeats
    # the whole point of compile-time validation.
    check not compiles(embed[Rule]("fixtures/rule_broken.kdl"))

  test "embed of a well-formed file still compiles":
    # Sanity guard so we don't accidentally over-restrict and break
    # the working path. (Already implicitly covered by the let-bindings
    # at the top of this file, but spelling it out makes intent clear.)
    check compiles(embed[Rule]("fixtures/rule_simple.kdl"))
