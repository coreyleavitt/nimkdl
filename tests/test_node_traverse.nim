## test_node_traverse.nim — Cat-3 DOM traversal (rfc §9.4).
##
## `descendants` is iterative pre-order DFS (recursive inline iterators are
## illegal in Nim). `find` returns the first descendant by name (nil if none).
## `findPath` returns the root→match chain (for removal-of-found, since there are
## no parent pointers). where/first/only + byName/hasProp/propEq are the
## compile-time-typed superset of KQL's matchers for in-process use.

import std/[unittest, options]
import ../src/node

proc sample(): KdlNode =
  ## root { a { target 1 }  b { c { target 2 } }  a 9 }
  result = newNode("root")
  let a1 = newNode("a"); a1.addChild(newNode("target")); a1.child("target").addArg(newKdlInt(1))
  let b = newNode("b"); let c = newNode("c")
  c.addChild(newNode("target")); c.child("target").addArg(newKdlInt(2))
  b.addChild(c)
  let a2 = newNode("a"); a2.addArg(newKdlInt(9))
  result.addChild(a1); result.addChild(b); result.addChild(a2)

suite "node — traversal":
  test "descendants yields the whole subtree pre-order":
    var names: seq[string]
    for d in sample().descendants: names.add d.name
    check names == @["a", "target", "b", "c", "target", "a"]

  test "find returns the first descendant by name (depth-first)":
    let f = sample().find("target")
    check not f.isNil
    check f.arg(0) == some(newKdlInt(1))     # the shallower-left one
    check sample().find("missing").isNil

  test "findPath returns the root→match chain":
    let path = sample().findPath("c")
    check path.len == 3
    check path[0].name == "root"
    check path[1].name == "b"
    check path[2].name == "c"
    check sample().findPath("missing").len == 0

suite "node — predicate selection (where/first/only)":
  test "where + byName over children":
    let r = sample()
    check r.children.where(byName("a")).len == 2

  test "first + only":
    let r = sample()
    check r.children.first(byName("b")).name == "b"
    check r.children.only(byName("b")).name == "b"   # exactly one
    check r.children.only(byName("a")).isNil          # two → nil
    check r.children.only(byName("zzz")).isNil        # zero → nil

  test "propEq / hasProp predicates":
    var x = newNode("x"); x.setPropInt("port", 80)
    var y = newNode("x"); y.setPropInt("port", 81)
    let nodes = @[x, y]
    check nodes.where(propEq("port", newKdlInt(80))).len == 1
    check nodes.where(hasProp("port")).len == 2
    check nodes.where(hasProp("nope")).len == 0
