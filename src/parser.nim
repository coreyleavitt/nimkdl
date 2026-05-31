## parser — KDL v2 public parse entry points.
##
## `parse()` and `parseAll()` both drive `parseDocumentWith[DocBuilder]`
## from `typed_parser` + `doc_builder` — one grammar, two error-handling
## modes: single-shot via `parse()` (returns first error), accumulating
## via `parseAll()` (returns partial doc + every error encountered).
##
## ## Grammar (informal)
##
##   document   := node*
##   node       := slashdash? typeAnno? IDENT entry* children? terminator
##   entry      := slashdash? (property | argument)
##   property   := IDENT '=' value
##   argument   := value
##   value      := typeAnno? (STRING | RAW_STRING | NUMBER | KEYWORD | IDENT-as-bareword?)
##   typeAnno   := '(' IDENT ')'
##   children   := slashdash? '{' node* '}'
##   terminator := NEWLINE | ';' | EOF
##
## See `typed_parser.parseDocumentWith` for the full implementation +
## `doc_builder.DocBuilder` for the KdlDoc-building visitor.
##
## ## Compile-time use
##
## parse() is `noSideEffect` so it runs in NimVM — that's what makes
## `embed[T]` (#529) work without escape hatches.

import ./ast
import ./cursor
import ./doc_build
import ./lexer
import ./spans

const
  MaxParserDepth* = cursor.MaxParserDepth
    ## Maximum recursion depth through `{ children }` blocks. The guard
    ## itself lives in `cursor.nim` (`buildDoc` enforces it).

func estimateDocNodes*(tokenCount: int): int {.inline.} =
  ## Heuristic for pre-allocating doc-level seqs. Each top-level node
  ## consumes ~5+ tokens; estimating at `tokens/5` slightly over-shoots
  ## the common case so the seq doesn't re-grow during parsing.
  ## Floors at 4 — tiny docs don't benefit from a smaller initial
  ## capacity than the first power-of-two seq growth would land on.
  max(4, tokenCount div 5)

proc parse*(source: string, sourcePath = "<input>",
            preserveFormat: bool = false):
    Result[KdlDoc, ParseError] {.noSideEffect.} =
  ## Parse `source` into a `KdlDoc`. Returns the first error encountered.
  ## The doc owns its interner.
  ##
  ## `preserveFormat` (default false) — when true, DocBuilder populates
  ## per-node and per-entry parseHash fields needed by
  ## `encode(doc, emPreserve)` for byte-lossless round-trip. Opt-in
  ## because hashing is ~18% of parse cost.
  var stream = lex(source)
  var c = initStringCursor(addr stream, source)
  buildDoc(c, sourcePath, preserveFormat)

proc parseAll*(source: string, sourcePath = "<input>",
               preserveFormat: bool = false):
    tuple[doc: KdlDoc, errors: seq[ParseError]] {.noSideEffect.} =
  ## Multi-error variant of `parse`. Drives parseDocumentWith[DocBuilder]
  ## in accumulating mode (errorBuf threaded through). Collects every
  ## lex- and node-level error while continuing past failures. The
  ## returned `doc` is a partial document built from the nodes that
  ## DID parse.
  ##
  ## Caller contract:
  ##   - If `errors.len == 0`, the doc is a valid, complete parse.
  ##   - If `errors.len > 0`, the doc holds whichever nodes survived.
  var stream = lex(source)
  var c = initStringCursor(addr stream, source, mode = cmAccumulating)
  buildDocAll(c, sourcePath, preserveFormat)
