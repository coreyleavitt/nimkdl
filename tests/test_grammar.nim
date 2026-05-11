## Tests for grammar.nim — grammar value structure, validation,
## reference interpreter correctness, and **differential testing** of
## the reference interpreter against the hand parser.

import std/[strutils, tables, unittest]

import ../src/ast
import ../src/grammar
import ../src/parser
import ../src/spans

suite "Grammar value":
  test "validate passes on canonical KDL v2 grammar":
    let errs = validate(KdlV2Grammar)
    check errs.len == 0

  test "validate catches undefined ref":
    var bad = buildKdlGrammar()
    bad.rules["broken"] = refTo("nonexistent")
    let errs = validate(bad)
    check errs.len == 1
    check "nonexistent" in errs[0]

  test "validate catches undefined start":
    var bad = buildKdlGrammar()
    bad.startRule = "nope"
    let errs = validate(bad)
    check errs.len >= 1

  test "renders as readable EBNF":
    let s = $KdlV2Grammar
    check "start: document" in s
    check "node :=" in s
    check "value :=" in s

suite "Reference interpreter: basic shapes":
  template same(src: string) =
    ## Asserts both interpreters succeed and produce structurally equal docs.
    let viaFast = parse(src)
    let viaRef  = referenceInterpret(src)
    check viaFast.isOk
    check viaRef.isOk
    if viaFast.isOk and viaRef.isOk:
      check docEqual(viaFast.get, viaRef.get)

  test "empty doc":
    same("")

  test "single bare node":
    same("rule")

  test "two nodes separated by newline":
    same("a\nb")

  test "nodes separated by semicolon":
    same("a; b")

  test "node with string argument":
    same("rule \"compaction\"")

  test "node with multiple arguments":
    same("range 1 2 3")

  test "node with property":
    same("rule enabled=#true")

  test "mixed args and props":
    same("rule \"id\" enabled=#true 42")

  test "node with children":
    same("rule {\n  child\n}")

  test "nested children":
    same("outer {\n  middle {\n    inner\n  }\n}")

  test "type annotation on value":
    same("size (u32)1024")

  test "type annotation on node":
    same("(version)rule")

  test "all keyword values":
    same("v a=#true b=#false c=#null")

  test "special floats":
    same("v a=#inf b=#-inf c=#nan")

  test "negative integer":
    same("offset -7")

  test "hex literal":
    same("mask 0xFF")

  test "octal literal":
    same("perm 0o755")

  test "binary literal":
    same("flags 0b1010")

  test "float with exponent":
    same("v 1.5e10")

suite "Reference interpreter: slashdash":
  template same(src: string) =
    let viaFast = parse(src)
    let viaRef  = referenceInterpret(src)
    check viaFast.isOk
    check viaRef.isOk
    if viaFast.isOk and viaRef.isOk:
      check docEqual(viaFast.get, viaRef.get)

  test "slashdash on node":
    same("/- skipped\nkept")

  test "slashdash on entry":
    same("rule /- skipped=1 kept=2")

  test "slashdash on children":
    same("rule /- {\n  hidden\n} visible=#true")

suite "Reference interpreter: realistic fragments":
  test "rule with action subtree matches hand parser":
    let src = """
rule "compaction" {
  enabled #true
  action "inject" {
    template "ctx pressure"
  }
}
"""
    let viaFast = parse(src)
    let viaRef  = referenceInterpret(src)
    check viaFast.isOk
    check viaRef.isOk
    if viaFast.isOk and viaRef.isOk:
      check docEqual(viaFast.get, viaRef.get)

  test "config with multiple top-level nodes":
    let src = """
provider "openrouter" {
  api_key_file "~/.amoxtli/or.key"
}

defaults {
  model "tencent/hy3-preview:free"
  temperature 0.2
}
"""
    let viaFast = parse(src)
    let viaRef  = referenceInterpret(src)
    check viaFast.isOk
    check viaRef.isOk
    if viaFast.isOk and viaRef.isOk:
      check docEqual(viaFast.get, viaRef.get)

suite "Reference interpreter: error parity":
  template bothErr(src: string) =
    ## Both interpreters should reject; we don't require identical
    ## error messages (the parsers are deliberately different shapes)
    ## but both must agree that this is bad input.
    let viaFast = parse(src)
    let viaRef  = referenceInterpret(src)
    check viaFast.isErr
    check viaRef.isErr

  test "unclosed children block":
    bothErr("rule {\n  child\n")

  test "lexer error surfaces in both":
    bothErr("\"unterminated")

suite "kdlGrammar macro":
  test "wraps a valid grammar without complaint":
    let g = kdlGrammar:
      buildKdlGrammar()
    check g.startRule == "document"

  # We can't (easily) test that the macro REJECTS a bad grammar with
  # `check` — it would be a compile error in this test file. The
  # validate() unit test above covers the underlying check.
