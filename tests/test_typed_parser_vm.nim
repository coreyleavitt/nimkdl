## VM compatibility spike for parseInto[T] (cycle 7.5).
##
## If this compiles, the visitor-based typed-direct path works at
## compile time too — which means we can collapse the `when nimvm`
## split and retire kdlDecodeImpl entirely. If it fails, we know
## the blocker (most likely `cast[string]` in the generated
## visitProp, per PhD review).
##
## The test runs parseInto[Service] inside a `static:` block, which
## forces NimVM evaluation. Any VM-incompatibility surfaces as a
## compile-time error here.

import std/unittest
import ../src/[lexer, intern, numlit, spans, typed_parser]
import ../src/codegen

type ServiceVM {.kdlNode: "service".} = object
  name {.kdlArg.}: string
  port {.kdlProp.}: int
  replicas {.kdlProp.}: int = 1

deriveVisitor(ServiceVM)

# This block runs at compile time. If parseInto[ServiceVM] can't
# execute in the VM, this fails to compile.
static:
  let r = parseInto[ServiceVM]("service \"vm-test\" port=9999")
  doAssert r.isOk
  doAssert r.get.name == "vm-test"
  doAssert r.get.port == 9999
  doAssert r.get.replicas == 1   # default fires

suite "VM compatibility":
  test "parseInto[T] executes in NimVM":
    # If we reached the test runner at all, the static: block above
    # compiled — which is the actual assertion. Just confirm the
    # runtime equivalent also works.
    let r = parseInto[ServiceVM]("service \"runtime\" port=8888")
    check r.isOk
    check r.get.name == "runtime"
    check r.get.port == 8888
