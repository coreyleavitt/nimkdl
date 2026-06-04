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
## kdl:
##   type Service {.kdlNode: "service".} = object
##     name {.kdlArg.}: string
##     port {.kdlProp.}: int
##     enabled {.kdlProp.}: bool = true
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
## | Cat 1 — streaming events | `initStringCursor` + `advance` | `cursor` *(`import nkdl/cursor`)* |
## | Cat 3 — parse text → DOM | `parse(src) -> Result[KdlDoc, ParseError]` | `parser` |
## | Cat 3 — multi-error parse | `parseAll(src) -> (doc, errors)` | `parser` |
## | Cat 3 — encode DOM → text | `encode(doc) -> string` *(canonical; `encode(doc, preserve = true)` is byte-lossless)* | `node_emit` |
## | Cat 2 — typed decode | `decode[T](src) -> Result[T, ParseError]` | `api` |
## | Cat 2 — multi-error decode | `decodeAll[T](src) -> (value, errors)` | `api` |
## | Cat 2 — typed encode | `encode[T](v) -> Result[string, ParseError]` | `api` |
## | Cat 2 — compile-time embed | `embed[T]("path")` | `api` |
## | Typed query DSL | `path(items, [pred].field.chain)` | `path` |
## | Differential oracle | `referenceInterpret(src)` | `grammar` |
##
## ## Pragmas
##
## Complete reference: [docs/derive-reference.md](docs/derive-reference.md).
##
## Type-level: ``{.kdlNode: "name".}``, ``{.kdlRenameAll: kc….}``,
## ``{.kdlIgnoreUnknown.}``, ``{.kdlEncodeOnly.}`` / ``{.kdlDecodeOnly.}``,
## ``{.kdlUntagged.}``.
##
## Field-level: ``{.kdlArg.}``, ``{.kdlVariadic.}``, ``{.kdlProp.}``,
## ``{.kdlChild.}``, ``{.kdlScalar.}``, ``{.kdlRename: "x".}``,
## ``{.kdlAlias("a", "b").}``, ``{.kdlReserved: "ipv4".}``, ``{.kdlSkip.}`` /
## ``{.kdlSkipEncode.}`` / ``{.kdlSkipDecode.}``, ``{.kdlFlatten.}``.
##
## Native Nim 2.x field defaults (``field: type = expr``) double as
## fallback values for absent KDL props. Inherited fields (``object of Base``)
## are included. Custom scalars use the ``kdlEncodeValue`` / ``kdlDecodeValue``
## ``KdlValue`` hook pair (see the reference).
##
## ## See also
##
## - [BENCHMARK.md](https://github.com/coreyleavitt/nkdl/blob/main/BENCHMARK.md) — cross-impl perf + methodology.
## - [README.md](https://github.com/coreyleavitt/nkdl) — overview, install, vs the alternatives.
## - [kdl.dev](https://kdl.dev/) — the KDL v2 spec.

import ./spans
import ./node
import ./value
import ./parser
import ./grammar
import ./pragmas
import ./path
import ./api
import ./node_emit
import ./kdl_block
# Note: ./lexer and ./typed_parser are NOT imported here on purpose.
# Lexer keeps Token / TokenKind / Lexer / lex out of the `import nkdl`
# namespace (still reachable via `import nkdl/lexer` for tests/advanced
# consumers). typed_parser is the visitor protocol that powers decode[T]
# under the hood — public consumers route through decode[T], so the
# visitor primitives (parseInto / parseWith / parseDocumentWith / etc.)
# stay implementation-detail.

# Spans / Result / Position / Span — public diagnostic + error vocabulary.
export spans

# Lexer — internal. Token, Lexer, TokenKind, lex() are implementation
# details; users go through parser.parse / codegen.decode. The lexer
# module is still importable directly (``import nkdl/lexer``) for tests
# and for the few advanced users who want raw token streams.
#
# (No re-export here.)

# Self-contained DOM — the canonical data model (owned strings, no interner).
export node, value

# Parser — only the public entry point (parse, MaxParserDepth).
export parser

# Typed-direct surface — decode[T] / encode[T] / decodeAll[T] /
# embed[T] entry points. Routes through derive-emitted kdlEncode /
# kdlDecode for the user's `{.kdlNode.}`-tagged types.
export api

# Cat 3 OUT — DOM → text. `encode(doc)` is canonical; `encode(doc, preserve)`
# and `encode(doc, mode)` (EmitMode) are the byte-lossless-capable forms.
export node_emit

# kdl: block macro orchestrator — wraps a region of type
# definitions and emits deriveEncode + deriveDecode for each
# `{.kdlNode.}`-tagged type. Non-tagged types pass through.
export kdl_block

# Grammar — public surface includes referenceInterpret (the differential-
# testing oracle) plus the combinators that let users build their own
# Grammar values. InterpState / ParseNode / interpRule stay accessible
# via `import nkdl/grammar` for tests but aren't curated public API.
export grammar

# Pragmas — kdlNode / kdlArg / kdlProp / kdlChild / kdlSkip / kdlRename /
# kdlReserved marker templates. The new Stage C/D codegen will consume
# these via `getCustomPragmaVal`.
export pragmas

# Path DSL — full public surface.
export path

const KdlLibVersion* = "0.1.0"
