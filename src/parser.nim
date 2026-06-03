## parser — KDL v2 public parse entry points.
##
## `parse()` and `parseAll()` both drive the cursor-event walk in
## `node_build` over the self-contained DOM (`node.KdlDoc` — owned strings,
## no interner) — one grammar, two error-handling modes: single-shot via
## `parse()` (returns first error), accumulating via `parseAll()` (returns
## partial doc + every error encountered).
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
## See `node_build.buildNodeDoc` for the full implementation.
##
## ## Compile-time use
##
## parse() is `noSideEffect` so it runs in NimVM — that's what makes
## `embed[T]` (#529) work without escape hatches.

import ./node
import ./cursor
import ./node_build
import ./spans

const
  MaxParserDepth* = cursor.MaxParserDepth
    ## Maximum recursion depth through `{ children }` blocks. The guard
    ## itself lives in `cursor.nim`.

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
  ## Parse `source` into a self-contained `KdlDoc`. Returns the first
  ## error encountered. The doc owns every byte (no interner).
  ##
  ## `preserveFormat` is accepted for API compatibility but no longer
  ## changes behavior: the self-contained DOM always retains the source
  ## text and uses the per-node dirty flag to drive byte-lossless
  ## `encode(doc, preserve = true)`. There is no longer a parse-time
  ## hashing cost to opt out of.
  parseNodes(source, sourcePath)

proc parseAll*(source: string, sourcePath = "<input>",
               preserveFormat: bool = false):
    tuple[doc: KdlDoc, errors: seq[ParseError]] {.noSideEffect.} =
  ## Multi-error variant of `parse`. Collects every lex- and node-level
  ## error while continuing past failures. The returned `doc` is a
  ## partial document built from the nodes that DID parse.
  ##
  ## Caller contract:
  ##   - If `errors.len == 0`, the doc is a valid, complete parse.
  ##   - If `errors.len > 0`, the doc holds whichever nodes survived.
  let parsed = parseNodesAll(source, sourcePath)
  (doc: parsed.value, errors: parsed.errors)
