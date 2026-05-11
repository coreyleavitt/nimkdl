## Tests for intern.nim — SBO classification, dedup, distinct-handle
## hygiene, capacity boundary.

import std/[strutils, unittest]

import ../src/intern

suite "Interner: storage classification":
  test "short string is stored inline":
    var i = initInterner()
    let h = i.intern("rule")
    check i.isInline(h)
    check i.lookup(h) == "rule"

  test "empty string is stored inline":
    var i = initInterner()
    let h = i.intern("")
    check i.isInline(h)
    check i.lookup(h) == ""

  test "string exactly at InlineCapacity is inline":
    var i = initInterner()
    let s = "a".repeat(InlineCapacity)
    let h = i.intern(s)
    check i.isInline(h)
    check i.lookup(h) == s

  test "string one over InlineCapacity is heap":
    var i = initInterner()
    let s = "a".repeat(InlineCapacity + 1)
    let h = i.intern(s)
    check not i.isInline(h)
    check i.lookup(h) == s

  test "long string round-trips":
    var i = initInterner()
    let s = "the quick brown fox jumps over the lazy dog (more than 22 bytes)"
    let h = i.intern(s)
    check not i.isInline(h)
    check i.lookup(h) == s

suite "Interner: dedup":
  test "interning the same short string twice yields the same handle":
    var i = initInterner()
    let a = i.intern("kind")
    let b = i.intern("kind")
    check a == b
    check i.len == 1

  test "interning the same long string twice yields the same handle":
    var i = initInterner()
    let s = "a".repeat(40)
    let a = i.intern(s)
    let b = i.intern(s)
    check a == b
    check i.len == 1

  test "distinct strings get distinct handles":
    var i = initInterner()
    let a = i.intern("rule")
    let b = i.intern("policy")
    check a != b
    check i.len == 2

  test "inline and heap entries with the same content dedup correctly":
    # Same content interned twice — once should be enough; second should
    # find the existing entry regardless of branch.
    var i = initInterner()
    let s = "x".repeat(15)  # inline-eligible
    let a = i.intern(s)
    let b = i.intern(s)
    check a == b
    check i.len == 1
    check i.isInline(a)

suite "Interner: handle hygiene":
  test "InternedStr is distinct from uint32 at type level":
    # Compile-time check: assignment without conversion must not compile.
    # We can't test failure-to-compile cleanly in unittest, so just
    # confirm the conversion is explicit and reversible.
    var i = initInterner()
    let h = i.intern("test")
    let raw: uint32 = uint32(h)
    let back: InternedStr = InternedStr(raw)
    check h == back

  test "InvalidInterned lookup returns empty string":
    let i = initInterner()
    check i.lookup(InvalidInterned) == ""

  test "out-of-range handle lookup returns empty string":
    let i = initInterner()
    let bogus = InternedStr(99u32)
    check i.lookup(bogus) == ""

  test "handle equality is value-based":
    var i = initInterner()
    let a = i.intern("foo")
    let b = i.intern("foo")
    let c = i.intern("bar")
    check a == b
    check a != c

  test "hash on handle is stable":
    var i = initInterner()
    let h = i.intern("stable")
    check hash(h) == hash(h)

suite "Interner: realistic identifier pool":
  # Mirrors what a small KDL file looks like — a handful of identifiers,
  # repeated many times across nodes / attributes / values.
  test "1000 references over 10 distinct identifiers produce 10 entries":
    var i = initInterner()
    let words = ["rule", "policy", "action", "kind", "inject",
                 "deny", "template", "predicate", "enabled", "max"]
    for n in 0 ..< 100:
      for w in words:
        discard i.intern(w)
    check i.len == words.len
    # All ten words are inline (each ≤ 22 bytes)
    for w in words:
      check i.isInline(i.intern(w))
