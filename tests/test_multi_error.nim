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
