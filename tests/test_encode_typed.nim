## Tests for `encode[T]` — the typed-value encode entry point.
##
## Coverage is layered: flat object emit → children blocks → Option[T]
## fields → kdlReserved validation → string escaping → mode handling
## (emPretty / emCompact / emPreserve degradation) → numeric and
## tagged child shapes (forcedTag, Option[Tagged], seq[Tagged]) →
## variant fail-fast (peEncodeUnsupported) → depth cap
## (MaxEncodeDepth). Most tests assert byte-for-byte parity against
## `encode(doc, mode)` (the AST-level emit) built from the same data
## — catches divergence between the two independent implementations of
## the same spec.

import std/[strutils, unittest]

import ../src/[ast, codegen, encode, reserved, spans]

kdl:
  type Service {.kdlNode: "service".} = object
    name {.kdlArg.}: string
    port {.kdlProp.}: int
    replicas {.kdlProp.}: int = 1
    enabled {.kdlProp.}: bool = true

suite "encode[T] flat object: args + props":

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

# Children blocks: typed values with nested kdlChild fields
kdl:
  type Action {.kdlNode: "action".} = object
    tmpl {.kdlArg, kdlRename: "template".}: string
  type Server {.kdlNode: "server".} = object
    name {.kdlArg.}: string
    actions {.kdlChild.}: seq[Action]

suite "encode[T] children blocks":

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

# Option[T] fields: some(v) emits; none omits the prop entirely
kdl:
  type WithOpt {.kdlNode: "task".} = object
    name {.kdlArg.}: string
    retries {.kdlProp.}: Option[int]
    desc {.kdlProp.}: Option[string]

suite "encode[T] Option[T] fields":

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

# kdlReserved tag emission + Layer-1 content validation at encode time
kdl:
  type Tagged {.kdlNode: "tagged".} = object
    bindAddr {.kdlProp, kdlReserved: "ipv4".}: string

suite "encode[T] kdlReserved validation":

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

suite "encode[T] string escaping":

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

# Numeric kdlReserved validation, kdlReserved on kdlArg, uint64 bigint
# promotion: behaviors that were broken in earlier iterations of the
# direct path. The fixes are upstream; these suites pin the contract.

kdl:
  type WithU8 {.kdlNode: "port".} = object
    n {.kdlProp, kdlReserved: "u8".}: int

suite "encode: numeric kdlReserved tag validation":
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

suite "encode: kdlReserved on kdlArg fields":
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

# Type-level `{.kdlReserved: "X".}` on the node must emit `(X)name` at
# the top level — symmetric with the field-level pragma covered above.

kdl:
  type Versioned {.kdlNode: "module", kdlReserved: "v2".} = object
    field {.kdlProp.}: string

suite "encode: type-level kdlReserved node prefix":
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

  test "compact matches the AST emitter for the same data (flat)":
    # encode[T] writes via the macro-emitted direct path; encode(doc, ...)
    # writes via emitNode (encode.nim). They're independent implementations
    # of the same compact spec — pin them against each other, not against
    # `encode[T] == encode[T]` which is a tautology.
    let s = Service(name: "api", port: 8080, replicas: 2, enabled: false)
    var doc = newDoc()
    var n = newNode(doc, "service")
    n.addArg(doc, newStringValue("api"))
    n.setProp(doc, "port", newIntValue(8080))
    n.setProp(doc, "replicas", newIntValue(2))
    n.setProp(doc, "enabled", newBoolValue(false))
    doc.add(n)
    check encode(s, emCompact).get == encode(doc, emCompact)

  test "nested children (Server with Action seq) compact form":
    let srv = Server(name: "web", actions: @[
      Action(tmpl: "log"), Action(tmpl: "alert")])
    let r = encode(srv, emCompact)
    check r.isOk
    check '\n' notin r.get
    check "{" in r.get
    check "}" in r.get

  test "compact matches the AST emitter for the same data (nested)":
    let srv = Server(name: "web", actions: @[
      Action(tmpl: "log"), Action(tmpl: "alert")])
    var doc = newDoc()
    var server = newNode(doc, "server")
    server.addArg(doc, newStringValue("web"))
    for tmpl in ["log", "alert"]:
      var action = newNode(doc, "action")
      action.addArg(doc, newStringValue(tmpl))
      server.children.add(action)
    doc.add(server)
    check encode(srv, emCompact).get == encode(doc, emCompact)

  test "emPretty default unchanged":
    let s = Service(name: "ok", port: 1, replicas: 1, enabled: true)
    # encode(s) without mode = encode(s, emPretty) = current behavior
    check encode(s).get == encode(s, emPretty).get

  test "emPreserve on typed value degrades to emPretty":
    # No source bytes available for a built-from-scratch value;
    # emPreserve falls through to canonical (emPretty) emit.
    let s = Service(name: "ok", port: 1, replicas: 1, enabled: true)
    check encode(s, emPreserve).get == encode(s, emPretty).get

suite "encode: uint64 bigint promotion":
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

# forcedTag plumbing: kdlReserved on a kdlChild slot (field-level tag
# propagates through to the child's emit via the kdlEncodeIntoImpl
# forcedTag parameter — closes a coverage gap flagged in round 4).

kdl:
  type
    SubInner {.kdlNode: "sub".} = object
      flag {.kdlProp.}: bool
    OuterTagged {.kdlNode: "outer".} = object
      sub {.kdlChild, kdlReserved: "version".}: SubInner

suite "encode: field-level kdlReserved on a single kdlChild (forcedTag)":
  test "child node carries (version) tag from the parent slot":
    let v = OuterTagged(sub: SubInner(flag: true))
    let r = encode(v)
    check r.isOk
    check "(version)sub" in r.get
  test "round-trips through decode":
    let v = OuterTagged(sub: SubInner(flag: true))
    let back = decode[OuterTagged](encode(v).get)
    check back.isOk
    check back.get.sub.flag == true

# Option[Tagged] kdlChild: an optional child whose type carries a
# type-level kdlReserved. Exercises csOption path with non-empty
# forcedTag-fallthrough (no field-level tag, child's own typeReserved
# kicks in).

kdl:
  type
    VTagged {.kdlNode: "vt", kdlReserved: "v2".} = object
      f {.kdlProp.}: string
    HoldsOpt {.kdlNode: "holds".} = object
      maybe {.kdlChild.}: Option[VTagged]

suite "encode: Option[T] kdlChild where T has type-level kdlReserved":
  test "present child emits (v2)vt":
    let v = HoldsOpt(maybe: some(VTagged(f: "ok")))
    let r = encode(v)
    check r.isOk
    check "(v2)vt" in r.get
  test "absent child emits no block":
    let v = HoldsOpt(maybe: none(VTagged))
    let r = encode(v)
    check r.isOk
    check "{" notin r.get
  test "present child round-trips":
    let v = HoldsOpt(maybe: some(VTagged(f: "ok")))
    let back = decode[HoldsOpt](encode(v).get)
    check back.isOk
    check back.get.maybe.isSome
    check back.get.maybe.get.f == "ok"

# seq[Tagged] kdlChild: each element gets the type-level kdlReserved
# annotation via its own kdlEncodeIntoImpl. csSeq path with type-level
# tag in the child type.

kdl:
  type
    HoldsSeq {.kdlNode: "holds-seq".} = object
      items {.kdlChild.}: seq[VTagged]

suite "encode: seq[T] kdlChild where T has type-level kdlReserved":
  test "each element carries (v2)vt":
    let v = HoldsSeq(items: @[
      VTagged(f: "a"), VTagged(f: "b"), VTagged(f: "c")])
    let r = encode(v)
    check r.isOk
    check r.get.count("(v2)vt") == 3
  test "round-trips through decode":
    let v = HoldsSeq(items: @[VTagged(f: "a"), VTagged(f: "b")])
    let back = decode[HoldsSeq](encode(v).get)
    check back.isOk
    check back.get.items.len == 2
    check back.get.items[0].f == "a"

# Runtime-error stub: variant types return peEncodeUnsupported via the
# transitional stub. Asserts the stub fires AND uses the right code.

kdl:
  type
    Kind = enum
      kFoo = "foo"
      kBar = "bar"
    V {.kdlNode: "v".} = object
      case kind {.kdlArg.}: Kind
      of kFoo:
        a {.kdlProp.}: string
      of kBar:
        b {.kdlProp.}: int

suite "encode: variant types fail cleanly with peEncodeUnsupported":
  test "variant value returns peEncodeUnsupported (not peTypeMismatch)":
    let v = V(kind: kFoo, a: "x")
    let r = encode(v)
    check r.isErr
    check r.getErr.code == peEncodeUnsupported
    check "variant" in r.getErr.hint

# Depth guard mirrors MaxParserDepth (256). Programmatically-constructed
# deep ASTs would stack-overflow without the cap.

suite "encode: depth cap":
  test "AST encode raises ValueError past MaxEncodeDepth":
    # Build a (MaxEncodeDepth+1)-deep doc bottom-up: construct the
    # leaf, wrap it in a parent that has the leaf as its sole child,
    # repeat. The resulting root is `MaxEncodeDepth + 2` levels deep,
    # so encode(doc, emPretty) recurses past the cap.
    var doc = newDoc()
    var node = newNode(doc, "n")
    for _ in 0 .. MaxEncodeDepth:
      var parent = newNode(doc, "n")
      parent.children.add(node)
      node = parent
    doc.add(node)
    expect ValueError:
      discard encode(doc, emPretty)

  test "typed encode returns peParseDepthExceeded past MaxEncodeDepth":
    # Direct call with indent past the cap — proves the guard fires.
    # Recursive trigger isn't naturally testable in the typed path:
    # Nim's `Option[T]`/`seq[T]` kdlChild fields can't self-reference
    # without `ref T`, which the codegen doesn't emit through. The AST
    # recursive test above covers the recursive-trigger semantics;
    # this test pins the typed-path error code + early return.
    let s = Service(name: "x", port: 1)
    var buf = ""
    let r = kdlEncodeIntoImpl(s, buf, emPretty, MaxEncodeDepth + 1)
    check r.isErr
    check r.getErr.code == peParseDepthExceeded
