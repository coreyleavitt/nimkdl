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

proc emitEntry[E: KdlEmitter](entry: KdlEntry, doc: KdlDoc, e: var E) =
  ## Forward an entry's value through the emitter via the KdlValue
  ## dispatcher (resolves the value's typeAnnotation against the
  ## doc's interner). Args go through pushArg; props prepend the
  ## interned key.
  case entry.kind
  of keArgument:
    e.pushArg(entry.argValue, doc.interner)
  of keProperty:
    e.pushProp(doc.interner.lookup(entry.propName), entry.propValue,
               doc.interner)

proc emitNode[E: KdlEmitter](n: KdlNode, doc: KdlDoc, e: var E) =
  let anno =
    if n.typeAnnotation == InvalidInterned: ""
    else: doc.interner.lookup(n.typeAnnotation)
  e.pushNodeBegin(doc.interner.lookup(n.name), anno)
  for entry in n.entries:
    emitEntry(entry, doc, e)
  if n.children.len > 0:
    e.pushChildrenBegin()
    for child in n.children:
      emitNode(child, doc, e)
    e.pushChildrenEnd()
  e.pushNodeEnd()

proc emitDoc*[E: KdlEmitter](doc: KdlDoc, e: var E) =
  ## Emit `doc` through `e` in canonical mode. Walks top-level nodes
  ## in source order; each node pushes Begin → entries → children →
  ## End. Stage B5 will add a preserve-mode overload that consults
  ## `doc.sourceText` + `n.parseHash` for byte-exact round-trip.
  for n in doc.nodes:
    emitNode(n, doc, e)
