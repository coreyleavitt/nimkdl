## test_node_clone.nim — clone + positional child mutation (rfc §9.2).
##
## clone is a deep copy — trivial under owned strings (entries are value objects;
## children recurse). The clone is fully independent of the original.

import std/[unittest, options]
import ../src/node

suite "node — clone (deep copy)":
  test "clone is independent of the original":
    var orig = newNode("svc")
    orig.setPropInt("port", 80)
    orig.addChild(newNode("child"))
    let cp = clone(orig)
    check cp == orig                    # structurally equal
    # mutating the clone must not touch the original
    cp.setName("changed")
    cp.setPropInt("port", 99)
    cp.addChild(newNode("extra"))
    check orig.name == "svc"
    check orig.propInt("port") == some(80'i64)
    check orig.children.len == 1
    check cp.children.len == 2

  test "deep clone of nested children":
    var root = newNode("r")
    let a = newNode("a"); a.addChild(newNode("deep"))
    root.addChild(a)
    let cp = clone(root)
    cp.child("a").child("deep").setName("mutated")
    check root.child("a").child("deep").name == "deep"

suite "node — insertChild / replaceChild":
  test "insertChild places at index (clamped)":
    var n = newNode("n")
    n.addChild(newNode("b"))
    n.insertChild(0, newNode("a"))      # front
    n.insertChild(99, newNode("c"))     # clamp to end
    check n.children.len == 3
    check n.children[0].name == "a"
    check n.children[1].name == "b"
    check n.children[2].name == "c"

  test "replaceChild by index returns success":
    var n = newNode("n")
    n.addChild(newNode("old"))
    check n.replaceChild(0, newNode("new"))
    check n.children[0].name == "new"
    check not n.replaceChild(5, newNode("oob"))   # out of range
