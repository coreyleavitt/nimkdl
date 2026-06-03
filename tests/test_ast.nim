## Tests for ast.nim — value constructors, structural equality, repr,
## variant exhaustiveness, cross-doc node equality.

import std/[strutils, unittest]

import ../src/ast
# encode import removed in the clean-core delete commit (rebuilt in Stage B)
import ../src/intern
import ../src/spans

suite "KdlValue constructors":
  test "string":
    let v = newStringValue("hello")
    check v.kind == kvString
    check v.strVal == "hello"
    check v.typeAnnotation == InvalidInterned

  test "int":
    let v = newIntValue(42)
    check v.kind == kvInt
    check v.intVal == 42

  test "float":
    let v = newFloatValue(3.14)
    check v.kind == kvFloat
    check v.floatVal == 3.14

  test "bool":
    let t = newBoolValue(true)
    let f = newBoolValue(false)
    check t.boolVal
    check not f.boolVal

  test "null":
    let v = newNullValue()
    check v.kind == kvNull

suite "KdlValue equality":
  test "same-kind same-value equal":
    check newIntValue(7) == newIntValue(7)
    check newStringValue("x") == newStringValue("x")
    check newBoolValue(true) == newBoolValue(true)
    check newNullValue() == newNullValue()

  test "different kinds unequal":
    check newIntValue(0) != newStringValue("0")
    check newBoolValue(true) != newIntValue(1)

  test "different values unequal":
    check newIntValue(1) != newIntValue(2)
    check newStringValue("a") != newStringValue("b")

  test "exhaustive case over KdlValueKind":
    # Forcing-function: if a new variant is added, this case must be
    # updated. No else branch — Nim warns on non-exhaustive case.
    for v in [newStringValue("x"), newIntValue(1),
              newBigIntValue(0, 7, false),
              newFloatValue(1.0), newBoolValue(true), newNullValue()]:
      case v.kind
      of kvString: check v.strVal.len >= 0
      of kvInt:    check v.intVal == 1
      of kvBigInt: check v.bigLo == 7
      of kvFloat:  check v.floatVal == 1.0
      of kvBool:   check v.boolVal
      of kvNull:   check v.kind == kvNull

suite "KdlEntry":
  test "argument carries a value":
    let e = newArgument(newIntValue(5))
    check e.kind == keArgument
    check e.argValue.intVal == 5

  test "property carries name + value":
    var doc = newDoc()
    let e = doc.newProperty("enabled", newBoolValue(true))
    check e.kind == keProperty
    check doc.interner.lookup(e.propName) == "enabled"
    check e.propValue.boolVal

  test "entry equality":
    check newArgument(newIntValue(1)) == newArgument(newIntValue(1))
    check newArgument(newIntValue(1)) != newArgument(newIntValue(2))

suite "KdlNode":
  test "newNode interns the name":
    var doc = newDoc()
    let n = doc.newNode("rule")
    check doc.interner.lookup(n.name) == "rule"
    check n.entries.len == 0
    check n.children.len == 0

  test "structural equality is recursive":
    var doc = newDoc()
    var a = doc.newNode("rule")
    a.entries.add(newArgument(newStringValue("first")))
    var b = doc.newNode("rule")
    b.entries.add(newArgument(newStringValue("first")))
    check a == b

  test "different entry order is unequal":
    var doc = newDoc()
    var a = doc.newNode("n")
    a.entries.add(newArgument(newIntValue(1)))
    a.entries.add(newArgument(newIntValue(2)))
    var b = doc.newNode("n")
    b.entries.add(newArgument(newIntValue(2)))
    b.entries.add(newArgument(newIntValue(1)))
    check a != b

suite "KdlNode: cross-doc equality":
  test "nodeEqual resolves names via each doc's interner":
    # Build the same logical node in two different docs (each with its
    # own interner; handle values won't match by uint32 identity).
    var docA = newDoc("a.kdl")
    var docB = newDoc("b.kdl")
    # Pad docA's interner so handles differ from docB's
    discard docA.interner.intern("noise-one")
    discard docA.interner.intern("noise-two")
    var nA = docA.newNode("rule")
    nA.entries.add(newArgument(newStringValue("first")))
    var nB = docB.newNode("rule")
    nB.entries.add(newArgument(newStringValue("first")))
    check uint32(nA.name) != uint32(nB.name)   # different handles
    check nodeEqual(docA, docB, nA, nB)        # but structurally equal

  test "docEqual matches when nodes match":
    var a = newDoc()
    var b = newDoc()
    a.rootNodes.add(a.newNode("x"))
    b.rootNodes.add(b.newNode("x"))
    check docEqual(a, b)

  test "docEqual rejects differing node counts":
    var a = newDoc()
    var b = newDoc()
    a.rootNodes.add(a.newNode("x"))
    check not docEqual(a, b)

suite "KdlDoc: repr":
  test "single node":
    var doc = newDoc()
    var n = doc.newNode("rule")
    n.entries.add(newArgument(newStringValue("compaction")))
    n.entries.add(doc.newProperty("enabled", newBoolValue(true)))
    doc.rootNodes.add(n)
    let s = $doc
    check "rule" in s
    check "\"compaction\"" in s
    check "enabled=#true" in s

  test "nested children render with braces":
    var doc = newDoc()
    var parent = doc.newNode("rule")
    var child = doc.newNode("action")
    child.entries.add(newArgument(newStringValue("inject")))
    parent.childNodes.add(child)
    doc.rootNodes.add(parent)
    let s = $doc
    check "{" in s
    check "action \"inject\"" in s

  test "depth cap suppresses deep recursion":
    # Hand-construct a long left-spine that exceeds the cap, then assert
    # the repr terminates at the cap marker rather than infinitely recursing.
    var doc = newDoc()
    var leaf = doc.newNode("leaf")
    var cursor = leaf
    for _ in 0 ..< KdlReprMaxDepth + 5:
      var parent = doc.newNode("layer")
      parent.childNodes.add(cursor)
      cursor = parent
    doc.rootNodes.add(cursor)
    let s = $doc
    check "<…>" in s

suite "iterators":
  test "arguments yields only positional values":
    var doc = newDoc()
    var n = doc.newNode("n")
    n.entries.add(newArgument(newIntValue(1)))
    n.entries.add(doc.newProperty("k", newIntValue(2)))
    n.entries.add(newArgument(newIntValue(3)))
    var args: seq[int64] = @[]
    for v in n.arguments:
      args.add(v.intVal)
    check args == @[1'i64, 3'i64]

  test "properties yields only named pairs":
    var doc = newDoc()
    var n = doc.newNode("n")
    n.entries.add(newArgument(newIntValue(1)))
    n.entries.add(doc.newProperty("a", newIntValue(10)))
    n.entries.add(doc.newProperty("b", newIntValue(20)))
    var keys: seq[string] = @[]
    for (k, _) in n.properties:
      keys.add(doc.interner.lookup(k))
    check keys == @["a", "b"]

# ---------------------------------------------------------------------------
# Cross-doc value safety (BACKLOG Low correctness items)
# ---------------------------------------------------------------------------

suite "valueEqual: cross-doc correctness":
  test "same string with different interner handles compares equal":
    var docA = newDoc()
    var docB = newDoc()
    # Force different handles for "ipv4" by pre-interning unrelated
    # strings in docA so the handle for "ipv4" in docA is shifted
    # relative to docB.
    discard docA.interner.intern("padding-string-1")
    discard docA.interner.intern("padding-string-2")
    var a = newStringValue("1.2.3.4")
    a.setTypeAnnotation(docA, "ipv4")
    var b = newStringValue("1.2.3.4")
    b.setTypeAnnotation(docB, "ipv4")
    # The handles differ as a result of padding in docA:
    check a.typeAnnotation != b.typeAnnotation
    # But the strings are identical, so valueEqual must say equal.
    check valueEqual(docA, docB, a, b)

  test "different strings happening to share a handle compares NOT equal":
    var docA = newDoc()
    var docB = newDoc()
    var a = newStringValue("x")
    a.setTypeAnnotation(docA, "tagA")   # handle 0 in docA
    var b = newStringValue("x")
    b.setTypeAnnotation(docB, "tagB")   # also handle 0 in docB
    check a.typeAnnotation == b.typeAnnotation  # the bug's precondition
    # `==` would say equal (and would be wrong); valueEqual gets it right.
    check not valueEqual(docA, docB, a, b)

suite "migrateValue: cross-doc transfer":
  test "migrateValue rewrites typeAnnotation against the destination doc":
    var srcDoc = newDoc()
    var dstDoc = newDoc()
    # Pad dstDoc so the handle for "ipv4" there won't collide with srcDoc.
    for s in ["a", "b", "c"]:
      discard dstDoc.interner.intern(s)
    var v = newStringValue("1.2.3.4")
    v.setTypeAnnotation(srcDoc, "ipv4")
    let oldHandle = v.typeAnnotation
    migrateValue(srcDoc, dstDoc, v)
    # After migration: handle is dstDoc-local; resolves to the right string.
    check v.typeAnnotation != oldHandle  # different interner → different handle
    check dstDoc.interner.lookup(v.typeAnnotation) == "ipv4"

  test "migrateValue is a no-op when typeAnnotation is InvalidInterned":
    var srcDoc = newDoc()
    var dstDoc = newDoc()
    var v = newStringValue("plain")
    let oldHandle = v.typeAnnotation
    migrateValue(srcDoc, dstDoc, v)
    check v.typeAnnotation == oldHandle  # unchanged

  # NOTE: the post-migrateValue encode round-trip is deferred until the
  # new KdlEmitter / docEmit lands in Stage A/B of the clean-core rebuild.
  # The migration mechanics themselves are still exercised by the test
  # immediately above; only the encode-side assertion moved.
