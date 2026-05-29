## doc_emit — Cat 3 OUT consumer.
##
## Walk a KdlDoc and push events into a KdlEmitter. The inverse of
## buildDoc (which walks cursor events and constructs a KdlDoc).
## Together they're the round-trip pair for the Cat 3 surface.
##
## ## Stage B buildout
##
## - B1: tracer — single bare node `"foo\n"`
## - B2-B6: accretion per docs/branch-rebuild-plan.md
##
## docEmit is generic over `E: KdlEmitter` so any emitter impl
## (BufferEmitter today; TracingEmitter / SizeEmitter as
## property-test fixtures arrive in Stage F) can be the destination.
##
## ## Design note: not symmetric with buildDoc's hosting
##
## buildDoc currently lives in cursor.nim because Phase 2 needed
## direct access to cursor internals to populate parseHash sidecars
## efficiently. docEmit needs nothing from emitter internals — only
## the public push protocol — so it lives in its own module. The
## buildDoc-out-of-cursor refactor is a separate audit item.

import ./ast
import ./emitter
import ./intern
import ./spans

proc emitEntry(entry: KdlEntry, doc: KdlDoc, e: var BufferEmitter) =
  ## Forward an entry's value through the emitter via the KdlValue
  ## dispatcher (resolves the value's typeAnnotation against the
  ## doc's interner). Args go through pushArg; props prepend the
  ## interned key. Concrete BufferEmitter because the KdlValue
  ## dispatcher overloads live on it, not on the KdlEmitter concept.
  case entry.kind
  of keArgument:
    e.pushArg(entry.argValue, doc.interner)
  of keProperty:
    e.pushProp(doc.interner.lookup(entry.propName), entry.propValue,
               doc.interner)

proc emitNode(n: KdlNode, doc: KdlDoc, e: var BufferEmitter) =
  ## AST-aware emit. Uses the InternedStr-handle pushNodeBegin
  ## overload so explicit empty-string annotations `("")` are
  ## preserved byte-exactly (the string-based pushNodeBegin can't
  ## distinguish that from "no annotation").
  e.pushNodeBegin(doc.interner.lookup(n.name), doc.interner, n.typeAnnotation)
  for entry in n.entries:
    emitEntry(entry, doc, e)
  if n.children.len > 0:
    e.pushChildrenBegin()
    for child in n.children:
      emitNode(child, doc, e)
    e.pushChildrenEnd()
  e.pushNodeEnd()

proc emitDoc*(doc: KdlDoc, e: var BufferEmitter) =
  ## Emit `doc` through `e` in canonical mode. Walks top-level nodes
  ## in source order; each node pushes Begin → entries → children →
  ## End. The preserve-mode counterpart is `emitDocPreserve` below.
  ##
  ## Concrete BufferEmitter signature because the AST-aware push
  ## overloads (KdlValue dispatcher, InternedStr annotation) live on
  ## BufferEmitter rather than the KdlEmitter concept. A generic-on-
  ## KdlEmitter docEmit would require adding all the AST-aware paths
  ## to the concept; that pollutes impls that don't need them. The
  ## generic / streaming-event consumer pattern lives one level up
  ## (Cat 1 OUT, hand-written by users).
  for n in doc.nodes:
    emitNode(n, doc, e)

# ---------------------------------------------------------------------------
# Preserve mode (BufferEmitter-specific — needs pushPreservedBytes)
# ---------------------------------------------------------------------------

func subtreeIsClean(n: KdlNode): bool =
  ## A node and all its descendants are "clean" iff no mutation has
  ## touched them since parse time. Cheap detection — checks the
  ## lazy `mutState` sidecar which the builder API populates on first
  ## modification. Unmodified parsed nodes pay zero cost (mutState
  ## stays nil for the lifetime of the parsed tree).
  ##
  ## When the whole subtree is clean AND `n.span` is valid, the
  ## original source bytes for that subtree are still semantically
  ## current; the preserve-mode emitter splices them verbatim,
  ## bypassing canonical re-rendering (which would lose original
  ## number bases, comments anchored to entries, exact whitespace).
  if n.mutState != nil and n.mutState.dirty:
    return false
  for c in n.children:
    if not subtreeIsClean(c):
      return false
  true

func validSpanInto(span: Span, source: string): bool {.inline.} =
  source.len > 0 and span.offset >= 0 and
  span.endOffset <= source.len and span.offset < span.endOffset

proc emitDocPreserve*(doc: KdlDoc, e: var BufferEmitter) =
  ## Emit `doc` in preserve mode through a BufferEmitter. For every
  ## clean subtree whose `span` points into the original
  ## `doc.sourceText`, splices source bytes verbatim — preserving
  ## comments, exact whitespace, original number bases, and any
  ## other format detail the AST doesn't carry. For dirty subtrees,
  ## falls back to canonical emission.
  ##
  ## Walks the source forward, advancing a `cursor` byte offset
  ## past each node's span. Inter-node bytes (whitespace, comments,
  ## terminators like `;` or `\n`) get spliced as the trivia between
  ## one node's end and the next node's start. Trailing source bytes
  ## past the last node go through too — that catches the
  ## final `\n` that isn't part of any node's span.
  ##
  ## Requires `parse(src, preserveFormat = true)` upstream so spans
  ## are populated; with preserveFormat=false the spans are point
  ## spans and the preserve path degrades to canonical. The current
  ## impl detects span validity per-node and falls back cleanly.
  if doc.sourceText.len == 0:
    # No source to splice from — degrade to canonical.
    emitDoc(doc, e)
    return
  var cursor = 0
  template ensureNodeSeparator() =
    # Top-level node-separation invariant: between any two emitted
    # top-level nodes there must be a node terminator (`\n` or `;`).
    # A preserved source ending without a trailing newline followed
    # by an appended dirty node would otherwise concatenate them and
    # produce bytes the parser refuses ("whitespace required before
    # entry"). Caught by P6 — mutation round-trip property.
    let last = e.lastByteOrZero
    if last != '\0' and last != '\n' and last != ';':
      e.pushPreservedBytes("\n")
  for n in doc.nodes:
    if subtreeIsClean(n) and validSpanInto(n.span, doc.sourceText):
      # Inter-node trivia: whitespace / comments / terminator between
      # the previous splice end and this node's start.
      if cursor < n.span.offset:
        e.pushPreservedBytes(doc.sourceText.toOpenArray(
          cursor, n.span.offset - 1))
      else:
        # No source trivia available between previous emission and this
        # node (the previous emission already consumed up through this
        # node's offset). The separator invariant still applies — e.g.
        # an appended dirty node followed by another node would
        # otherwise butt up against it.
        ensureNodeSeparator()
      e.pushPreservedBytes(doc.sourceText.toOpenArray(
        n.span.offset, n.span.endOffset - 1))
      cursor = n.span.endOffset
    else:
      # Dirty subtree (or built programmatically) — emit canonical.
      # We still emit any preceding source trivia so siblings keep
      # their formatting; the dirty node disrupts only itself.
      if cursor < doc.sourceText.len:
        # Find the end of preceding trivia heuristically: if span is
        # valid, splice up to span.offset; else emit just a newline.
        if validSpanInto(n.span, doc.sourceText) and cursor < n.span.offset:
          e.pushPreservedBytes(doc.sourceText.toOpenArray(
            cursor, n.span.offset - 1))
          cursor = n.span.offset
      # Always enforce the separator invariant before emitting a
      # dirty top-level node. Covers the append-after-no-newline
      # case (caught by P6) and the insert-between-spans case where
      # the preceding span ended without a terminator.
      ensureNodeSeparator()
      emitNode(n, doc, e)
      # If we know where the dirty node ended in source, skip past it
      # so we don't double-emit. Otherwise leave cursor as-is.
      if validSpanInto(n.span, doc.sourceText):
        cursor = n.span.endOffset
  # Trailing source bytes past the last node: the closing `\n` lives
  # here for a typical KDL file.
  if cursor < doc.sourceText.len:
    e.pushPreservedBytes(doc.sourceText.toOpenArray(
      cursor, doc.sourceText.len - 1))
