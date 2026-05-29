## spec_literals — single source of truth for KDL v2 wire-format
## literal strings.
##
## Any module producing or recognizing these byte sequences must
## reference the consts here, not embed the literals inline. When the
## spec evolves (a v3 renaming, say `#nan` → `#NaN`), one change here
## propagates everywhere.
##
## Lives in its own module because three callers participate at
## different layers (lexer, ast, emitter) and importing one of them
## into the others would create awkward dependency edges. This module
## imports nothing — bottom of the dependency graph.

type
  KdlKeyword* = enum
    ## Mirrors lexer.KeywordKind in order so KdlKeywordLiterals can be
    ## consulted by both sides without coupling.
    klTrue, klFalse, klNull, klInf, klNegInf, klNan

const
  KdlKeywordLiterals*: array[KdlKeyword, string] = [
    klTrue:   "#true",
    klFalse:  "#false",
    klNull:   "#null",
    klInf:    "#inf",
    klNegInf: "#-inf",
    klNan:    "#nan",
  ] ## Canonical wire bytes for each KDL v2 keyword. Lexer recognizes
    ## these; emitter produces them. Single source of truth.

const
  KdlSlashdash* = "/-"
    ## KDL v2 slashdash marker — comments out the following node /
    ## entry / children block.
