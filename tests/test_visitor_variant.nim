## Variant / case-object decode through the typed-direct visitor path.
##
## Until gap 4 closed, parseInto[T] on a variant type returned a
## "not supported yet — use decode[T] instead" error. Now the visitor
## handles variants by accumulating shared + branch field locals on the
## builder and constructing the result atomically in visitEndNode (matches
## the AST-walk path's Q3(ii) atomicity guarantee).
##
## Scope of this cycle: kdlArg discriminator, no kdlChild fields in any
## branch. kdlProp discriminator and variant+children land later.

import std/unittest
import ../src/[codegen, nkdl, typed_parser]

kdl:
  type
    ActionKind = enum
      akInject    = "inject"
      akDeny      = "deny"
      akTransform = "transform"

    Action {.kdlNode: "action".} = object
      label {.kdlProp.}: string = "(unlabeled)"   # shared, optional
      case kind {.kdlArg.}: ActionKind            # discriminator, positional
      of akInject:
        tmpl {.kdlProp, kdlRename: "template".}: string
      of akDeny:
        reason {.kdlProp.}: string
      of akTransform:
        cel {.kdlProp.}: string

suite "variant via parseInto: happy paths":

  test "akInject decodes with required template":
    let r = parseInto[Action]("action \"inject\" template=\"ctx pressure\"")
    check r.isOk
    check r.get.kind == akInject
    check r.get.tmpl == "ctx pressure"
    check r.get.label == "(unlabeled)"   # default fired

  test "akDeny decodes with required reason":
    let r = parseInto[Action]("action \"deny\" reason=\"too risky\"")
    check r.isOk
    check r.get.kind == akDeny
    check r.get.reason == "too risky"

  test "akTransform decodes with required cel":
    let r = parseInto[Action]("action \"transform\" cel=\"size > 0\"")
    check r.isOk
    check r.get.kind == akTransform
    check r.get.cel == "size > 0"

  test "shared field decodes alongside variant":
    let r = parseInto[Action](
      "action \"inject\" label=\"high-pri\" template=\"foo\"")
    check r.isOk
    check r.get.kind == akInject
    check r.get.label == "high-pri"
    check r.get.tmpl == "foo"

  test "bareword discriminator":
    let r = parseInto[Action]("action deny reason=\"x\"")
    check r.isOk
    check r.get.kind == akDeny

suite "variant via parseInto: error paths (atomicity)":

  test "missing discriminator -> Err":
    let r = parseInto[Action]("action")
    check r.isErr
    check r.getErr.code == peTypeMissingRequired

  test "unknown discriminator value -> peTypeDiscriminatorBad":
    let r = parseInto[Action]("action \"unrecognized\"")
    check r.isErr
    check r.getErr.code == peTypeDiscriminatorBad

  test "missing required branch field -> Err":
    let r = parseInto[Action]("action \"inject\"")
    check r.isErr
    check r.getErr.code == peTypeMissingRequired

  test "branch field on wrong branch is ignored":
    # `reason` is in akDeny branch but kind is akInject -> reason
    # silently dropped, but `template` (required for akInject) is
    # missing -> Err.
    let r = parseInto[Action]("action \"inject\" reason=\"misplaced\"")
    check r.isErr
    check r.getErr.code == peTypeMissingRequired

suite "variant via parseInto vs decode: cross-path agreement":

  test "happy-path inject: parseInto matches decode":
    let src = "action \"inject\" template=\"x\""
    let viaAst    = decode[Action](src).get
    let viaDirect = parseInto[Action](src).get
    check viaAst.kind == viaDirect.kind
    check viaAst.tmpl == viaDirect.tmpl
    check viaAst.label == viaDirect.label

  test "missing-disc: both report peTypeMissingRequired":
    let src = "action"
    let viaAst    = decode[Action](src)
    let viaDirect = parseInto[Action](src)
    check viaAst.isErr
    check viaDirect.isErr
    check viaAst.getErr.code == viaDirect.getErr.code

  test "unknown disc value: both report peTypeDiscriminatorBad":
    let src = "action \"made-up\""
    let viaAst    = decode[Action](src)
    let viaDirect = parseInto[Action](src)
    check viaAst.isErr
    check viaDirect.isErr
    check viaAst.getErr.code == viaDirect.getErr.code

# Variant in a seq — needs seq wrapper visitor.
suite "variant via parseInto[seq[T]]":

  test "decode three actions of different kinds":
    let src = """
action "inject" template="t1"
action "deny" reason="r2"
action "transform" cel="c3"
"""
    let r = parseInto[seq[Action]](src)
    check r.isOk
    check r.get.len == 3
    check r.get[0].kind == akInject
    check r.get[0].tmpl == "t1"
    check r.get[1].kind == akDeny
    check r.get[1].reason == "r2"
    check r.get[2].kind == akTransform
    check r.get[2].cel == "c3"

# Variant with a shared kdlArg before the discriminator + per-branch
# kdlArg with the same index across branches but different types.
kdl:
  type
    EventKind = enum
      evClick   = "click"
      evKey     = "key"

    Event {.kdlNode: "event".} = object
      tag {.kdlArg.}: string                  # shared arg, idx=0
      case kind {.kdlArg.}: EventKind         # disc, idx=1
      of evClick:
        x {.kdlArg.}: int                     # branch arg, idx=2
        y {.kdlArg.}: int                     # branch arg, idx=3
      of evKey:
        keyName {.kdlArg.}: string            # branch arg, idx=2 (different type!)

suite "variant with shared+branch kdlArgs":

  test "evClick: two ints after disc":
    let r = parseInto[Event]("event \"home\" \"click\" 42 99")
    check r.isOk
    check r.get.tag == "home"
    check r.get.kind == evClick
    check r.get.x == 42
    check r.get.y == 99

  test "evKey: string after disc":
    let r = parseInto[Event]("event \"home\" \"key\" \"escape\"")
    check r.isOk
    check r.get.tag == "home"
    check r.get.kind == evKey
    check r.get.keyName == "escape"
