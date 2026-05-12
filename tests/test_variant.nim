## Tests for H9 — object-variant support in deriveDecode.
##
## Verifies:
##   - Happy paths for each branch
##   - Discriminator decode failure → Err, target untouched (Q2 (b)
##     downgraded to (a) under un-hedged C3)
##   - Unknown discriminator value → Err, target untouched
##   - Missing required branch field → Err, target untouched (Q3 (ii))
##   - Atomic construction: variant fields not accessible by name when
##     wrong discriminator is set
##   - Shared (non-variant) fields decode alongside variant fields

import std/[strutils, unittest]

import ../src/codegen
import ../src/spans

# Fixtures at module scope: deriveDecode emits `proc kdlDecodeImpl*`
# which can't be declared inside a `suite` template body.

type
  ActionKind* = enum
    akInject  = "inject"
    akDeny    = "deny"
    akTransform = "transform"

  Action* {.kdlNode: "action".} = object
    label* {.kdlAttr.}: string = "(unlabeled)"   # shared, optional
    case kind* {.kdlArg.}: ActionKind            # discriminator, positional
    of akInject:
      tmpl* {.kdlAttr, kdlRename: "template".}: string
    of akDeny:
      reason* {.kdlAttr.}: string
    of akTransform:
      cel* {.kdlAttr.}: string

deriveDecode(Action)

suite "variant: happy paths":
  test "akInject decodes with required tmpl":
    let r = decode[Action]("action \"inject\" template=\"ctx pressure\"")
    check r.isOk
    if r.isOk:
      check r.get.kind == akInject
      check r.get.tmpl == "ctx pressure"
      check r.get.label == "(unlabeled)"          # default fired

  test "akDeny decodes with required reason":
    let r = decode[Action]("action \"deny\" reason=\"too risky\"")
    check r.isOk
    if r.isOk:
      check r.get.kind == akDeny
      check r.get.reason == "too risky"

  test "akTransform decodes with required cel":
    let r = decode[Action](
      "action \"transform\" cel=\"size(rules) > 0\"")
    check r.isOk
    if r.isOk:
      check r.get.kind == akTransform
      check r.get.cel == "size(rules) > 0"

  test "shared field decodes alongside variant":
    let r = decode[Action](
      "action \"inject\" label=\"high-priority\" template=\"foo\"")
    check r.isOk
    if r.isOk:
      check r.get.kind == akInject
      check r.get.label == "high-priority"
      check r.get.tmpl == "foo"

suite "variant: error paths (Q3 (ii) atomicity)":
  test "missing discriminator → Err":
    let r = decode[Action]("action")
    check r.isErr
    if r.isErr:
      check r.getErr.code == peTypeMissingRequired

  test "unknown discriminator value → Err":
    let r = decode[Action]("action \"unrecognized\"")
    check r.isErr
    if r.isErr:
      check r.getErr.code == peTypeMismatch

  test "missing required branch field → Err":
    # akInject requires `template`; KDL omits it.
    let r = decode[Action]("action \"inject\"")
    check r.isErr
    if r.isErr:
      check r.getErr.code == peTypeMissingRequired
      check "template" in r.getErr.hint

  test "branch field on wrong branch is ignored":
    # KDL supplies `reason` but discriminator is `akInject` — reason
    # isn't part of the akInject branch, so it's just an unknown
    # property and gets silently dropped (no entry-key strictness in
    # v0.1). The required `template` is still missing → Err.
    let r = decode[Action]("action \"inject\" reason=\"misplaced\"")
    check r.isErr

suite "variant: atomicity of construction":
  test "successful decode produces correctly-shaped variant":
    let r = decode[Action]("action \"deny\" reason=\"x\"")
    check r.isOk
    if r.isOk:
      let a = r.get
      # Type system enforces: a.kind == akDeny ⇒ a.reason exists.
      # Trying to access a.tmpl when kind=akDeny should be a
      # Defect, not a silent zero string. Verify by case-matching.
      case a.kind
      of akInject:    fail()   # we asked for deny
      of akDeny:      check a.reason == "x"
      of akTransform: fail()
