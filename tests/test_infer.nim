## test_infer.nim — name-preserving slot inference for unannotated fields (rfc §8.2).
##
## Before this fix, `classify` had no else branch: a field with none of
## {.kdlArg./kdlProp./kdlChild.} was SILENTLY DROPPED from the decoder (a D3
## "fail loud" violation — the field decoded to its default, no error). The fix
## infers the slot from the field's type:
##   * primitive / enum            → prop  (wire key = field name)
##   * object / ref object         → child (by the type's node name)
##   * seq[object]                 → child seq
##   * Option[X]                   → inherits X's routing
## seq[primitive] without a pragma is a compile error (can't infer; needs kdlArg).

import std/[unittest, options]
import ../src/api
import ../src/kdl_block
import ../src/pragmas

kdl:
  type Endpoint {.kdlNode: "endpoint".} = object
    host {.kdlArg.}: string

  type Server {.kdlNode: "server".} = object
    port: int          # unannotated → infer prop "port"
    name: string       # unannotated → infer prop "name"
    ep: Endpoint       # unannotated → infer child (node "endpoint")

  type Opt {.kdlNode: "opt".} = object
    label: string                # → prop
    tag: Option[string]          # → optional prop (Option[primitive])

  type Ports {.kdlNode: "ports".} = object
    small {.kdlProp.}: uint8
    big {.kdlProp.}: uint32

suite "derive — name-preserving slot inference (rfc §8.2)":
  test "unannotated primitive fields infer as props; object as child":
    let r = decode[Server]("server port=8080 name=\"web\" {\n  endpoint \"h\"\n}")
    check r.isOk
    check r.get.port == 8080
    check r.get.name == "web"
    check r.get.ep.host == "h"

  test "Option[primitive] infers as optional prop":
    let r = decode[Opt]("opt label=\"x\" tag=\"t\"")
    check r.isOk
    check r.get.label == "x"
    check r.get.tag == some("t")

  test "absent Option[primitive] stays none":
    let r = decode[Opt]("opt label=\"x\"")
    check r.isOk
    check r.get.tag.isNone

suite "derive — unsigned integer fields (rfc §8.7)":
  test "uint8 / uint32 decode":
    let r = decode[Ports]("ports small=200 big=70000")
    check r.isOk
    check r.get.small == 200'u8
    check r.get.big == 70000'u32

  test "negative literal for an unsigned field is rejected":
    let r = decode[Ports]("ports small=-1 big=0")
    check r.isErr
