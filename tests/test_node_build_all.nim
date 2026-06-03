## test_node_build_all.nim — accumulating (multi-error) self-contained builder.
##
## `parseNodesAll` drives the cursor in cmAccumulating mode and folds events into
## a partial node.KdlDoc, collecting every error rather than stopping at the
## first. Returns `Parsed[KdlDoc]` (value + errors + isComplete). The recovering
## counterpart of `parser.parseAll`.

import std/[unittest, options]
import ../src/node_build

suite "node_build — accumulating parse":
  test "valid input is complete with all nodes":
    let p = parseNodesAll("a 1\nb 2\nc 3\n")
    check p.isComplete
    check p.errors.len == 0
    check p.value.nodes.len == 3
    check p.value.node("a").arg(0) == some(newKdlInt(1))
    check p.value.node("c").arg(0) == some(newKdlInt(3))

  test "malformed input collects errors and is not complete":
    let p = parseNodesAll("a {\n")   # unclosed children block
    check not p.isComplete
    check p.errors.len > 0

  test "recovers past a bad node to parse later ones":
    # A malformed middle node must not prevent earlier/later nodes from landing
    # in the partial doc.
    let p = parseNodesAll("good 1\nbad {\nlater 2\n")
    check p.errors.len > 0
    check not p.value.node("good").isNil
