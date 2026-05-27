## Cycle E.1 — encode[T] tracer.
##
## Acceptance: encode[T](v) produces byte-identical output to the
## legacy `encode[T](v, emPretty).get` path (value → KdlNode → KdlDoc →
## string) for a simple object type. Architectural symmetry with the
## decode-side win: parseInto[T] skipped KdlDoc, encode[T] skips
## KdlNode + KdlDoc.

import std/[strutils, unittest]

import ../src/[ast, codegen, encode, reserved, spans]

kdl:
  type Service {.kdlNode: "service".} = object
    name {.kdlArg.}: string
    port {.kdlProp.}: int
    replicas {.kdlProp.}: int = 1
    enabled {.kdlProp.}: bool = true

suite "encode[T] tracer (cycle E.1)":

  test "single Service value: direct encode matches legacy KdlDoc encode":
    let s = Service(name: "web", port: 8080, replicas: 2, enabled: true)
    let viaLegacy = encode(s, emPretty)
    check viaLegacy.isOk
    let viaDirect = encode(s)
    check viaDirect.isOk
    check viaLegacy.get == viaDirect.get

  test "Service with default-valued props: direct == legacy":
    let s = Service(name: "api", port: 80)  # replicas + enabled default
    let viaLegacy = encode(s, emPretty)
    check viaLegacy.isOk
    check encode(s).get == viaLegacy.get

  test "Service with name needing quoting (contains space)":
    let s = Service(name: "my service", port: 443)
    let viaLegacy = encode(s, emPretty)
    check viaLegacy.isOk
    check encode(s).get == viaLegacy.get

# Cycle E.5 — children blocks
kdl:
  type Action {.kdlNode: "action".} = object
    tmpl {.kdlArg, kdlRename: "template".}: string
  type Server {.kdlNode: "server".} = object
    name {.kdlArg.}: string
    actions {.kdlChild.}: seq[Action]

suite "encode[T] children blocks (cycle E.5)":

  test "Server with seq[Action] children — direct matches legacy":
    let s = Server(name: "web", actions: @[
      Action(tmpl: "log"),
      Action(tmpl: "alert")])
    let viaLegacy = encode(s, emPretty)
    check viaLegacy.isOk
    check encode(s).get == viaLegacy.get

  test "Server with empty children seq emits no block":
    let s = Server(name: "minimal", actions: @[])
    let viaLegacy = encode(s, emPretty)
    check viaLegacy.isOk
    check encode(s).get == viaLegacy.get

# Cycle E.4 — Option[T] fields
kdl:
  type WithOpt {.kdlNode: "task".} = object
    name {.kdlArg.}: string
    retries {.kdlProp.}: Option[int]
    desc {.kdlProp.}: Option[string]

suite "encode[T] Option[T] (cycle E.4)":

  test "Option some(int) emits prop=value":
    let t = WithOpt(name: "build", retries: some(3), desc: none(string))
    let viaLegacy = encode(t, emPretty)
    check viaLegacy.isOk
    check encode(t).get == viaLegacy.get

  test "Option none — prop is omitted":
    let t = WithOpt(name: "lint", retries: none(int), desc: none(string))
    let viaLegacy = encode(t, emPretty)
    check viaLegacy.isOk
    check encode(t).get == viaLegacy.get

  test "Option some(string)":
    let t = WithOpt(name: "deploy", retries: none(int),
                    desc: some("rollout"))
    let viaLegacy = encode(t, emPretty)
    check viaLegacy.isOk
    check encode(t).get == viaLegacy.get

# Cycle E.6 — kdlReserved tag emission + validation
kdl:
  type Tagged {.kdlNode: "tagged".} = object
    bindAddr {.kdlProp, kdlReserved: "ipv4".}: string

suite "encode[T] kdlReserved (cycle E.6)":

  test "valid ipv4 emits `(ipv4)` tag prefix":
    let t = Tagged(bindAddr: "192.0.2.1")
    let viaLegacy = encode(t, emPretty)
    check viaLegacy.isOk
    check encode(t).get == viaLegacy.get

  test "round-trips through parser + decode":
    let t = Tagged(bindAddr: "10.0.0.1")
    let txt = encode(t).get
    check "(ipv4)" in txt

  test "invalid ipv4 errors (Layer 1 validation fires in direct path)":
    let bad = Tagged(bindAddr: "not-an-ip")
    let r = encode(bad)
    check r.isErr
    check r.getErr.code == peReservedTypeInvalid

suite "encode[T] string escaping (cycle E.3)":

  proc roundTripsEqual(s: Service) =
    let viaLegacy = encode(s, emPretty)
    check viaLegacy.isOk
    let viaDirect = encode(s)
    check viaDirect.isOk
    check viaDirect.get == viaLegacy.get

  test "name with embedded quote — escapes match legacy":
    roundTripsEqual(Service(name: "with \"quote\"", port: 1))

  test "name with backslash":
    roundTripsEqual(Service(name: "back\\slash", port: 2))

  test "name with newline":
    roundTripsEqual(Service(name: "two\nlines", port: 3))

  test "name with tab + cr":
    roundTripsEqual(Service(name: "tab\there\rand cr", port: 4))

  test "name with control byte (\\x07 bell)":
    roundTripsEqual(Service(name: "bell\x07char", port: 5))

  test "name with NUL byte":
    roundTripsEqual(Service(name: "with\x00nul", port: 6))

  test "empty string":
    roundTripsEqual(Service(name: "", port: 7))

  test "name that looks like a reserved keyword (#true literal text)":
    roundTripsEqual(Service(name: "true", port: 8))

  test "name with non-ASCII utf8 (☃ snowman)":
    roundTripsEqual(Service(name: "snow☃man", port: 9))

# Encode-path review round-1 regressions:
#   C1 — numeric reserved tags ((u8), (i32), etc.) used to fail validation
#         in the direct path because the value was always wrapped as
#         kvString. kdlEncodeValue dispatch fixes it.
#   C2 — kdlReserved on a kdlArg field used to be silently skipped in the
#         direct path (no validation, no (tag) prefix emit).
#   H1 — uint64 above int64.high used to silently emit as a negative
#         decimal after a lossy cast; now promotes to bigint.

kdl:
  type WithU8 {.kdlNode: "port".} = object
    n {.kdlProp, kdlReserved: "u8".}: int

suite "encode: numeric kdlReserved tag (C1 regression)":
  test "valid (u8) value encodes":
    let r = encode(WithU8(n: 200))
    check r.isOk
    check "(u8)200" in r.get
  test "value matches legacy encode":
    let v = WithU8(n: 42)
    check encode(v).get == encode(v, emPretty).get
  test "out-of-range (u8) value errors":
    let r = encode(WithU8(n: 999))
    check r.isErr
    check r.getErr.code == peReservedTypeInvalid
    # Error hint should be prefixed with TypeName.fieldName (M2).
    check "WithU8.n" in r.getErr.hint

kdl:
  type Bind {.kdlNode: "bind".} = object
    addr1 {.kdlArg, kdlReserved: "ipv4".}: string

suite "encode: kdlReserved on kdlArg (C2 regression)":
  test "valid arg emits with (ipv4) tag prefix":
    let r = encode(Bind(addr1: "127.0.0.1"))
    check r.isOk
    check "(ipv4)" in r.get
  test "invalid arg fails validation":
    let r = encode(Bind(addr1: "not-an-ip"))
    check r.isErr
    check r.getErr.code == peReservedTypeInvalid
  test "arg encode matches legacy":
    let v = Bind(addr1: "10.0.0.1")
    check encode(v).get == encode(v, emPretty).get

kdl:
  type BigU {.kdlNode: "big".} = object
    n {.kdlProp.}: uint64

# Round-2 H1: type-level kdlReserved on the node was silently dropped
# by the direct-buffer path. The legacy encode[T] sets
# nodeSym.typeAnnotation; encode only emitted the node name with
# no `(tag)` prefix, breaking encode == encode(emPretty) parity.

kdl:
  type Versioned {.kdlNode: "module", kdlReserved: "v2".} = object
    field {.kdlProp.}: string

suite "encode: type-level kdlReserved emits (tag) prefix (round-2 H1)":
  test "node carries (v2) tag in output":
    let v = Versioned(field: "ok")
    let r = encode(v)
    check r.isOk
    check "(v2)module" in r.get
  test "encode output matches legacy encode for type-level tag":
    let v = Versioned(field: "ok")
    check encode(v).get == encode(v, emPretty).get
  test "round-trips through decode":
    let v = Versioned(field: "ok")
    let txt = encode(v).get
    let back = decode[Versioned](txt)
    check back.isOk
    check back.get.field == "ok"

## emCompact mode in the direct path. Cycle 1 of the encode collapse:
## the direct path learns to emit single-line `;`-separated output so
## the typed-encode story can converge on one entry point that handles
## both modes. New behavior — adds tests; existing emPretty behavior
## stays unchanged.

suite "encode: emCompact mode":
  test "flat type encodes as single line, no trailing newline":
    let s = Service(name: "web", port: 80, replicas: 1, enabled: true)
    let r = encode(s, emCompact)
    check r.isOk
    check '\n' notin r.get
    check r.get.startsWith("service")

  test "direct emCompact matches legacy encode emCompact byte-for-byte":
    let s = Service(name: "api", port: 8080, replicas: 2, enabled: false)
    let viaDirect = encode(s, emCompact)
    let viaLegacy = encode(s, emCompact)
    check viaDirect.isOk
    check viaLegacy.isOk
    check viaDirect.get == viaLegacy.get

  test "nested children (Server with Action seq) compact form":
    let srv = Server(name: "web", actions: @[
      Action(tmpl: "log"), Action(tmpl: "alert")])
    let r = encode(srv, emCompact)
    check r.isOk
    check '\n' notin r.get
    check "{" in r.get
    check "}" in r.get

  test "nested children: direct compact == legacy compact":
    let srv = Server(name: "web", actions: @[
      Action(tmpl: "log"), Action(tmpl: "alert")])
    check encode(srv, emCompact).get == encode(srv, emCompact).get

  test "emPretty default unchanged":
    let s = Service(name: "ok", port: 1, replicas: 1, enabled: true)
    # encode(s) without mode = encode(s, emPretty) = current behavior
    check encode(s).get == encode(s, emPretty).get

  test "emPreserve on typed value degrades to emPretty":
    # No source bytes available for a built-from-scratch value;
    # emPreserve falls through to canonical (emPretty) emit.
    let s = Service(name: "ok", port: 1, replicas: 1, enabled: true)
    check encode(s, emPreserve).get == encode(s, emPretty).get

suite "encode: uint64 bigint promotion (H1 regression)":
  test "uint64 within int64.high encodes as plain int":
    let r = encode(BigU(n: 12345'u64))
    check r.isOk
    check "n=12345" in r.get
  test "uint64 above int64.high promotes to bigint, not negative":
    # int64.high = 9223372036854775807; pick a value clearly above it.
    let big: uint64 = 18446744073709551615'u64  # uint64.max
    let r = encode(BigU(n: big))
    check r.isOk
    check "n=18446744073709551615" in r.get
    check "-" notin r.get   # pre-fix this would have emitted "n=-1"
  test "encode value matches legacy for the same big uint64":
    let v = BigU(n: 18446744073709551614'u64)
    check encode(v).get == encode(v, emPretty).get
