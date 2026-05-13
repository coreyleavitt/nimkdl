## Tests for `decodeAll[T]` — typed multi-error variant of `decode[T]`.
## Mirrors `parseAll`'s contract at the typed layer: `tuple[value, errors]`,
## with siblings decoding independently. See BACKLOG H7.

import std/[sequtils, unittest]

import ../src/ast
import ../src/codegen
import ../src/spans

type
  Rule {.kdlNode: "rule".} = object
    id {.kdlArg.}: string
    count {.kdlProp.}: int = 0

  Single {.kdlNode: "single".} = object
    name {.kdlArg.}: string

deriveDecode(Rule)
deriveDecode(Single)

suite "decodeAll[T] — clean input":
  test "matches decode[T] when source is fully valid (seq[T])":
    let src = """
      rule "a" count=1
      rule "b" count=2
    """
    let r = decodeAll[seq[Rule]](src)
    check r.errors.len == 0
    check r.value.len == 2
    check r.value[0].id == "a"
    check r.value[1].count == 2

  test "matches decode[T] when source is fully valid (single T)":
    let src = "single \"only\""
    let r = decodeAll[Single](src)
    check r.errors.len == 0
    check r.value.name == "only"

suite "decodeAll[T] — parse-time errors don't stop sibling decode":
  test "broken node before valid sibling: error surfaces, valid sibling decoded":
    # First rule has an unclosed type annotation on its value, which
    # makes the lexer/parser report an error. The second is well-formed.
    let src = """
      rule "broken" count=(unterminated
      rule "good" count=7
    """
    let r = decodeAll[seq[Rule]](src)
    check r.errors.len >= 1
    # The well-formed sibling survives.
    let goods = r.value.filterIt(it.id == "good")
    check goods.len == 1
    check goods[0].count == 7

suite "decodeAll[T] — decode-time errors don't stop sibling decode":
  test "type-mismatched node sandwiched between valid ones":
    # Middle rule has count="string" — wrong type for an int field.
    # The decoder for THAT node should fail, but the surrounding
    # rules must still surface in `value`.
    let src = """
      rule "first" count=1
      rule "bad" count="not-an-int"
      rule "third" count=3
    """
    let r = decodeAll[seq[Rule]](src)
    # Exactly one decode-time error (the bad node), zero parse errors.
    check r.errors.len == 1
    # The two valid siblings made it through.
    let ids = r.value.mapIt(it.id)
    check ids == @["first", "third"]

suite "decodeAll[T] — single-T missing node":
  test "no matching top-level node surfaces a peTypeMissingRequired":
    let src = "rule \"x\""   # no `single` node at all
    let r = decodeAll[Single](src)
    check r.errors.len == 1
    check r.errors[0].code == peTypeMissingRequired
    # Value stays default-init — caller must check errors first.
    check r.value.name == ""

suite "decodeAll[T] — parse and decode errors aggregate together":
  test "broken syntax + type mismatch + valid sibling: all three reported":
    let src = """
      rule "first" count=(unterminated
      rule "second" count="bad-type"
      rule "third" count=42
    """
    let r = decodeAll[seq[Rule]](src)
    # At least one parse error AND one decode error.
    check r.errors.len >= 2
    var hasParse = false
    var hasDecode = false
    for e in r.errors:
      case e.code
      of peTypeMismatch, peTypeMissingRequired, peTypeReservedMismatch,
         peTypeEnumInvalid, peTypeDiscriminatorBad:
        hasDecode = true
      else:
        hasParse = true
    check hasParse
    check hasDecode
    # Valid sibling survives.
    let ids = r.value.mapIt(it.id)
    check "third" in ids
