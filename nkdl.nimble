# Package metadata for nkdl — KDL v2 parser + type-driven codegen.
#
# See README.md for spec coverage + design philosophy + the explicit
# decisions not to implement KSL or KQL.

version       = "0.1.0"
author        = "Corey Leavitt"
description   = "KDL v2 parser, type-driven codegen, and typed-path DSL. See README.md."
license       = "Apache-2.0"
srcDir        = "src"

requires "nim >= 2.0.0"

task test, "Run unit tests":
  ## Same recursion-cap bump as lib/cel: hand-written recursive descent
  ## parser uses several frames per source-level nesting step, and the
  ## deep-nesting conformance cases would trip Nim's debug-build call-depth
  ## limit before our MaxParserDepth bound trips. Release builds don't
  ## have this limit at all.
  const cmd = "nim c -r --hints:off -d:nimCallDepthLimit=20000"
  exec cmd & " tests/test_smoke.nim"
  exec cmd & " tests/test_spans.nim"
  exec cmd & " tests/test_intern.nim"
  exec cmd & " tests/test_lexer.nim"
  exec cmd & " tests/test_ast.nim"
  exec cmd & " tests/test_parser.nim"
  exec cmd & " tests/test_reserved_keywords.nim"
  exec cmd & " tests/test_reserved_types.nim"
  exec cmd & " tests/test_kdl_reserved_pragma.nim"
  exec cmd & " tests/test_accessors.nim"
  exec cmd & " tests/test_derive_encode.nim"
  exec cmd & " tests/test_encode_typed.nim"
  exec cmd & " tests/test_builder.nim"
  exec cmd & " tests/test_multi_error.nim"
  exec cmd & " tests/test_preserve.nim"
  exec cmd & " tests/test_preserve_format_optin.nim"
  exec cmd & " tests/test_typed_parser.nim"
  exec cmd & " tests/test_typed_parser_vm.nim"
  exec cmd & " tests/test_doc_builder.nim"
  exec cmd & " tests/test_doc_builder_conformance.nim"
  exec cmd & " tests/test_option_and_node_tags.nim"
  exec cmd & " tests/test_encode.nim"
  exec cmd & " tests/test_grammar.nim"
  exec cmd & " tests/test_conformance.nim"
  exec cmd & " tests/test_codegen.nim"
  exec cmd & " tests/test_decode_all.nim"
  exec cmd & " tests/test_embed.nim"
  exec cmd & " tests/test_path.nim"
  exec cmd & " tests/test_variant.nim"
  exec cmd & " tests/test_h2_compiletime.nim"
  exec cmd & " tests/test_public_api.nim"
  exec cmd & " tests/test_readme_examples.nim"
  exec cmd & " tests/test_cursor.nim"
  # Property tests via proptest. Opt-in via NKDL_PROPTEST=1 so the
  # default `nimble test` (incl. CI) stays self-contained — proptest
  # is currently a local-path dep resolved through milpa and not yet
  # available on any registry. Flip the gate to file-existence (or
  # better, drop the gate entirely) once proptest publishes.
  #
  # Local dev: `milpa fetch` then `NKDL_PROPTEST=1 nimble test`.
  if existsEnv("NKDL_PROPTEST"):
    exec cmd & " tests/test_preserve_properties.nim"
    exec cmd & " tests/test_typed_decode_properties.nim"
    exec cmd & " tests/test_cursor_properties.nim"
  else:
    echo "[skip] tests/test_preserve_properties.nim — set NKDL_PROPTEST=1 + run `milpa fetch` to enable"
    echo "[skip] tests/test_typed_decode_properties.nim — set NKDL_PROPTEST=1 + run `milpa fetch` to enable"
    echo "[skip] tests/test_cursor_properties.nim — set NKDL_PROPTEST=1 + run `milpa fetch` to enable"

task perfGuard, "Verify no KdlNode deep-copy regression":
  ## Compile-time check that the parser hot paths don't introduce
  ## KdlNode `=copy` calls. Adding any `for i, c in seq[KdlNode]`-style
  ## iteration or non-sink `Result.get` on a tree-bearing type will
  ## fail this with a clear diagnostic pointing at the offending line.
  ## A 14× perf regression was caught + fixed this way (660fe7a).
  ## Runs only over src/ + the perf-critical bench — test files
  ## may legitimately copy small KdlNodes (intentional, not perf-path).
  echo "perfGuard: -d:probeKdlNodeCopy build of src/ + perf bench"
  exec "nim c -c --hints:off -d:probeKdlNodeCopy -d:nimCallDepthLimit=20000 benchmarks/perf_deep_chain.nim"
  echo "perfGuard: OK (no KdlNode copies in parse hot path)"
