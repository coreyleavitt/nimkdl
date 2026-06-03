## F.1 acceptance tests for the ref-AST substrate.
##
## The headline behavior the value-object model could NOT provide: a node read
## from the doc is the *live* node, so mutating it is reflected in the doc — no
## detached-copy footgun. This is the consistent-by-construction win that the
## whole ref-AST decision (RFC §2.5) exists to deliver.

import std/[options, unittest]

import ../src/ast
import ../src/parser
import ../src/spans

suite "ref-AST — reads return the live node (mutate-through coherence)":
  test "a node read from the doc, mutated, is reflected in the doc":
    var doc = parse("server port=8080").get
    let n = doc.node("server")            # KdlNode (ref); nil when absent
    check n != nil
    n.setProp(doc, "port", newIntValue(9090))
    # A fresh, independent read must observe the change — proving `n` was the
    # live node, not a detached copy.
    check doc.node("server").prop(doc, "port").get.intVal == 9090

  test "node(missing) returns nil (no Option, no sentinel)":
    var doc = parse("server").get
    check doc.node("absent") == nil
    check doc.node("server") != nil
