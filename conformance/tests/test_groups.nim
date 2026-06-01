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

suite "A-float — float group instantiation":

  test "shape controls fraction/exponent presence in the surface":
    for row in coveringArray(floatGroup()):
      let t = instantiateFloat(row).text
      let hasDot = "." in t
      let hasE = ('e' in t) or ('E' in t)
      case lvl(row, "float.shape")
      of "frac": check hasDot and not hasE
      of "exp":  check hasE and not hasDot
      of "both": check hasDot and hasE
      else: discard

  test "every float witness is a real number (never an integer)":
    for row in coveringArray(floatGroup()):
      check isReal(instantiateFloat(row).value.num)

  test "leading sign is semantic (minus negates the magnitude)":
    for row in coveringArray(floatGroup()):
      let canon = canonicalKdl(instantiateFloat(row).value)
      check (canon.startsWith("-")) == (lvl(row, "float.sign") == "minus")

  test "exponent sign is semantic (minus → E- in canonical)":
    for row in coveringArray(floatGroup()):
      if lvl(row, "float.shape") in ["exp", "both"]:
        let canon = canonicalKdl(instantiateFloat(row).value)
        check ("E-" in canon) == (lvl(row, "float.expsign") == "minus")

  test "metamorphic: positive presentation variants per shape agree on value":
    # Fix the value-affecting factors to positive; vary expcase / leading-plus /
    # underscore. Each shape then denotes exactly one canonical real.
    proc canonOf(shape: string): seq[string] =
      coveringArray(floatGroup())
        .filterIt(lvl(it, "float.shape") == shape and
                  lvl(it, "float.sign") != "minus" and
                  lvl(it, "float.expsign") != "minus")
        .mapIt(canonicalKdl(instantiateFloat(it).value))
    check canonOf("frac").allIt(it == "1.25")
    check canonOf("exp").allIt(it == "1E+10")
    check canonOf("both").allIt(it == "1.25E+10")

suite "A-string — string group instantiation (single-line quoted + raw)":

  test "style controls the delimiter (quoted vs #-raw)":
    for row in coveringArray(stringGroup()):
      let t = instantiateString(row).text
      case lvl(row, "str.style")
      of "quoted": check t.startsWith("\"") and not t.startsWith("#")
      of "raw":    check t.startsWith("#")
      else: discard

  test "content determines the decoded value, independent of style":
    for row in coveringArray(stringGroup()):
      let v = instantiateString(row).value.s
      case lvl(row, "str.content")
      of "simple":    check v == "abc"
      of "quote":     check v == "ab\"cd"
      of "backslash": check v == "ab\\cd"
      else: discard

  test "raw hash count matches the requested level":
    for row in coveringArray(stringGroup()):
      if lvl(row, "str.style") == "raw":
        let t = instantiateString(row).text
        let want = (if lvl(row, "str.hashes") == "two": 2 else: 1)
        check t.startsWith(repeat('#', want) & "\"")
        check not t.startsWith(repeat('#', want + 1))

  test "canonical is the quoted-escaped form regardless of surface style":
    for row in coveringArray(stringGroup()):
      let s = instantiateString(row)
      case lvl(row, "str.content")
      of "simple":    check canonicalKdl(s.value) == "\"abc\""
      of "quote":     check canonicalKdl(s.value) == "\"ab\\\"cd\""
      of "backslash": check canonicalKdl(s.value) == "\"ab\\\\cd\""
      else: discard

  test "metamorphic: same content via quoted and raw denotes the same value":
    for content in ["simple", "quote", "backslash"]:
      let vals = coveringArray(stringGroup())
        .filterIt(lvl(it, "str.content") == content)
        .mapIt(instantiateString(it).value.s)
      check vals.len >= 2          # both styles present
      check vals.allIt(it == vals[0])

suite "A-anno — value type-annotation group":

  test "every witness value carries the type annotation 'type'":
    for row in coveringArray(annotationGroup()):
      check instantiateAnnotation(row).value.typeAnno == "type"

  test "surface always brackets the annotation":
    for row in coveringArray(annotationGroup()):
      let t = instantiateAnnotation(row).text
      check "(" in t and ")" in t

  test "annotation style: quoted iff style=quoted":
    for row in coveringArray(annotationGroup()):
      let t = instantiateAnnotation(row).text
      check ("\"type\"" in t) == (lvl(row, "anno.style") == "quoted")

  test "inner whitespace appears iff innerWs=spaced":
    for row in coveringArray(annotationGroup()):
      let t = instantiateAnnotation(row).text
      check ("( " in t) == (lvl(row, "anno.innerWs") == "spaced")

  test "canonical normalizes to a tight bareword annotation regardless of surface":
    for row in coveringArray(annotationGroup()):
      let s = instantiateAnnotation(row)
      let want = (if lvl(row, "anno.valueKind") == "string": "(type)\"s\"" else: "(type)1")
      check canonicalKdl(s.value) == want

  test "metamorphic: all surface variants of a value+anno denote one model":
    for vk in ["int", "string"]:
      let canons = coveringArray(annotationGroup())
        .filterIt(lvl(it, "anno.valueKind") == vk)
        .mapIt(canonicalKdl(instantiateAnnotation(it).value))
      check canons.len >= 2
      check canons.allIt(it == canons[0])

suite "A-struct — structural group instantiation (node-shaped witnesses)":

  proc argCount(n: KNode): int =
    for e in n.entries:
      if e.kind == keArg: inc result
  proc propCount(n: KNode): int =
    for e in n.entries:
      if e.kind == keProp: inc result

  test "arg count matches the factor (0/1/2 positional arguments)":
    for row in coveringArray(structuralGroup()):
      let want = parseInt(lvl(row, "struct.args"))
      check argCount(instantiateStructural(row).doc[0]) == want

  test "property present iff props=1":
    for row in coveringArray(structuralGroup()):
      let n = instantiateStructural(row).doc[0]
      check (propCount(n) == 1) == (lvl(row, "struct.props") == "yes")

  test "children block present iff children=yes":
    for row in coveringArray(structuralGroup()):
      let s = instantiateStructural(row)
      let hasKids = s.doc[0].children.len > 0
      check hasKids == (lvl(row, "struct.children") == "yes")
      check ("{" in s.text) == hasKids

  test "document has a second node iff secondNode=yes":
    for row in coveringArray(structuralGroup()):
      let s = instantiateStructural(row)
      check (s.doc.len == 2) == (lvl(row, "struct.second") == "yes")

  test "the interaction case — node with children followed by a sibling — is generated":
    # children=yes ∧ second=yes is the slashdash×children-checkpoint bug home;
    # the constrained covering array must include it.
    let hit = coveringArray(structuralGroup()).anyIt(
      lvl(it, "struct.children") == "yes" and lvl(it, "struct.second") == "yes")
    check hit
