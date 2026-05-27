## Compile + run the README's worked examples. Catches doc rot the
## moment an example diverges from the actual API.
##
## When you change the README, change this file in the same commit.
## If this test fails, the README is the source of truth — fix the
## library to match the example, or update both together.

import std/[sequtils, strutils, unittest]

import ../src/nkdl

# Top-level types (Nim doesn't allow `type` blocks nested in a suite).

type
  Action {.kdlNode: "action".} = object
    kind* {.kdlArg.}: string
    tmpl* {.kdlProp, kdlRename: "template".}: string

  Rule {.kdlNode: "rule".} = object
    id* {.kdlArg.}: string
    enabled* {.kdlProp.}: bool = true
    action*: Action

  QRule = object
    id*: string
    enabled*: bool
    score*: int

  DemoRule = object
    id*: string
    enabled*: bool

deriveDecode(Action)
deriveDecode(Rule)

let queryRules = @[
  QRule(id: "a", enabled: true,  score: 10),
  QRule(id: "b", enabled: false, score: 20),
  QRule(id: "c", enabled: true,  score: 30),
]
let demoRules = @[DemoRule(id: "x", enabled: true)]

suite "README: parse → encode round trip":
  test "rule fragment encodes":
    let r = parse("""
rule "compaction" {
  action "inject" template="ctx pressure rising"
}
""", preserveFormat = true)
    check r.isOk
    let encoded = encode(r.get)
    check "rule" in encoded
    check "compaction" in encoded
    check "action" in encoded

suite "README: type-driven decode":
  test "rule with renamed inner template field":
    let r = decode[Rule]("""
      rule "compaction" {
        action "inject" template="ctx pressure rising"
      }
    """)
    check r.isOk
    if r.isOk:
      check r.get.id == "compaction"
      check r.get.enabled                  # default fired
      check r.get.action.kind == "inject"
      check r.get.action.tmpl == "ctx pressure rising"

suite "README: typed query — three styles":
  test "path() macro yields filtered fields":
    let ids = toSeq(path(queryRules, [it.enabled].id))
    check ids == @["a", "c"]

  test "where iterator chain":
    var kept: seq[string] = @[]
    for r in queryRules.where(it.enabled):
      kept.add(r.id)
    check kept == @["a", "c"]

  test "first returns the first match":
    let f = queryRules.first(it.score >= 20)
    check f.id == "b"

suite "README: compile-time typo demo":
  test "misspelled `enabel` does NOT compile":
    check not compiles(toSeq(path(demoRules, [it.enabel].id)))

  test "correct `enabled` DOES compile":
    check compiles(toSeq(path(demoRules, [it.enabled].id)))

suite "README: differential testing":
  test "hand parser and reference interpreter agree":
    let src = "rule \"compaction\" {\n  action \"inject\"\n}"
    let viaFast = parse(src)
    let viaRef  = referenceInterpret(src)
    check viaFast.isOk == viaRef.isOk
    if viaFast.isOk and viaRef.isOk:
      check docEqual(viaFast.get, viaRef.get)

suite "README: safety limits exposed":
  test "constants reachable from kdl":
    check MaxParserDepth >= 256
    check InlineCapacity >= 22
    check KdlReprMaxDepth >= 32
