## kdl — public API surface for lib/kdl (KDL v2 parser + type-driven codegen).
##
## See ``README.md`` in this directory for spec coverage, worked examples,
## pragma reference, and the explicit decisions not to implement KSL or KQL.
##
## ## Layered modules
##
## - ``spans``   — Position / Span / ParseError / Result[T, E]
## - ``intern``  — SBO string interner
## - ``lexer``   — KDL v2 tokenizer
## - ``ast``     — KdlDoc / KdlNode / KdlValue object variants
## - ``parser``  — hand-written recursive descent (``parse``)
## - ``encode``  — canonical encoder (``encode``)
## - ``grammar`` — grammar-as-value + reference interpreter
##                 (``referenceInterpret``)
## - ``codegen`` — pragmas + ``deriveDecode`` macro + ``decode[T]`` +
##                 ``embed[T]``
## - ``path``    — typed schema-path DSL (``path`` macro + ``where`` /
##                 ``first`` / ``only`` templates)
##
## All public symbols from those modules are re-exported below.
## Downstream callers (amoxtli rule loader, config loader, tests) need
## only ``import kdl``.

import ./spans, ./intern, ./lexer, ./ast, ./parser, ./encode, ./grammar,
       ./codegen, ./path
export spans, intern, lexer, ast, parser, encode, grammar, codegen, path

const KdlLibVersion* = "0.1.0"
