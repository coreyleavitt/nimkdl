## conformance/tests/test_groups.nim — spec-transcribed interaction groups +
## their instantiators (clean-room, no nkdl).
##
## A3: a covering-array ROW (abstract surface choices) is turned into a concrete
## witness `(text, value)` by the group's instantiator. The instantiator is the
## spec transcription of that production in the *generation* direction, so each
## witness is an oracle by construction. Two checks matter:
##   • the surface choices are faithfully rendered (a hex row's text says `0x`…),
##   • presentation-only factors (base/case/underscore) do NOT change the model
##     value — the metamorphic invariant that justifies calling them "surface".

import std/[unittest, sequtils, strutils]
import ../model
import ../coverage
import ../groups

suite "A3 — integer group instantiation":

  test "sign is semantic: minus negates, none/plus stay positive":
    for row in coveringArray(integerGroup()):
      let s = instantiateInteger(row)
      case lvl(row, "int.sign")
      of "minus": check canonicalKdl(s.value) == "-42"
      else:       check canonicalKdl(s.value) == "42"

  test "base is rendered into the surface text":
    for row in coveringArray(integerGroup()):
      let t = instantiateInteger(row).text
      case lvl(row, "int.base")
      of "hex": check "0x" in t
      of "oct": check "0o" in t
      of "bin": check "0b" in t
      of "dec": check "0x" notin t and "0o" notin t and "0b" notin t
      else: discard

  test "hexcase=upper uses uppercase hex digits (42 = 0x2a, letter case observable)":
    # An underscore may split the digits (0x2_A), so check the letter's case
    # directly rather than a digit-pair substring.
    for row in coveringArray(integerGroup()):
      if lvl(row, "int.base") == "hex":
        let t = instantiateInteger(row).text
        if lvl(row, "int.hexcase") == "upper":
          check 'A' in t and 'a' notin t
        else:
          check 'a' in t and 'A' notin t

  test "underscore=yes inserts an underscore between digits":
    for row in coveringArray(integerGroup()):
      let yes = lvl(row, "int.underscore") == "yes"
      check ("_" in instantiateInteger(row).text) == yes

  test "metamorphic: presentation-only variants of the same value agree":
    # All positive rows (sign none/plus) denote exactly kInt(42) regardless of
    # base, hex-case, or underscores — that is what makes them surface.
    let positives = coveringArray(integerGroup())
      .filterIt(lvl(it, "int.sign") != "minus")
      .mapIt(canonicalKdl(instantiateInteger(it).value))
    check positives.allIt(it == "42")
