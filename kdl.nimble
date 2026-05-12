# Package metadata for kdl — KDL v2 parser + type-driven codegen for amoxtli.
#
# Lives in-tree (lib/kdl/) rather than a sibling repo because the surface is
# bounded, amoxtli is the only consumer, and we need tight coevolution of
# the parser, codegen macros, and diagnostic shape. If we ever extract:
# `git subtree split --prefix=lib/kdl main` produces a clean standalone repo
# with full history.
#
# See lib/kdl/README.md for spec coverage + design philosophy + the explicit
# decisions not to implement KSL or KQL.

version       = "0.1.0"
author        = "Corey Leavitt"
description   = "KDL v2 parser, type-driven codegen, and typed-path DSL. See README.md."
license       = "MIT"
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
  exec cmd & " tests/test_encode.nim"
  exec cmd & " tests/test_grammar.nim"
  exec cmd & " tests/test_conformance.nim"
  exec cmd & " tests/test_codegen.nim"
  exec cmd & " tests/test_embed.nim"
  exec cmd & " tests/test_path.nim"
  exec cmd & " tests/test_variant.nim"
  exec cmd & " tests/test_h2_compiletime.nim"
  exec cmd & " tests/test_public_api.nim"
  exec cmd & " tests/test_readme_examples.nim"
