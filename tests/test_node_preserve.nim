## test_node_preserve.nim — preserve-mode encode (rfc §9.3).
##
## The self-contained pipeline detects "modified" via the per-node dirty flag
## (set by every mutator), not parseHash. So an UNMUTATED parsed doc is wholly
## clean and its retained `sourceText` is the byte-exact original — preserve just
## returns it. A mutated or hand-built doc falls back to canonical (a correct,
## model-preserving result). Partial splice (clean subtrees of a mutated doc) is
## a later refinement.

import std/[unittest, options]
import ../src/node_build
import ../src/node_emit

suite "node_emit — preserve mode":
  test "unmutated parsed doc encodes byte-exact to its source":
    let src = "node a=1 b=0x1A {\n  // keep this comment\n  child \"x\"\n}\n"
    let doc = parseNodes(src).get
    check encode(doc, preserve = true) == src     # comments / hex base / spacing kept

  test "hand-built doc (no source) → canonical":
    let d = newDoc()
    d.add(newNode("n"))
    check encode(d, preserve = true) == "n\n"

  test "mutation marks dirty → canonical fallback, model preserved":
    let doc = parseNodes("a 1\n").get
    doc.node("a").setPropInt("k", 5)              # mutate → dirty
    let outp = encode(doc, preserve = true)
    check parseNodes(outp).get == doc             # canonicalized but equal model

  test "preserve=false is always canonical":
    let doc = parseNodes("node 0x1A\n").get
    check encode(doc, preserve = false) == "node 26\n"   # hex → decimal canonical
