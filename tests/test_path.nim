## Tests for path.nim — typed iterator chain + path() macro, plus the
## headline compile-time-typo demo.

import std/[sequtils, unittest]

import ../src/path

type
  Action = object
    kind*: string
    tmpl*: string

  Rule = object
    id*: string
    enabled*: bool
    action*: Action

let rules = @[
  Rule(id: "a", enabled: true,  action: Action(kind: "inject", tmpl: "TA")),
  Rule(id: "b", enabled: false, action: Action(kind: "deny",   tmpl: "TB")),
  Rule(id: "c", enabled: true,  action: Action(kind: "inject", tmpl: "TC")),
]

suite "path: typed-iterator chain":
  test "where filters by predicate":
    let kept = toSeq(rules.where(it.enabled))
    check kept.len == 2
    check kept[0].id == "a"
    check kept[1].id == "c"

  test "first returns the first match":
    let first = rules.first(it.id == "b")
    check first.id == "b"

  test "first with no match returns default":
    let none = rules.first(it.id == "ZZ")
    check none.id == ""

  test "only on a single-element seq":
    let single = @[rules[0]]
    check single.only.id == "a"

suite "path: path() macro":
  test "single field on each element":
    let ids = path(rules, id)
    check ids == @["a", "b", "c"]

  test "predicate + terminal field":
    # Drops disabled rules; yields each remaining rule's template
    let kept = path(rules, [it.enabled].id)
    check kept == @["a", "c"]

  test "two-level field access":
    let templates = path(rules, action.tmpl)
    check templates == @["TA", "TB", "TC"]

  test "predicate + nested field":
    let templates = path(rules, [it.action.kind == "inject"].action.tmpl)
    check templates == @["TA", "TC"]

suite "path: compile-time typo detection":
  # The whole demo: `enabel` is a typo. This must FAIL TO COMPILE with
  # a "did you mean enabled?" suggestion. We assert that via Nim's
  # `compiles()` introspection — the expression should NOT compile.
  test "misspelled field is a compile error":
    check not compiles(toSeq(rules.where(it.enabel)))

  test "correct spelling compiles":
    check compiles(toSeq(rules.where(it.enabled)))

  test "misspelled field in path() macro is a compile error":
    check not compiles(path(rules, [it.enabel].id))

  test "misspelled terminal in path() macro is a compile error":
    check not compiles(path(rules, action.tmpll))
