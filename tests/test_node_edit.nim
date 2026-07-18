## test_node_edit.nim — targeted single-node property preserve-splice.
##
## `setNodePropPreserving(src, nodeName, propName, value)` sets/inserts/replaces
## ONE property on the first top-level node named `nodeName`, returning new
## source bytes byte-identical everywhere except the changed entry. This is the
## bounded single-node subset of the general #31 preserve engine — the one
## lossless edit consumers (amoxtli's `workspace.trust` toggle) need.

import std/[unittest, options]
import ../src/node_build   # re-exports node + value + spans (parseNodes, node, prop)
import ../src/node_edit    # setNodePropPreserving

proc spliced(src, node, prop: string, v: KdlValue): string =
  let r = setNodePropPreserving(src, node, prop, v)
  check r.isOk
  r.get

suite "setNodePropPreserving — node absent (append)":

  test "append a new node line; existing trailing newline preserved":
    let src = "// header\nfoo 1\n"
    check spliced(src, "runtime", "trust-third-party", newKdlBool(true)) ==
      "// header\nfoo 1\nruntime trust-third-party=#true\n"

  test "src without trailing newline → newline boundary inserted first":
    check spliced("foo 1", "runtime", "trust-third-party", newKdlBool(true)) ==
      "foo 1\nruntime trust-third-party=#true\n"

  test "src ending in a comment (no newline) → appended node not swallowed":
    check spliced("foo 1\n// trailing", "runtime", "trust-third-party",
                  newKdlBool(true)) ==
      "foo 1\n// trailing\nruntime trust-third-party=#true\n"

  test "empty src → single appended node":
    check spliced("", "runtime", "trust-third-party", newKdlBool(false)) ==
      "runtime trust-third-party=#false\n"

suite "setNodePropPreserving — node present, prop present (replace value)":

  test "replace value only; siblings on the line byte-exact":
    check spliced("runtime trust-third-party=#true network=\"pasta\"\n",
                  "runtime", "trust-third-party", newKdlBool(false)) ==
      "runtime trust-third-party=#false network=\"pasta\"\n"

  test "replace inside a node with a children block; all comments preserved":
    let src = "// top\nruntime trust-third-party=#true {\n" &
              "  // inner\n  devices \"x\"\n}\n// bottom\n"
    check spliced(src, "runtime", "trust-third-party", newKdlBool(false)) ==
      "// top\nruntime trust-third-party=#false {\n" &
      "  // inner\n  devices \"x\"\n}\n// bottom\n"

  test "type-annotated value is replaced wholesale":
    check spliced("runtime level=(u8)3\n", "runtime", "level",
                  newKdlInt(7)) == "runtime level=7\n"

  test "duplicate key on the head → last occurrence wins (matches decode)":
    check spliced("runtime trust-third-party=#true trust-third-party=#true\n",
                  "runtime", "trust-third-party", newKdlBool(false)) ==
      "runtime trust-third-party=#true trust-third-party=#false\n"

suite "setNodePropPreserving — node present, prop absent (insert)":

  test "no children block → insert after the last head entry":
    check spliced("runtime network=\"pasta\"\n", "runtime",
                  "trust-third-party", newKdlBool(true)) ==
      "runtime network=\"pasta\" trust-third-party=#true\n"

  test "children block present → insert before the '{', never after '}'":
    let src = "runtime network=\"pasta\" {\n  devices \"x\"\n}\n"
    check spliced(src, "runtime", "trust-third-party", newKdlBool(true)) ==
      "runtime network=\"pasta\" trust-third-party=#true {\n  devices \"x\"\n}\n"

  test "no entries, no block → insert after the node name":
    check spliced("runtime\n", "runtime", "trust-third-party",
                  newKdlBool(true)) == "runtime trust-third-party=#true\n"

  test "no entries, block present → insert after name, before block":
    let src = "runtime {\n  devices \"x\"\n}\n"
    check spliced(src, "runtime", "trust-third-party", newKdlBool(true)) ==
      "runtime trust-third-party=#true {\n  devices \"x\"\n}\n"

suite "setNodePropPreserving — comment safety & robustness":

  test "a comment mentioning the key (node absent) is untouched":
    let src = "// set runtime trust-third-party=#true to opt in\nfoo 1\n"
    check spliced(src, "runtime", "trust-third-party", newKdlBool(true)) ==
      "// set runtime trust-third-party=#true to opt in\n" &
      "foo 1\nruntime trust-third-party=#true\n"

  test "a comment inside the node block mentioning the key is not matched":
    let src = "runtime trust-third-party=#true {\n" &
              "  // trust-third-party=#false is just docs\n  devices \"x\"\n}\n"
    check spliced(src, "runtime", "trust-third-party", newKdlBool(false)) ==
      "runtime trust-third-party=#false {\n" &
      "  // trust-third-party=#false is just docs\n  devices \"x\"\n}\n"

  test "duplicate top-level node → operates on the first (documented)":
    check spliced("runtime trust-third-party=#true\nruntime network=\"pasta\"\n",
                  "runtime", "trust-third-party", newKdlBool(false)) ==
      "runtime trust-third-party=#false\nruntime network=\"pasta\"\n"

  test "malformed src → err, not a corrupted string":
    let r = setNodePropPreserving("runtime {{{", "runtime", "x",
                                  newKdlBool(true))
    check r.isErr

  test "result re-parses and the prop decodes to the new value":
    let got = spliced("runtime trust-third-party=#true\n", "runtime",
                      "trust-third-party", newKdlBool(false))
    let d = parseNodes(got)
    check d.isOk
    check d.get.node("runtime").prop("trust-third-party").get.boolVal == false
