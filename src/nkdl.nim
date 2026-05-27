## nkdl — fast KDL v2 parser for Nim with compile-time-validated
## typed decode and byte-lossless format preservation.
##
## ## Install
##
## ```
## nimble install nkdl
## ```
##
## ## Quick start
##
## ```nim
## import nkdl
##
## type Service {.kdlNode: "service".} = object
##   name {.kdlArg.}: string
##   port {.kdlProp.}: int
##   enabled {.kdlProp.}: bool = true
##
## deriveDecode(Service)
##
## let r = decode[seq[Service]](readFile("services.kdl"))
## if r.isErr:
##   stderr.writeLine r.getErr.formatError(readFile("services.kdl"))
##   quit 1
## for s in r.get:
##   if s.enabled: echo s.name, " :", s.port
## ```
##
## The same file can be embedded at compile time so a parse error fails
## `nim c` rather than production:
##
## ```nim
## const builtins = embed[seq[Service]]("services.kdl").get
## ```
##
## ## Public API map
##
## | Operation | Entry point | Module |
## |-----------|-------------|--------|
## | Parse text → AST | `parse(src) -> Result[KdlDoc, ParseError]` | `parser` |
## | Multi-error parse | `parseAll(src) -> (doc, errors)` | `parser` |
## | Typed decode | `decode[T](src) -> Result[T, ParseError]` | `codegen` |
## | Typed-direct decode | `parseInto[T](src) -> Result[T, ParseError]` | `typed_parser` |
## | Compile-time embed | `embed[T]("path")` | `codegen` |
## | Encode AST → text | `encode(doc, mode = emPreserve) -> string` | `encode` |
## | Typed-direct encode | `encodeFrom[T](v) -> Result[string, ParseError]` | `codegen` |
## | Typed query DSL | `path(items, [pred].field.chain)` | `path` |
## | Differential oracle | `referenceInterpret(src)` | `grammar` |
##
## ## Pragmas
##
## Type-level: ``{.kdlNode: "name".}``.
##
## Field-level: ``{.kdlArg.}``, ``{.kdlProp.}``, ``{.kdlChild.}``,
## ``{.kdlSkip.}``, ``{.kdlRename: "x".}``, ``{.kdlReserved: "ipv4".}``.
##
## Native Nim 2.x field defaults (``field: type = expr``) double as
## fallback values for absent KDL props.
##
## ## See also
##
## - [BENCHMARK.md](https://github.com/coreyleavitt/nkdl/blob/main/BENCHMARK.md) — cross-impl perf + methodology.
## - [README.md](https://github.com/coreyleavitt/nkdl) — overview, install, vs the alternatives.
## - [kdl.dev](https://kdl.dev/) — the KDL v2 spec.

import ./spans
import ./intern
import ./ast
import ./parser
import ./encode
import ./grammar
import ./codegen
import ./path
import ./typed_parser
# Note: ./lexer NOT imported here on purpose — keeps Token / TokenKind /
# Lexer / lex out of the `import nkdl` namespace. They're still accessible
# via `import nkdl/lexer` for tests and advanced consumers.

# Spans / Result / Position / Span — public diagnostic + error vocabulary.
export spans

# Intern — public for callers that hold InternedStr handles via the AST.
export intern

# Lexer — internal. Token, Lexer, TokenKind, lex() are implementation
# details; users go through parser.parse / codegen.decode. The lexer
# module is still importable directly (``import nkdl/lexer``) for tests
# and for the few advanced users who want raw token streams.
#
# (No re-export here.)

# AST — the canonical data model.
export ast

# Parser — only the public entry point (parse, MaxParserDepth).
export parser

# Encoder — full surface (EncodeMode enum + encode proc).
export encode

# Grammar — public surface includes referenceInterpret (the differential-
# testing oracle) plus the combinators that let users build their own
# Grammar values. InterpState / ParseNode / interpRule stay accessible
# via `import nkdl/grammar` for tests but aren't curated public API.
export grammar

# Codegen — the headline surface. Pragmas, deriveDecode, decode[T],
# embed[T], kdlDecodeValue overloads (needed by user-defined enum types).
export codegen

# Path DSL — full public surface.
export path

# Typed-direct path (issue #1) — parseInto[T] + parseWith[V].
export typed_parser

const KdlLibVersion* = "0.1.0"
