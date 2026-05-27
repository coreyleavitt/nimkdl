## kdlReserved validation through the typed-direct visitor path.
##
## Before gap 3 closed: parseInto[T] silently accepted any value for a
## kdlReserved-pragma'd field — the visitor didn't opt into vcValueAnno
## and emitVisitorFieldAssign had no validation hook. decode[T]'s
## AST-walk path always validated via emitReservedTagCheck + DocBuilder's
## per-value validateReserved call.
##
## Now the visitor's emit:
##   - opts into vcValueAnno
##   - tracks `pendingValueAnno` on the builder
##   - for any field: if a tag is present, runs validateReserved
##   - for kdlReserved-pragma'd fields: also enforces that the tag
##     matches the expected name (and that it's present at all)

import std/unittest
import ../src/[codegen, nkdl, typed_parser]

kdl:
  type Listener {.kdlNode: "listener".} = object
    bindaddr {.kdlProp, kdlReserved: "ipv4".}: string

suite "kdlReserved validation via visitor (gap 3)":

  test "valid ipv4-tagged value decodes":
    let r = parseInto[Listener]("listener bindaddr=(ipv4)\"192.0.2.1\"")
    check r.isOk
    check r.get.bindaddr == "192.0.2.1"

  test "wrong tag fails with peTypeReservedMismatch":
    let r = parseInto[Listener]("listener bindaddr=(ipv6)\"::1\"")
    check r.isErr
    check r.getErr.code == peTypeReservedMismatch

  test "missing tag on kdlReserved field fails":
    let r = parseInto[Listener]("listener bindaddr=\"192.0.2.1\"")
    check r.isErr
    check r.getErr.code == peTypeReservedMismatch

  test "valid tag but invalid content fails (Layer 1)":
    let r = parseInto[Listener]("listener bindaddr=(ipv4)\"not-an-ip\"")
    check r.isErr
    check r.getErr.code == peReservedTypeInvalid

  test "decode[T] and parseInto[T] agree on valid input":
    let src = "listener bindaddr=(ipv4)\"10.0.0.1\""
    let viaAst    = decode[Listener](src).get
    let viaDirect = parseInto[Listener](src).get
    check viaAst.bindaddr == viaDirect.bindaddr

  test "decode[T] and parseInto[T] agree on wrong-tag rejection":
    let src = "listener bindaddr=(ipv6)\"::1\""
    let viaAst    = decode[Listener](src)
    let viaDirect = parseInto[Listener](src)
    check viaAst.isErr
    check viaDirect.isErr
    check viaAst.getErr.code == viaDirect.getErr.code

# Non-reserved field that happens to receive a tag — must still validate.
kdl:
  type Tagged {.kdlNode: "tag".} = object
    addr1 {.kdlProp.}: string

suite "non-reserved field with annotation still validates":

  test "ipv4-tagged value on plain field: valid passes":
    let r = parseInto[Tagged]("tag addr1=(ipv4)\"192.0.2.1\"")
    check r.isOk

  test "ipv4-tagged value on plain field: invalid content fails":
    let r = parseInto[Tagged]("tag addr1=(ipv4)\"not-an-ip\"")
    check r.isErr
    check r.getErr.code == peReservedTypeInvalid

  test "untagged value on plain field: accepted":
    let r = parseInto[Tagged]("tag addr1=\"anything\"")
    check r.isOk

# kdlReserved on a positional arg, not just a prop.
kdl:
  type Bind {.kdlNode: "bind".} = object
    addr2 {.kdlArg, kdlReserved: "ipv4".}: string

suite "kdlReserved on positional arg":

  test "valid arg decodes":
    let r = parseInto[Bind]("bind (ipv4)\"127.0.0.1\"")
    check r.isOk
    check r.get.addr2 == "127.0.0.1"

  test "missing tag on arg fails":
    let r = parseInto[Bind]("bind \"127.0.0.1\"")
    check r.isErr
    check r.getErr.code == peTypeReservedMismatch
