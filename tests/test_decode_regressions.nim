## Behavior-level regression tests for decode[T] / decodeAll[T].
##
## Each suite below pins down a specific behavior that the visitor codegen
## previously got wrong or could regress on. The tests are organized by
## behavior topic (not by review-finding ID) so they remain meaningful
## independent of the code-review history that originally prompted them.
##
## Topics covered:
##   - Mixed-shape top-level documents: alien sibling nodes must be
##     silently skipped, not surface as errors, even for variant types.
##   - Per-node error recovery in accumulating mode: a single failing
##     node must produce exactly one error, regardless of how many
##     subsequent entries it had.
##   - Enum-failure error code routing: discriminator failures use
##     peTypeDiscriminatorBad; non-discriminator enum field failures
##     use peTypeEnumInvalid. Applies to both flat and variant types.
##   - Pending-annotation lifecycle: a type-mismatch on one field must
##     not leak `(tag)` annotations into the next field's reserved-tag
##     check (catches the snapshot+clear pattern getting reintroduced
##     piecewise).
##   - Error-hint amplification: user-controlled annotation strings
##     embedded in error.hint must be length-capped so a giant `(tag)`
##     in source can't produce a megabyte error message.

import std/[strutils, unittest]
import ../src/[codegen, nkdl, typed_parser]

kdl:
  type
    EvKind = enum
      evClick = "click"
      evKey   = "key"

    # A non-discriminator enum field on the akClick branch — exercises
    # H3 (must use peTypeEnumInvalid, not peTypeDiscriminatorBad).
    Severity = enum
      sevLow  = "low"
      sevHigh = "high"

    Event {.kdlNode: "event".} = object
      case kind {.kdlArg.}: EvKind
      of evClick:
        sev {.kdlProp.}: Severity
      of evKey:
        keyName {.kdlArg.}: string

suite "decode[seq[VariantType]]: alien top-level nodes are skipped":

  test "decode[seq[Event]] over mixed top-level: alien nodes skipped":
    let src = """
event "click" sev="low"
other "x"
event "key" "escape"
"""
    let r = decode[seq[Event]](src)
    check r.isOk
    check r.get.len == 2
    check r.get[0].kind == evClick
    check r.get[0].sev == sevLow
    check r.get[1].kind == evKey
    check r.get[1].keyName == "escape"

  test "decodeAll[seq[Event]] over mixed top-level: no spurious errors":
    let src = """
event "click" sev="high"
other "x"
unrelated 1 2 3
event "key" "tab"
"""
    let r = decodeAll[seq[Event]](src)
    check r.errors.len == 0    # alien siblings must NOT raise errors
    check r.value.len == 2

suite "decodeAll[seq[VariantType]]: one error per failing node":

  test "bad-disc node with later entries produces ONE error, not N":
    # Discriminator "unrecognized" is invalid. The remaining `sev="high"`
    # prop would, pre-fix, also surface as its own error. Post-fix the
    # node aborts after the first error.
    let src = """
event "click" sev="high"
event "unrecognized" sev="low"
event "key" "esc"
"""
    let r = decodeAll[seq[Event]](src)
    check r.errors.len == 1
    check r.errors[0].code == peTypeDiscriminatorBad
    # Surrounding good nodes still made it through.
    check r.value.len == 2
    check r.value[0].kind == evClick
    check r.value[1].kind == evKey

  test "bad branch field in middle of node: one error, others skipped":
    # akClick wants sev to be an enum value; "purple" isn't one. After
    # H2+H3 fix: ONE error with code peTypeEnumInvalid (not
    # peTypeDiscriminatorBad — the discriminator decoded fine).
    let src = """
event "click" sev="low"
event "click" sev="purple"
event "click" sev="high"
"""
    let r = decodeAll[seq[Event]](src)
    check r.errors.len == 1
    check r.errors[0].code == peTypeEnumInvalid  # H3: not Discriminator
    check r.value.len == 2

suite "variant enum error code routing (disc vs non-disc)":

  test "bad value on plain enum prop: peTypeEnumInvalid (strict mode)":
    let r = decode[Event]("event \"click\" sev=\"purple\"")
    check r.isErr
    check r.getErr.code == peTypeEnumInvalid

  test "bad value on the discriminator itself: peTypeDiscriminatorBad":
    let r = decode[Event]("event \"made-up\"")
    check r.isErr
    check r.getErr.code == peTypeDiscriminatorBad

# Same H3 check on a flat (non-variant) enum field — exercises the flat
# visitor's emitVisitorFieldAssign enum routing.
kdl:
  type
    Color = enum
      cRed   = "red"
      cBlue  = "blue"

    Paint {.kdlNode: "paint".} = object
      color {.kdlProp.}: Color

suite "flat-type enum field error code":
  test "bad enum value on a flat type: peTypeEnumInvalid":
    let r = decode[Paint]("paint color=\"chartreuse\"")
    check r.isErr
    check r.getErr.code == peTypeEnumInvalid

# Pending-annotation lifecycle: a type-mismatch error on field A must
# not leak A's `(tag)` annotation into field B's reserved-tag check.
# The visitor's snapshot+clear pattern at the top of every primitive
# decode closes this leak uniformly — this regression test catches it
# getting reintroduced one site at a time.

kdl:
  type Two {.kdlNode: "two".} = object
    a {.kdlProp.}: int      # plain int, no kdlReserved
    b {.kdlProp.}: string   # plain string, no kdlReserved

suite "primitive-type-mismatch does not leak pendingValueAnno":

  test "(ipv4)\"x\" on int field then untagged b: b decodes cleanly":
    # a expects int; source supplies (ipv4)"x" which is a string-typed
    # value AND annotated. Pre-fix: int kind-check returned Err without
    # clearing pendingValueAnno. In strict mode (decode[T]) the error
    # propagates immediately so we wouldn't observe the leak. In
    # accumulating mode (decodeAll) the per-node failure-swallow keeps
    # us in the same node; once we move to the NEXT node, fresh
    # visitBeginNode → fresh state. So the leak only manifests if the
    # parser keeps processing fields within the same node after the
    # error. Today's seq wrapper sets curFailed so subsequent events
    # for the same node are swallowed, masking the leak in practice.
    # The defense-in-depth value is that the snapshot+clear pattern
    # makes the property hold regardless of recovery strategy.
    let r = decodeAll[seq[Two]]("two a=(ipv4)\"x\" b=\"ok\"")
    check r.errors.len == 1
    check r.errors[0].code == peTypeMismatch
    # Subsequent unrelated nodes work fine.
    let r2 = decodeAll[seq[Two]]("""
two a=(ipv4)"x" b="ok"
two a=42 b="fine"
""")
    check r2.errors.len == 1
    check r2.value.len == 1
    check r2.value[0].a == 42
    check r2.value[0].b == "fine"

# Error-hint amplification defense: user-controlled annotation bytes
# embedded in error.hint must be length-capped (capAnnoForHint).
# Without the cap, a malicious 1 MB `(tag)` in source would produce a
# 1 MB error.hint that any log consumer would write verbatim.

kdl:
  type Strict {.kdlNode: "strict".} = object
    v {.kdlProp, kdlReserved: "ipv4".}: string

suite "annotation length cap in error hints":

  test "1KB tag in source produces a bounded error hint":
    let bigTag = "a".repeat(1024)
    let src = "strict v=(" & bigTag & ")\"127.0.0.1\""
    let r = decode[Strict](src)
    check r.isErr
    check r.getErr.code == peTypeReservedMismatch
    # capAnnoForHint truncates at 256 chars + "...(truncated)" marker.
    # Hint also includes field name + expected tag boilerplate — so
    # the total should be well under 1 KB.
    check r.getErr.hint.len < 600
    check "...(truncated)" in r.getErr.hint
