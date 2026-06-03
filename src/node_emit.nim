## node_emit.nim — canonical encoder for the self-contained DOM (rfc §SB).
##
## Walks a node.KdlDoc and renders canonical KDL text via the value-agnostic
## BufferEmitter primitives (pushArg*/pushProp*/pushNodeBegin string overloads).
## The self-contained counterpart of `doc_emit.emitDoc`. Reuses the existing
## emitter wholesale — only the tree walk + value-kind dispatch are new.
##
## Preserve mode (byte-exact via source spans) needs the per-node sidecar (§5.5)
## and lands in a later slice; this is canonical-only.
##
## NOTE: an explicit empty annotation `("")` (typeAnnotation == some("")) renders
## as no annotation here — the string emitter can't distinguish it from `none`.
## The corpus round-trip flags any fixture that depends on the distinction.

import ./node
import ./value
import ./emitter
export emitter   # BufferEmitter, newBufferEmitter, finish

proc emitNode(n: KdlNode, e: var BufferEmitter) =
  e.pushNodeBeginV(n.name, n.typeAnnotation)
  for entry in n.entries:
    case entry.kind
    of keArgument: e.pushArgV(entry.argValue)
    of keProperty: e.pushPropV(entry.propKey, entry.propValue)
  if n.childNodes.len > 0:
    e.pushChildrenBegin()
    for c in n.childNodes:
      emitNode(c, e)
    e.pushChildrenEnd()
  e.pushNodeEnd()

proc emitDoc*(doc: KdlDoc, e: var BufferEmitter) =
  ## Walk top-level nodes in source order, canonical mode.
  for n in doc.rootNodes:
    emitNode(n, e)

proc encode*(doc: KdlDoc): string =
  ## Canonical-encode a self-contained doc to KDL text. Total — emission is
  ## infallible given an in-memory tree.
  var e = newBufferEmitter()
  emitDoc(doc, e)
  e.finish()

func nodeClean(n: KdlNode): bool =
  ## A node + its whole subtree is unmodified since parse (dirty-flag model).
  if n.dirty: return false
  for c in n.childNodes:
    if not nodeClean(c): return false
  true

func docClean(doc: KdlDoc): bool =
  for n in doc.rootNodes:
    if not nodeClean(n): return false
  true

type EmitMode* = enum
  ## Selects how `encode(doc, mode)` renders.
  emPreserve  ## Byte-lossless for an unmutated doc that still carries its
              ## source text (comments, exact whitespace, original number
              ## bases all retained). A mutated doc falls back to canonical.
  emPretty    ## Canonical, re-derived formatting — ignores preserved
              ## source bytes and emits the model in canonical form.

proc encode*(doc: KdlDoc, preserve: bool): string =
  ## Preserve mode (rfc §9.3): when `preserve` and the doc is unmutated and still
  ## carries its source text, return the original bytes verbatim — byte-exact,
  ## keeping comments, exact whitespace, and original number bases. Otherwise
  ## canonical (a correct, model-preserving fallback).
  ##
  ## NOTE: partial-splice preserve (preserving the clean subtrees of a *mutated*
  ## doc) is a later refinement; today any mutation falls the whole doc back to
  ## canonical.
  if preserve and doc.sourceText.len > 0 and docClean(doc):
    return doc.sourceText
  encode(doc)

proc encode*(doc: KdlDoc, mode: EmitMode): string =
  ## `EmitMode`-overloaded public entry. `emPreserve` (the default in the
  ## umbrella re-export) is byte-lossless for an unmutated doc; `emPretty`
  ## re-derives canonical formatting. The sibling of typed `encode[T]`.
  case mode
  of emPreserve: encode(doc, preserve = true)
  of emPretty:   encode(doc)
