## Tests for Phase 4 PDA-based typed decode (per docs/rfc-pda-substrate.md).
##
## Each cycle exercises one behavior. The PDA path lives in
## src/pda_decode.nim parallel to the cursor-based src/derive_decode.nim
## per RFC Q1 (transition co-existence).

import std/unittest

import ../src/pda_decode
import ../src/pragmas
import ../src/spans

type Service {.kdlNode: "service".} = object
  name {.kdlArg.}: string

derivePDADecode(Service)

suite "pda_decode — Sprint 1 cycle 1: tracer (single string kdlArg)":

  test "single string kdlArg decodes from `service \"web\"`":
    let r = decodePDA[Service]("service \"web\"")
    check r.isOk
    check r.get.name == "web"

# Cycle 2 — RFC Q3 hard constraint: the macro-emitted decoder must
# run in NimVM at compile time so `embed[T]` keeps working post-
# Phase-4. If this `const` doesn't evaluate, the architecture has
# already failed and we abort.
const ctTracer = decodePDA[Service]("service \"compiletime\"").get

suite "pda_decode — Sprint 1 cycle 2: VM-compat (embed)":

  test "decodePDA[T] runs at compile time":
    check ctTracer.name == "compiletime"

# Cycle 3 — single int prop.
type ServiceP {.kdlNode: "service".} = object
  name {.kdlArg.}: string
  port {.kdlProp.}: int

derivePDADecode(ServiceP)

suite "pda_decode — Sprint 1 cycle 3: single int kdlProp":

  test "string arg + int prop decodes":
    let r = decodePDA[ServiceP]("service \"web\" port=80")
    check r.isOk
    check r.get.name == "web"
    check r.get.port == 80

# Cycle 4 — bool prop with #true / #false reserved keywords.
type ServicePB {.kdlNode: "service".} = object
  name {.kdlArg.}: string
  enabled {.kdlProp.}: bool

derivePDADecode(ServicePB)

suite "pda_decode — Sprint 1 cycle 4: bool kdlProp":

  test "bool prop #true decodes":
    let r = decodePDA[ServicePB]("service \"web\" enabled=#true")
    check r.isOk
    check r.get.enabled == true

  test "bool prop #false decodes":
    let r = decodePDA[ServicePB]("service \"web\" enabled=#false")
    check r.isOk
    check r.get.enabled == false

# Cycle 5 — Nim field defaults are respected when the prop is absent.
type ServiceD {.kdlNode: "service".} = object
  name {.kdlArg.}: string
  port {.kdlProp.}: int = 80
  enabled {.kdlProp.}: bool = true

derivePDADecode(ServiceD)

suite "pda_decode — Sprint 1 cycle 5: field defaults":

  test "default value used when prop absent":
    let r = decodePDA[ServiceD]("service \"web\"")
    check r.isOk
    check r.get.name == "web"
    check r.get.port == 80
    check r.get.enabled == true

  test "explicit prop overrides default":
    let r = decodePDA[ServiceD]("service \"web\" port=443 enabled=#false")
    check r.isOk
    check r.get.port == 443
    check r.get.enabled == false

# Cycle 6 — multiple positional kdlArgs (declaration order).
type Pair {.kdlNode: "pair".} = object
  left {.kdlArg.}: string
  right {.kdlArg.}: string

derivePDADecode(Pair)

suite "pda_decode — Sprint 1 cycle 6: multiple positional args":

  test "two string kdlArgs decode in declaration order":
    let r = decodePDA[Pair]("pair \"alpha\" \"beta\"")
    check r.isOk
    check r.get.left == "alpha"
    check r.get.right == "beta"

# Cycle 7 — wrong node name produces Err (already verified by the
# tracer's negative branch, but assert it explicitly so future
# regressions can't pass silently).
suite "pda_decode — Sprint 1 cycle 7: wrong node name":

  test "mismatched bareword returns Err":
    let r = decodePDA[Service]("other \"value\"")
    check r.isErr

# Cycle 8 — required prop (no default) absent from input → Err.
type ServiceR {.kdlNode: "service".} = object
  name {.kdlArg.}: string
  port {.kdlProp.}: int  # no `= 80` default → required

derivePDADecode(ServiceR)

suite "pda_decode — Sprint 1 cycle 8: required prop missing":

  test "required prop absent returns Err":
    let r = decodePDA[ServiceR]("service \"web\"")
    check r.isErr

  test "required prop present decodes":
    let r = decodePDA[ServiceR]("service \"web\" port=80")
    check r.isOk
    check r.get.port == 80

# Cycle 9 — decodePDA[seq[T]] over multi-node input.
suite "pda_decode — Sprint 1 cycle 9: seq[T] at top level":

  test "two nodes decode into a seq":
    let src = "service \"web\" port=80\nservice \"api\" port=443"
    let r = decodePDA[seq[ServiceP]](src)
    check r.isOk
    check r.get.len == 2
    check r.get[0].name == "web"
    check r.get[0].port == 80
    check r.get[1].name == "api"
    check r.get[1].port == 443

  test "empty input decodes to empty seq":
    let r = decodePDA[seq[ServiceP]]("")
    check r.isOk
    check r.get.len == 0
