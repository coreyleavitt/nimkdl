## kdl — public API surface for lib/kdl (KDL v2 parser + type-driven codegen).
##
## See ``README.md`` in this directory for spec coverage, worked examples,
## pragma reference, and the explicit decisions not to implement KSL or KQL.
##
## ## Public surface
##
## `import kdl` gives the curated public API. Tests and advanced users
## that need internals (the lexer's `Token` / `TokenKind`, `lex`, the
## interner's `Entry` shape, the grammar's `InterpState`/`ParseNode`,
## etc.) import the specific submodule directly: ``import kdl/lexer``,
## ``import kdl/grammar``, etc.
##
## ## Modules
##
## - ``spans``   — Position / Span / ParseError / Result[T, E]
## - ``intern``  — SBO string interner (InternedStr + Interner)
## - ``lexer``   — KDL v2 tokenizer (internals only — `lex` is not in
##                 the public surface; users go through `parse`)
## - ``ast``     — KdlDoc / KdlNode / KdlValue object variants
## - ``parser``  — hand-written recursive descent (``parse``)
## - ``encode``  — canonical encoder (``encode``)
## - ``grammar`` — grammar-as-value + reference interpreter
##                 (``referenceInterpret`` + combinators for advanced use)
## - ``codegen`` — pragmas + ``deriveDecode`` macro + ``decode[T]`` +
##                 ``embed[T]``
## - ``path``    — typed schema-path DSL (``path`` macro + ``where`` /
##                 ``first`` / ``only`` templates)

import ./spans
import ./intern
import ./ast
import ./parser
import ./encode
import ./grammar
import ./codegen
import ./path
# Note: ./lexer NOT imported here on purpose — keeps Token / TokenKind /
# Lexer / lex out of the `import kdl` namespace. They're still accessible
# via `import kdl/lexer` for tests and advanced consumers.

# Spans / Result / Position / Span — public diagnostic + error vocabulary.
export spans

# Intern — public for callers that hold InternedStr handles via the AST.
export intern

# Lexer — internal. Token, Lexer, TokenKind, lex() are implementation
# details; users go through parser.parse / codegen.decode. The lexer
# module is still importable directly (``import kdl/lexer``) for tests
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
# via `import kdl/grammar` for tests but aren't curated public API.
export grammar

# Codegen — the headline surface. Pragmas, deriveDecode, decode[T],
# embed[T], kdlDecodeValue overloads (needed by user-defined enum types).
export codegen

# Path DSL — full public surface.
export path

const KdlLibVersion* = "0.1.0"
