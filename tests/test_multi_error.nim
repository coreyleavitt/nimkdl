## Tests for `parseAll` — multi-error reporting variant of `parse`.
##
## `parse(source)` keeps its existing contract: return the first error.
## `parseAll(source)` collects every node-level error plus a partial
## doc, re-syncing at node terminators (newline / `;`) after each
## failure. This is the parser-side property IDE / CI consumers want.

import std/unittest

import ../src/ast
import ../src/parser
import ../src/spans

suite "parseAll — multi-error":
  test "fully-valid source yields zero errors and the same doc as parse":
    let src = "a 1\nb 2\nc 3"
    let viaParse = parse(src)
    let viaAll = parseAll(src)
    check viaParse.isOk
    check viaAll.errors.len == 0
    check viaAll.doc.nodes.len == 3
    if viaParse.isOk:
      check docEqual(viaAll.doc, viaParse.get)

  test "two independent errors are both collected":
    # Two node-level failures separated by a newline. Parser recovers
    # at the newline and tries each in isolation.
    let src = "node(unbalanced\nother malformed=\n"
    let r = parseAll(src)
    check r.errors.len >= 2

  test "later valid nodes survive after an earlier error":
    # First node is malformed; second is fine. Recovery should keep
    # the second.
    let src = "broken=\nok-node"
    let r = parseAll(src)
    check r.errors.len >= 1
    check r.doc.nodes.len >= 1
    let names: seq[string] =
      block:
        var s: seq[string] = @[]
        for n in r.doc.nodes:
          s.add(r.doc.resolveName(n))
        s
    check "ok-node" in names

  test "parse() still returns just the first error":
    let src = "first(broken\nsecond bad="
    let viaParse = parse(src)
    let viaAll = parseAll(src)
    check viaParse.isErr
    check viaAll.errors.len >= 2
    if viaParse.isErr:
      # parse()'s error equals the first one parseAll collected.
      check viaParse.getErr.code == viaAll.errors[0].code

suite "parseAll — entry-level recovery":
  test "two malformed entries within one node both get reported":
    # Both entries violate the Layer-1 (ipv4) content rule. With
    # entry-level recovery, both errors land in the accumulator instead
    # of the first one aborting the node.
    let src = "node (ipv4)\"banana\" (ipv4)\"apple\""
    let r = parseAll(src)
    check r.errors.len >= 2
    check r.errors[0].code == peReservedTypeInvalid
    check r.errors[1].code == peReservedTypeInvalid

  test "good entry between two malformed ones survives":
    # `a=1` is valid; the two `(ipv4)` entries fail Layer 1.
    let src = "n (ipv4)\"banana\" a=1 (ipv4)\"apple\""
    let r = parseAll(src)
    check r.errors.len >= 2
    check r.doc.nodes.len == 1
    check r.doc.nodes[0].hasProp(r.doc, "a")
    check r.doc.nodes[0].prop(r.doc, "a").intVal == 1

  test "entry-level errors don't drop the whole node":
    # Before this slice, a node with any bad entry was dropped entirely.
    # Now the node survives with the entries that DID parse.
    let src = "node (ipv4)\"banana\" ok=#true"
    let r = parseAll(src)
    check r.doc.nodes.len == 1
    check r.doc.nodes[0].hasProp(r.doc, "ok")
    check r.errors.len == 1
    check r.errors[0].code == peReservedTypeInvalid

  test "errors from multiple nodes still accumulate":
    let src = "first (ipv4)\"banana\"\nsecond (ipv4)\"apple\""
    let r = parseAll(src)
    check r.errors.len == 2
    check r.doc.nodes.len == 2

suite "parseAll — children-block recovery":
  test "name-resolution error inside children block doesn't escape":
    # `=` isn't a valid node-name token. parseNode fails inside the
    # children block before consuming any tokens; previously this
    # propagated to the doc level and caused skipToRecovery to chew
    # past the closing `}`, generating phantom "expected node name"
    # errors at every nesting depth.
    let src = "parent {\n  ok-child\n  = bad\n  good-child\n}\n"
    let r = parseAll(src)
    # Exactly one error: the `=` violation. No phantom errors from
    # the closing `}` or beyond.
    check r.errors.len == 1
    # The parent node survives in the partial doc.
    check r.doc.nodes.len == 1
    check r.doc.resolveName(r.doc.nodes[0]) == "parent"

  test "siblings of failed node inside children block still parse":
    let src = "parent {\n  ok-child\n  = bad\n  good-child\n}\n"
    let r = parseAll(src)
    check r.errors.len == 1
    check r.doc.nodes.len == 1
    let parent = r.doc.nodes[0]
    var names: seq[string] = @[]
    for c in parent.children:
      names.add(r.doc.resolveName(c))
    check "good-child" in names

  test "error inside nested children block doesn't compound":
    # Three levels of nesting; error at the innermost level should
    # produce exactly one error, not three (one per level).
    let src = "outer {\n  middle {\n    = bad\n  }\n}\n"
    let r = parseAll(src)
    check r.errors.len == 1
