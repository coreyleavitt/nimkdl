## kdl — public API surface for the KDL v2 parser + type-driven codegen.
##
## Layered modules (added as sub-issues land — see README.md):
##   spans.nim       — Position, Span, ParseError, Result
##   intern.nim      — SBO string interner
##   lexer.nim       — source → seq[Token]
##   ast.nim         — KdlDoc, KdlNode, KdlValue
##   parser.nim      — tokens → KdlDoc (recursive descent, {.noSideEffect.})
##   encode.nim      — KdlDoc → canonical text
##   grammar.nim     — kdlGrammar: macro + reference interpreter
##   codegen.nim     — parse[T] + embed[T] macros (type reflection)
##   path.nim        — typed schema-path DSL macro + helpers
##
## Downstream callers (amoxtli rule loader, config loader, tests) import only
## this module.

import ./spans, ./intern, ./lexer, ./ast, ./parser, ./encode, ./grammar
export spans, intern, lexer, ast, parser, encode, grammar

const KdlLibVersion* = "0.0.1"
