## Smoke test for the `kdl:` block macro. Wraps `type T {.kdlNode.}`
## definitions and auto-emits decode + encode + typed-direct surfaces.

import std/[strutils, unittest]

import ../src/[nkdl]

kdl:
  type Service {.kdlNode: "service".} = object
    name {.kdlArg.}: string
    port {.kdlProp.}: int
    replicas {.kdlProp.}: int = 1
    enabled {.kdlProp.}: bool = true

  type Action {.kdlNode: "action".} = object
    tmpl {.kdlArg, kdlRename: "template".}: string

suite "kdl: block macro":

  test "decode[T] works (deriveDecode emitted)":
    let r = decode[Service]("""service "web" port=80""")
    check r.isOk
    check r.get.name == "web"
    check r.get.port == 80
    check r.get.replicas == 1     # default fired
    check r.get.enabled == true   # default fired

  test "parseInto[T] works (deriveVisitor emitted)":
    let r = parseInto[Service]("""service "api" port=443 replicas=3 enabled=#false""")
    check r.isOk
    check r.get.name == "api"
    check r.get.port == 443
    check r.get.replicas == 3
    check r.get.enabled == false

  test "encode[T] works (deriveEncode emitted)":
    let s = Service(name: "deploy", port: 22, replicas: 2, enabled: true)
    let r = encode(s)
    check r.isOk
    check r.get.len > 0
    check "service" in r.get
    check "deploy" in r.get

  # Other gets its own top-level block (below the suite) — derives
  # contain top-level `export` calls that can't live inside a test proc.
  test "second type from the same module-level kdl block":
    let d = decode[Action](""" action "log" """).get
    check d.tmpl == "log"
    let e = encode(Action(tmpl: "alert")).get
    check "alert" in e
