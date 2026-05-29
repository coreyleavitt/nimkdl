## D13 — embed[T] VM-compat. The macro-emitted kdlDecode runs in
## NimVM at compile time, so `const cfg = embed[T](staticSrc)`
## materializes a const T baked into the binary with zero runtime
## parse cost.
##
## The trigger that originally broke this was `cursor.bytesEq`'s
## `equalMem(unsafeAddr ...)` path — C memcmp doesn't exist in NimVM.
## Fixed via `when nimvm` byte-loop fallback in the template; that's
## what makes every test in this file compile.

import std/unittest

import ../src/derive_decode
import ../src/pragmas

# --- simplest case ---

type Bare {.kdlNode: "bare".} = object
  name {.kdlArg.}: string

deriveDecode(Bare)

# --- typed primitives ---

type Service {.kdlNode: "service".} = object
  name {.kdlArg.}: string
  port {.kdlProp.}: int
  enabled {.kdlProp.}: bool

deriveDecode(Service)

# --- self-recursive Tree (depth proves child-loop is VM-safe too) ---

type Tree {.kdlNode: "tree".} = object
  value {.kdlArg.}: string
  children {.kdlChild.}: seq[Tree]

deriveDecode(Tree)

# --- enum decode in VM ---

type Status = enum
  sOk = "ok"
  sFailed = "failed"

type Job {.kdlNode: "job".} = object
  name {.kdlArg.}: string
  state {.kdlProp.}: Status

deriveDecode(Job)

# Compile-time evaluations. If any of these fail to compile, embed[T]
# is broken — these are the proof.
const bareWeb = embed[Bare]("bare \"web\"")
const svcWeb = embed[Service]("service \"web\" port=80 enabled=#true")
const svcApi = embed[Service]("service \"api\" port=443 enabled=#false")
const treeRoot = embed[Tree]("tree \"root\" {\n    tree \"a\"\n    tree \"b\" {\n        tree \"b1\"\n    }\n}")
const jobOk = embed[Job]("job \"compaction\" state=\"ok\"")

suite "embed[T] — compile-time decode":

  test "simplest single-field type":
    check bareWeb.name == "web"

  test "Service with string + int + bool":
    check svcWeb.name == "web"
    check svcWeb.port == 80
    check svcWeb.enabled == true
    check svcApi.name == "api"
    check svcApi.port == 443
    check svcApi.enabled == false

  test "self-recursive Tree at depth 3":
    check treeRoot.value == "root"
    check treeRoot.children.len == 2
    check treeRoot.children[0].value == "a"
    check treeRoot.children[0].children.len == 0
    check treeRoot.children[1].value == "b"
    check treeRoot.children[1].children.len == 1
    check treeRoot.children[1].children[0].value == "b1"

  test "enum field with string-mapped variants":
    check jobOk.name == "compaction"
    check jobOk.state == sOk
