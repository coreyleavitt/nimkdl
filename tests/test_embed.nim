## D13 — embed[T] VM-compat. The macro-emitted kdlDecode runs in
## NimVM at compile time, so `const cfg = embed[T](staticSrc)`
## materializes a const T baked into the binary with zero runtime
## parse cost.
##
## What made this work: the dispatch substrate is pure Nim
## end-to-end. `bytesEqLit` is a macro that emits inline byte
## compares with literal-known length + literal-known bytes, so the
## compiler folds them (often into SIMD) at every call site. No FFI,
## no `when nimvm` split — same code at runtime and at compile time.

import std/unittest

import ../src/api
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

# --- S9 untagged variant decode in VM ---
# The try-each-branch decoder uses cursor pos/seek to rewind between branch
# attempts. Both are side-effect-free + VM-evaluable, so an untagged variant
# decodes at compile time like any other derived type (S9 VM-safety AC).

type Payload = enum
  plText = "text"
  plNum = "num"

type Msg {.kdlNode: "msg", kdlUntagged.} = object
  case kind: Payload
  of plText:
    body {.kdlProp.}: string
  of plNum:
    value {.kdlProp.}: int

deriveDecode(Msg)

# Compile-time evaluations. If any of these fail to compile, embed[T]
# is broken — these are the proof.
const bareWeb = embed[Bare]("bare \"web\"")
const svcWeb = embed[Service]("service \"web\" port=80 enabled=#true")
const svcApi = embed[Service]("service \"api\" port=443 enabled=#false")
const treeRoot = embed[Tree]("tree \"root\" {\n    tree \"a\"\n    tree \"b\" {\n        tree \"b1\"\n    }\n}")
const jobOk = embed[Job]("job \"compaction\" state=\"ok\"")
const msgText = embed[Msg]("msg body=\"hi\"")
const msgNum = embed[Msg]("msg value=5")

# --- D1: embedFile[T] — compile-time staticRead + decode ---
# Path is relative to THIS file (staticRead/gorge semantics), so the
# fixture under tests/fixtures resolves as "fixtures/embed_service.kdl".
const svcFromFile = embedFile[Service]("fixtures/embed_service.kdl")

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

  test "S9 untagged variant decodes at compile time (try-each-branch in VM)":
    check msgText.kind == plText
    check msgText.body == "hi"
    check msgNum.kind == plNum
    check msgNum.value == 5

  test "embedFile[T] staticReads + decodes a fixture at compile time (D1)":
    check svcFromFile.name == "web"
    check svcFromFile.port == 80
    check svcFromFile.enabled == true
