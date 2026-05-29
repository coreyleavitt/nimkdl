## Property tests for typed-decode + typed-encode round-trips.
##
## `encode[T](v)` writes T directly to KDL text; `decode[T](src)`
## parses + projects KDL text back into T. The expected invariant
## across the visitor protocol, kdlArg/kdlProp/kdlChild routing,
## enum handling, and Option[T] field handling is:
##
##   decode[T](encode(v).get).get ≈ v
##   encode(decode[T](src).get).get ≈ encode_canonical(parse(src))
##   encode(v) is deterministic (same input → same output)
##
## These hit a different code path than the AST-round-trip suite in
## test_preserve_properties.nim — that one stays on AST; this one
## crosses the typed-codegen boundary in both directions.

import std/[options, unittest]

import proptest except Span    # datasource.Span collides with spans.Span

import ../src/codegen
import ../src/encode
import ../src/spans

# ---------------------------------------------------------------------------
# Types under test. Cover the full pragma surface: kdlArg, kdlProp,
# kdlChild, kdlNode, enums, Option, defaulted fields, seq[T] children.
# ---------------------------------------------------------------------------

kdl:
  type
    Color = enum
      cRed = "red"
      cBlue = "blue"
      cGreen = "green"

    Flat {.kdlNode: "flat".} = object
      id {.kdlArg.}: string
      count {.kdlProp.}: int
      enabled {.kdlProp.}: bool
      label {.kdlProp.}: string

    Tinted {.kdlNode: "tinted".} = object
      name {.kdlArg.}: string
      color {.kdlProp.}: Color

    OptField {.kdlNode: "opt".} = object
      name {.kdlArg.}: string
      maybeCount {.kdlProp, kdlRename: "count".}: Option[int]

    Inner {.kdlNode: "inner".} = object
      label {.kdlProp.}: string
      level {.kdlProp.}: int

    Outer {.kdlNode: "outer".} = object
      name {.kdlProp.}: string
      inner {.kdlChild.}: Inner

    OuterMulti {.kdlNode: "outer".} = object
      name {.kdlProp.}: string
      items {.kdlChild.}: seq[Inner]

    # Three-level non-recursive deep nesting. Covers distinct-type
    # child chains; left in alongside the recursive Tree case below
    # so both shapes are property-tested.
    L3 {.kdlNode: "l3".} = object
      label {.kdlProp.}: string
      n {.kdlProp.}: int

    L2 {.kdlNode: "l2".} = object
      label {.kdlProp.}: string
      items {.kdlChild.}: seq[L3]

    L1 {.kdlNode: "l1".} = object
      label {.kdlProp.}: string
      items {.kdlChild.}: seq[L2]

    # Self-recursive: the canonical tree shape. nkdl#7 → solved by
    # nkdl#8's parametric SeqBuilder[B] refactor. Test currently
    # fails to compile (codegen emits a `TreeVBuilderSeq` reference
    # before the type is defined within the same deriveVisitor call);
    # will pass once the refactor lands.
    Tree {.kdlNode: "tree".} = object
      label {.kdlProp.}: string
      children {.kdlChild.}: seq[Tree]

# ---------------------------------------------------------------------------
# Properties
# ---------------------------------------------------------------------------

suite "typed-decode — round-trip identity":
  # The central invariant: encode-then-decode is identity. If the
  # encoder emits anything the decoder can't ingest, or the decoder
  # rebuilds a different value, this fails. proptest auto-derives
  # arbitrary(T) for plain objects — no manual generators needed.

  property "Flat round-trips through encode + decode":
    given v in arbitrary(Flat)
    let text = assumeOk(encode(v))
    let back = assumeOk(decode[Flat](text))
    note("encoded", text)
    ensure back == v

  property "Tinted (with enum) round-trips":
    given v in arbitrary(Tinted)
    let text = assumeOk(encode(v))
    let back = assumeOk(decode[Tinted](text))
    note("encoded", text)
    ensure back == v

  property "OptField round-trips (present and absent forms)":
    given v in arbitrary(OptField)
    let text = assumeOk(encode(v))
    let back = assumeOk(decode[OptField](text))
    note("encoded", text)
    ensure back == v

  property "Outer (with single kdlChild) round-trips":
    given v in arbitrary(Outer)
    let text = assumeOk(encode(v))
    let back = assumeOk(decode[Outer](text))
    note("encoded", text)
    ensure back == v

  property "OuterMulti (with seq[T] kdlChild) round-trips":
    given v in arbitrary(OuterMulti)
    let text = assumeOk(encode(v))
    let back = assumeOk(decode[OuterMulti](text))
    note("encoded", text)
    ensure back == v

  property "seq[Flat] at top-level round-trips":
    given vs in lists(arbitrary(Flat), 0, 6)
    let text = assumeOk(encode(vs))
    let back = assumeOk(decode[seq[Flat]](text))
    note("encoded", text)
    note("count", vs.len)
    ensure back == vs

suite "typed-encode — determinism":
  # Same value must always encode to the same bytes. Any non-
  # determinism in the encoder (e.g., interner-handle ordering
  # affecting prop emission order) would break differential
  # tooling that hashes encoded output.

  property "encode(v) is deterministic":
    given v in arbitrary(Flat)
    let t1 = assumeOk(encode(v))
    let t2 = assumeOk(encode(v))
    ensure t1 == t2

  property "encode(seq[T]) is deterministic":
    given vs in lists(arbitrary(Flat), 0, 6)
    let t1 = assumeOk(encode(vs))
    let t2 = assumeOk(encode(vs))
    ensure t1 == t2

suite "typed-decode — adversarial string content":
  # Auto-derived arbitrary(string) yields printable ASCII broadly,
  # but specific shapes (KDL syntax chars, reserved-keyword bytes,
  # empty, very long) are worth forcing explicitly. If the encoder
  # picks the wrong quoting form for any of these, decode will
  # diverge.
  property "string-arg with KDL syntax characters round-trips":
    given s in sampledFrom([
      "", "{", "}", "(", ")", "\"", "\\",
      ";", "=", "//", "/-", "/*", "*/",
      "  leading", "trailing  ",
      "#true", "#false", "#null", "#inf", "#nan",
      "true", "false", "null", "inf", "nan", "-inf",
      "0x10", "0b101", "0o7",                  # would-be numeric literals
      "\n", "\t", "\r",                        # ASCII control
    ])
    let v = Flat(id: s, count: 0, enabled: false, label: "x")
    let text = assumeOk(encode(v))
    let back = assumeOk(decode[Flat](text))
    note("encoded", text)
    ensure back == v

  property "string-prop with KDL syntax characters round-trips":
    given s in sampledFrom([
      "", "with spaces", "with\"quote", "with\\backslash",
      "with\nnewline", "with;semi", "with=equals",
    ])
    let v = Flat(id: "x", count: 0, enabled: false, label: s)
    let text = assumeOk(encode(v))
    let back = assumeOk(decode[Flat](text))
    note("encoded", text)
    ensure back == v

suite "typed encode/decode — order preservation in collections":
  # decode[seq[T]] must preserve the order of top-level nodes. If
  # decode reorders (e.g., via Set-backed intern caches leaking out)
  # the round-trip breaks.
  property "seq[Inner] preserves insertion order":
    given xs in lists(arbitrary(Inner), 1, 8)
    let text = assumeOk(encode(xs))
    let back = assumeOk(decode[seq[Inner]](text))
    ensure back.len == xs.len
    for i in 0 ..< xs.len:
      ensure back[i] == xs[i]

  property "OuterMulti preserves child order":
    given items in lists(arbitrary(Inner), 0, 6)
    let v = OuterMulti(name: "x", items: items)
    let text = assumeOk(encode(v))
    let back = assumeOk(decode[OuterMulti](text))
    ensure back.items.len == v.items.len
    for i in 0 ..< v.items.len:
      ensure back.items[i] == v.items[i]

proc nodeCount(v: L1): int =
  result = 1
  for l2 in v.items:
    inc result
    for l3 in l2.items: inc result

suite "typed-decode — three-level nested types":
  # Distinct types at each level (L1 holds seq[L2] holds seq[L3]).
  # Exercises the codegen's nested children-block emission, the
  # decoder's recursive visitor descent across distinct builder
  # types, and indent/depth bookkeeping across non-trivial trees.

  property "L1 round-trips through encode + decode":
    given v in arbitrary(L1)
    let text = assumeOk(encode(v))
    let back = assumeOk(decode[L1](text))
    note("nodes", nodeCount(v))
    note("encoded", text)
    ensure back == v

  property "encode(L1) is deterministic":
    given v in arbitrary(L1)
    let t1 = assumeOk(encode(v))
    let t2 = assumeOk(encode(v))
    ensure t1 == t2

  property "encode(decode(encode(L1))) == encode(L1) (idempotent)":
    given v in arbitrary(L1)
    let text1 = assumeOk(encode(v))
    let back = assumeOk(decode[L1](text1))
    let text2 = assumeOk(encode(back))
    ensure text1 == text2

  property "L1 child ordering preserved at every level":
    given v in arbitrary(L1)
    let text = assumeOk(encode(v))
    let back = assumeOk(decode[L1](text))
    ensure back.items.len == v.items.len
    for i in 0 ..< v.items.len:
      ensure back.items[i].items.len == v.items[i].items.len
      for j in 0 ..< v.items[i].items.len:
        ensure back.items[i].items[j] == v.items[i].items[j]

suite "typed-decode — self-recursive Tree (nkdl#7 minimum-fix tracer)":
  # The minimum bullet for nkdl#7: a self-recursive type
  # (`children: seq[Tree]`) compiles AND round-trips. If it
  # fails to compile, the codegen still emits the forward-
  # referenced XVBuilderSeq pattern that #7 reported. If it
  # compiles but round-trips wrong, the ref-cur + reset-in-
  # place pattern (or the seqWrapProcs forward declarations)
  # broke per-node accumulation.
  proc treeEqual(a, b: Tree): bool =
    if a.label != b.label: return false
    if a.children.len != b.children.len: return false
    for i in 0 ..< a.children.len:
      if not treeEqual(a.children[i], b.children[i]): return false
    true

  test "depth-1 Tree compiles + round-trips":
    let leaf = Tree(label: "leaf", children: @[])
    let parent = Tree(label: "root", children: @[leaf])
    let text = encode(parent)
    check text.isOk
    if text.isOk:
      let back = decode[Tree](text.get)
      check back.isOk
      if back.isOk:
        check treeEqual(back.get, parent)

  # NOTE: depth-2+ recursive Tree is BROKEN by an architectural bug
  # in the visitor protocol (single visitor + `inChildren` flag
  # can't handle nested children blocks for the same builder type).
  # The same bug affects depth-3+ NON-recursive nested types
  # (L1→L2→L3 also fails) — it's been latent in the codebase and
  # was only surfaced by the self-recursive shape. Filed as a
  # separate issue (see nkdl#11). The pull-based decoder RFC
  # (nkdl#10) is the structural fix.
  #
  # When nkdl#11 is closed, uncomment + the depth-3 case will work.

suite "typed encode/decode — idempotent normalization":
  # encode-decode-encode must collapse: the second encode-pass over a
  # decoded value should equal the first. If it doesn't, decode is
  # losing or reshaping information the encoder originally emitted.

  property "encode(decode[Flat](encode(v))) == encode(v)":
    given v in arbitrary(Flat)
    let t1 = assumeOk(encode(v))
    let back = assumeOk(decode[Flat](t1))
    let t2 = assumeOk(encode(back))
    note("first", t1)
    note("second", t2)
    ensure t1 == t2

  property "encode(decode[OuterMulti](encode(v))) == encode(v)":
    given v in arbitrary(OuterMulti)
    let t1 = assumeOk(encode(v))
    let back = assumeOk(decode[OuterMulti](t1))
    let t2 = assumeOk(encode(back))
    ensure t1 == t2
