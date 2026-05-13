## ast — KDL document tree.
##
## Mirrors KDL v2's data model:
##
##   Document  = sequence of nodes
##   Node      = name + optional type annotation + entries + children
##   Entry     = positional argument OR property (name=value)
##   Value     = string / int / float / bool / null, with optional type annotation
##
## ## Design notes
##
## **Identifiers are interned** (`InternedStr` from `intern.nim`). Node names,
## property keys, and type annotations all share the document's interner so
## that `rule`, `action`, `kind` etc. — which repeat heavily — pay a single
## allocation each. String *values* are not interned because they vary too
## much; interning a 1KB rule description is pointless overhead.
##
## **Numbers store as int64 or float64.** KDL v2 numbers are conceptually
## unbounded, but no real amoxtli config has integers outside int64 range
## (timestamps, byte counts, depth limits all fit). Numbers larger than int64
## are filed as v0.2 work (`kvBigInt` variant carrying raw source text).
##
## **Spans are present on every node + entry** for diagnostics.
##
## **No cycles.** KdlNode.children is a value-typed seq, so the tree is a
## DAG by construction. `$` still caps depth defensively to bound output
## for malformed-but-typechecked AST (e.g. a manually-built node that
## somehow recurses via a custom proc).

import std/[math, options, strutils]
export options.Option, options.isSome, options.isNone, options.get,
       options.some, options.none

import ./fnv
import ./intern
import ./spans

export fnv.Hash128, fnv.`==`

const
  KdlReprMaxDepth* = 32
    ## Defensive cap on `$` recursion. Doc trees never reach this depth
    ## in practice (rule files top out around 5-6); the cap guards against
    ## pathological inputs.

type
  KdlValueKind* = enum
    kvString, kvInt, kvBigInt, kvFloat, kvBool, kvNull

  KdlValue* = object
    ## Atomic value carried by an entry. `typeAnnotation` is the v2
    ## `(type)value` prefix; `InvalidInterned` when absent.
    typeAnnotation*: InternedStr
    span*: Span
    case kind*: KdlValueKind
    of kvString: strVal*: string
    of kvInt:    intVal*: int64
    of kvBigInt:
      ## Integer value whose magnitude exceeds int64. Used for hex/bin/
      ## decimal literals in the (int64.high, ~2^128] range — see corpus
      ## `hex.kdl` and `hex_int.kdl`. Magnitude is `(bigHi shl 64) or
      ## bigLo`; `bigNegative` carries the sign. v0.2 caps at 128 bits;
      ## true arbitrary precision is filed for v0.3 if a real consumer
      ## needs it.
      bigHi*: uint64
      bigLo*: uint64
      bigNegative*: bool
    of kvFloat:  floatVal*: float
    of kvBool:   boolVal*: bool
    of kvNull:   discard

  KdlEntryKind* = enum
    keArgument   ## positional value after a node name (e.g. `rule "id"`)
    keProperty   ## key=value pair (e.g. `enabled=#true`)

  KdlEntry* = object
    ## `parseHash` is set by the parser to a fingerprint of the
    ## entry's canonical content. The encoder's `emPreserve` mode
    ## uses it to detect whether THIS specific entry was modified
    ## (vs the whole subtree). When `span` is valid AND
    ## `hash(current) == parseHash`, the encoder leaves the entry's
    ## source bytes alone — preserving exact spacing, alignment, and
    ## any trailing comments anchored to the entry's line.
    span*: Span
    parseHash*: Hash128
    case kind*: KdlEntryKind
    of keArgument:
      argValue*: KdlValue
    of keProperty:
      propName*: InternedStr
      propValue*: KdlValue

  KdlNode* = object
    ## A KDL node: name + optional type annotation + entries (args + props,
    ## in source order) + nested children. Span covers the entire node
    ## including children.
    ##
    ## `parseHash` is set by the parser at construction time — an FNV-1a
    ## 128-bit fingerprint of the node's canonical content (recursively
    ## including children). The encoder's `emPreserve` mode recomputes
    ## the hash at encode time and compares: match → emit source bytes
    ## (preserving comments, exact whitespace, original number bases);
    ## mismatch → subtree was mutated, emit canonical. Newly-constructed
    ## nodes leave parseHash at its default zero, which will never match
    ## a freshly-computed hash, so they always emit canonical.
    name*: InternedStr
    typeAnnotation*: InternedStr
    entries*: seq[KdlEntry]
    children*: seq[KdlNode]
    span*: Span
    parseHash*: Hash128
    parseEntryCount*: int32
      ## Count of entries at parse time. The encoder's surgical-splice
      ## path uses `entries.len == parseEntryCount` to decide whether
      ## edits were purely in-place (splice individual entries) or
      ## structural (fall back to canonical for this node only —
      ## siblings still preserved).
    parseChildCount*: int32
      ## Same role for children.

  KdlDoc* = object
    ## A parsed KDL document. The interner is owned by the doc; all
    ## InternedStr handles inside `nodes` reference it.
    ##
    ## `sourcePath` is the file path (or "<input>" / "<test>" etc.)
    ## for diagnostics; it doesn't open the file.
    ##
    ## `sourceText` holds the original input bytes when this doc was
    ## produced by `parse()`. Combined with the per-AST-node `Span`s,
    ## it enables byte-lossless round-trip via `encode(doc, emPreserve)`
    ## — strictly more compact than trivia-per-node alternatives, and
    ## preserves every representation choice (number bases, escape
    ## styles, raw-string `#`-counts, bare-vs-quoted) for free.
    ##
    ## `mutated` flips to true on the first builder/mutation op. The
    ## preserving encoder falls back to canonical when set, since the
    ## AST no longer matches the source bytes byte-for-byte. Cleared
    ## by `clearSource(doc)` if the consumer wants to disclaim the
    ## source-preservation property explicitly.
    sourcePath*: string
    sourceText*: string
    mutated*: bool
    parseTopLevelCount*: int32
      ## Count of top-level nodes at parse time. The encoder's doc-level
      ## surgical-splice path uses `nodes.len == parseTopLevelCount` to
      ## decide whether changes were purely in-place (splice each
      ## modified node back into sourceText, preserving comments and
      ## blank lines between siblings) or structural (fall back to a
      ## per-node loop with newline joins).
    interner*: Interner
    nodes*: seq[KdlNode]

# ---------------------------------------------------------------------------
# Constructors
# ---------------------------------------------------------------------------

func newDoc*(sourcePath = "<input>"): KdlDoc =
  ## A fresh empty document.
  KdlDoc(sourcePath: sourcePath, interner: initInterner(), nodes: @[])

proc newNode*(doc: var KdlDoc, name: string, span = pointSpan(StartPosition)): KdlNode =
  KdlNode(name: doc.interner.intern(name),
          typeAnnotation: InvalidInterned,
          entries: @[], children: @[], span: span)

func newStringValue*(s: string, span = pointSpan(StartPosition)): KdlValue =
  KdlValue(kind: kvString, strVal: s, span: span,
           typeAnnotation: InvalidInterned)

func newIntValue*(i: int64, span = pointSpan(StartPosition)): KdlValue =
  KdlValue(kind: kvInt, intVal: i, span: span,
           typeAnnotation: InvalidInterned)

func newBigIntValue*(hi, lo: uint64, negative: bool,
                     span = pointSpan(StartPosition)): KdlValue =
  KdlValue(kind: kvBigInt, bigHi: hi, bigLo: lo, bigNegative: negative,
           span: span, typeAnnotation: InvalidInterned)

func newFloatValue*(f: float, span = pointSpan(StartPosition)): KdlValue =
  KdlValue(kind: kvFloat, floatVal: f, span: span,
           typeAnnotation: InvalidInterned)

func newBoolValue*(b: bool, span = pointSpan(StartPosition)): KdlValue =
  KdlValue(kind: kvBool, boolVal: b, span: span,
           typeAnnotation: InvalidInterned)

func newNullValue*(span = pointSpan(StartPosition)): KdlValue =
  KdlValue(kind: kvNull, span: span,
           typeAnnotation: InvalidInterned)

func newArgument*(v: KdlValue, span = pointSpan(StartPosition)): KdlEntry =
  KdlEntry(kind: keArgument, argValue: v, span: span)

proc newProperty*(doc: var KdlDoc, name: string, v: KdlValue,
                  span = pointSpan(StartPosition)): KdlEntry =
  KdlEntry(kind: keProperty, propName: doc.interner.intern(name),
           propValue: v, span: span)

# ---------------------------------------------------------------------------
# Structural equality (ignores spans + interner identity)
# ---------------------------------------------------------------------------
#
# Two ASTs are "equal" if their structure matches — names, values, order.
# Spans are ignored because they're diagnostic-only and would otherwise
# make any round-trip-through-encoder test impossible.
#
# Interned handles are not compared by handle (which is interner-specific);
# instead the resolved string is compared. This lets ASTs from two different
# documents be compared structurally.

func floatStructEq(a, b: float): bool {.inline.} =
  ## Structural equality on floats. IEEE NaN != NaN, but for AST equality
  ## (especially round-trip testing of #nan) we want NaN-to-NaN to compare
  ## equal. Same for distinguishing +0 / -0 if it ever matters.
  if a.classify == fcNan and b.classify == fcNan: return true
  a == b

func `==`*(a, b: KdlValue): bool

func valueEqual*(aDoc, bDoc: KdlDoc, a, b: KdlValue): bool =
  ## Value equality across docs — resolves type annotations against each
  ## doc's interner without allocating intermediate strings.
  if a.kind != b.kind: return false
  if not equalsAcross(aDoc.interner, a.typeAnnotation,
                      bDoc.interner, b.typeAnnotation):
    return false
  case a.kind
  of kvString: a.strVal == b.strVal
  of kvInt:    a.intVal == b.intVal
  of kvBigInt: a.bigHi == b.bigHi and a.bigLo == b.bigLo and
               a.bigNegative == b.bigNegative
  of kvFloat:  floatStructEq(a.floatVal, b.floatVal)
  of kvBool:   a.boolVal == b.boolVal
  of kvNull:   true

func `==`*(a, b: KdlValue): bool =
  ## Same-doc value equality (or use of the same interner). For
  ## cross-doc comparison use `valueEqual`.
  if a.kind != b.kind: return false
  if a.typeAnnotation != b.typeAnnotation: return false
  case a.kind
  of kvString: a.strVal == b.strVal
  of kvInt:    a.intVal == b.intVal
  of kvBigInt: a.bigHi == b.bigHi and a.bigLo == b.bigLo and
               a.bigNegative == b.bigNegative
  of kvFloat:  floatStructEq(a.floatVal, b.floatVal)
  of kvBool:   a.boolVal == b.boolVal
  of kvNull:   true

func `==`*(a, b: KdlEntry): bool =
  if a.kind != b.kind: return false
  case a.kind
  of keArgument:
    a.argValue == b.argValue
  of keProperty:
    a.propName == b.propName and a.propValue == b.propValue

func `==`*(a, b: KdlNode): bool =
  ## Recursive structural equality. Caller is responsible for both nodes
  ## belonging to docs that share an interner OR for ensuring handle
  ## values happen to align — `nodeEqual` does the safer cross-doc form.
  if a.name != b.name: return false
  if a.typeAnnotation != b.typeAnnotation: return false
  if a.entries.len != b.entries.len: return false
  for i in 0 ..< a.entries.len:
    if a.entries[i] != b.entries[i]: return false
  if a.children.len != b.children.len: return false
  for i in 0 ..< a.children.len:
    if a.children[i] != b.children[i]: return false
  true

proc nodeEqual*(aDoc, bDoc: KdlDoc, a, b: KdlNode): bool =
  ## Cross-doc node equality — resolves names + properties through each
  ## doc's interner without allocating intermediate strings (the inner
  ## comparison helper `equalsAcross` walks both entries' byte storage
  ## in lockstep). Hot path: 4 cross-interner comparisons per node.
  if not equalsAcross(aDoc.interner, a.name, bDoc.interner, b.name):
    return false
  if not equalsAcross(aDoc.interner, a.typeAnnotation,
                      bDoc.interner, b.typeAnnotation):
    return false
  if a.entries.len != b.entries.len: return false
  for i in 0 ..< a.entries.len:
    let ae = a.entries[i]
    let be = b.entries[i]
    if ae.kind != be.kind: return false
    case ae.kind
    of keArgument:
      if not valueEqual(aDoc, bDoc, ae.argValue, be.argValue): return false
    of keProperty:
      if not equalsAcross(aDoc.interner, ae.propName,
                          bDoc.interner, be.propName):
        return false
      if not valueEqual(aDoc, bDoc, ae.propValue, be.propValue): return false
  if a.children.len != b.children.len: return false
  for i in 0 ..< a.children.len:
    if not nodeEqual(aDoc, bDoc, a.children[i], b.children[i]): return false
  true

proc docEqual*(a, b: KdlDoc): bool =
  ## Cross-doc structural equality.
  if a.nodes.len != b.nodes.len: return false
  for i in 0 ..< a.nodes.len:
    if not nodeEqual(a, b, a.nodes[i], b.nodes[i]): return false
  true

# ---------------------------------------------------------------------------
# Debug-readable rendering ($)
# ---------------------------------------------------------------------------
#
# Depth-bounded to KdlReprMaxDepth. Output is NOT canonical KDL — that's
# what the encoder (#524) is for; this is for assertion messages / debug
# logs / repr-style inspection.

proc reprValue(v: KdlValue, doc: KdlDoc): string =
  let annotated =
    if v.typeAnnotation == InvalidInterned: ""
    else: "(" & doc.interner.lookup(v.typeAnnotation) & ")"
  case v.kind
  of kvString: annotated & "\"" & v.strVal & "\""
  of kvInt:    annotated & $v.intVal
  of kvBigInt: annotated & "<bigint hi=" & $v.bigHi & " lo=" & $v.bigLo &
               (if v.bigNegative: " neg>" else: ">")
  of kvFloat:  annotated & $v.floatVal
  of kvBool:   annotated & (if v.boolVal: "#true" else: "#false")
  of kvNull:   annotated & "#null"

proc reprEntry(e: KdlEntry, doc: KdlDoc): string =
  case e.kind
  of keArgument:
    reprValue(e.argValue, doc)
  of keProperty:
    doc.interner.lookup(e.propName) & "=" & reprValue(e.propValue, doc)

proc reprNode(n: KdlNode, doc: KdlDoc, depth: int): string =
  if depth >= KdlReprMaxDepth:
    return "<…>"
  let annotated =
    if n.typeAnnotation == InvalidInterned: ""
    else: "(" & doc.interner.lookup(n.typeAnnotation) & ")"
  var parts = @[annotated & doc.interner.lookup(n.name)]
  for e in n.entries:
    parts.add(reprEntry(e, doc))
  result = parts.join(" ")
  if n.children.len > 0:
    var childReprs: seq[string] = @[]
    for c in n.children:
      childReprs.add(reprNode(c, doc, depth + 1))
    result &= " { " & childReprs.join("; ") & " }"

proc `$`*(doc: KdlDoc): string =
  ## Debug-readable single-line form. Use the encoder (#524) for
  ## canonical KDL output.
  var reprs: seq[string] = @[]
  for n in doc.nodes:
    reprs.add(reprNode(n, doc, 0))
  result = reprs.join("\n")

proc repr*(n: KdlNode, doc: KdlDoc): string =
  ## Render a single node against its owning doc.
  reprNode(n, doc, 0)

# ---------------------------------------------------------------------------
# Convenience: lookup helpers
# ---------------------------------------------------------------------------

proc resolveName*(doc: KdlDoc, n: KdlNode): string =
  ## The node's name as a fresh `string`. Allocates; cache the result if
  ## you'll use it more than once in a hot path.
  doc.interner.lookup(n.name)

proc typeAnnotationOf*(doc: KdlDoc, n: KdlNode): string =
  if n.typeAnnotation == InvalidInterned: ""
  else: doc.interner.lookup(n.typeAnnotation)

# `iterator children` and `iterator entries` removed — they shadowed
# the field of the same name and added zero behaviour over plain
# `for c in n.children: ...`. The two filtering iterators below carry
# their weight: they extract typed values from the heterogeneous
# `entries` seq.

iterator arguments*(n: KdlNode): KdlValue =
  ## Positional arguments only, in source order. Filters the
  ## heterogeneous `entries` seq to its `keArgument` payloads.
  for e in n.entries:
    if e.kind == keArgument:
      yield e.argValue

iterator properties*(n: KdlNode): tuple[name: InternedStr, value: KdlValue] =
  ## Properties only, in source order. Filters the heterogeneous
  ## `entries` seq to its `keProperty` payloads.
  for e in n.entries:
    if e.kind == keProperty:
      yield (e.propName, e.propValue)

iterator namedProperties*(n: KdlNode, doc: KdlDoc):
    tuple[name: string, value: KdlValue] =
  ## Like `properties` but yields the resolved name as a `string`.
  ## Convenience for ad-hoc inspection where the caller doesn't want
  ## to thread the interner.
  for e in n.entries:
    if e.kind == keProperty:
      yield (doc.interner.lookup(e.propName), e.propValue)

func arg*(n: KdlNode, idx: int): KdlValue =
  ## The `idx`-th positional argument on `n`, or a `kvNull` value if
  ## out of range. Properties interleaved among arguments are skipped:
  ## `arg(0)` is the first positional regardless of preceding `k=v`s.
  var seen = 0
  for e in n.entries:
    if e.kind == keArgument:
      if seen == idx: return e.argValue
      inc seen
  newNullValue()

func hasArg*(n: KdlNode, idx: int): bool =
  ## True iff `n` has at least `idx + 1` positional arguments.
  var seen = 0
  for e in n.entries:
    if e.kind == keArgument:
      if seen == idx: return true
      inc seen
  false

# ---------------------------------------------------------------------------
# String-keyed convenience accessors
# ---------------------------------------------------------------------------
#
# Thin wrappers over the InternedStr-keyed primitives in codegen.nim:
# look up the name via the doc's interner once, then walk the linear
# entries / children seq. Sentinel returns match the InternedStr-keyed
# helpers — `newNullValue()` for absent property, `KdlNode(name:
# InvalidInterned)` for absent child / node.

func prop*(n: KdlNode, doc: KdlDoc, name: string): Option[KdlValue] =
  ## First property with `name`, or `none(KdlValue)` if absent.
  ##
  ## `Option` (not a `kvNull` sentinel) so callers can distinguish
  ## "property missing" from "property present with `#null` value" —
  ## both are legal KDL but mean different things to most consumers.
  ## Use `hasProp` for an alloc-free presence check.
  for e in n.entries:
    if e.kind == keProperty and
       doc.interner.equals(e.propName, name):
      return some(e.propValue)
  none(KdlValue)

func hasProp*(n: KdlNode, doc: KdlDoc, name: string): bool =
  for e in n.entries:
    if e.kind == keProperty and
       doc.interner.equals(e.propName, name):
      return true
  false

func child*(n: KdlNode, doc: KdlDoc, name: string): Option[KdlNode] =
  ## First child with `name`, or `none(KdlNode)` if absent.
  for c in n.children:
    if doc.interner.equals(c.name, name): return some(c)
  none(KdlNode)

func hasChild*(n: KdlNode, doc: KdlDoc, name: string): bool =
  ## True iff `n` has at least one child with the given name.
  for c in n.children:
    if doc.interner.equals(c.name, name): return true
  false

func children*(n: KdlNode, doc: KdlDoc, name: string): seq[KdlNode] =
  for c in n.children:
    if doc.interner.equals(c.name, name):
      result.add(c)

func findNode*(doc: KdlDoc, name: string): Option[KdlNode] =
  ## First top-level node with `name`, or `none(KdlNode)` if absent.
  for n in doc.nodes:
    if doc.interner.equals(n.name, name): return some(n)
  none(KdlNode)

func hasNode*(doc: KdlDoc, name: string): bool =
  ## True iff `doc` has at least one top-level node with the given name.
  for n in doc.nodes:
    if doc.interner.equals(n.name, name): return true
  false

func findNodes*(doc: KdlDoc, name: string): seq[KdlNode] =
  for n in doc.nodes:
    if doc.interner.equals(n.name, name):
      result.add(n)

# ---------------------------------------------------------------------------
# Builder / mutation API
# ---------------------------------------------------------------------------
#
# Imperative wrappers over the underlying seq fields. Value semantics
# (KdlNode is a plain object) mean these mutate the `var` argument
# in place; the caller's own seq still owns the storage.
#
# All procs that intern a string take `var KdlDoc` because intern is
# itself a mutation of the interner. Read-only operations take
# `KdlDoc`.

proc markMutated*(doc: var KdlDoc) {.inline.} =
  ## Disclaim source-byte preservation. Sets `doc.mutated = true` so
  ## `encode(doc, emPreserve)` falls back to canonical. The mutation
  ## helpers below call this for you; expose it for consumers who edit
  ## the AST through raw field access (`doc.nodes[i].entries[j] = ...`)
  ## rather than the helpers.
  doc.mutated = true

proc clearSource*(doc: var KdlDoc) {.inline.} =
  ## Disclaim source preservation explicitly: drop the cached sourceText
  ## and mark the doc mutated. Call this if you intend to edit and
  ## don't want emPreserve to carry stale bytes around.
  doc.sourceText = ""
  doc.mutated = true

proc add*(doc: var KdlDoc, n: sink KdlNode) {.inline.} =
  ## Append a top-level node.
  doc.nodes.add(n)
  doc.mutated = true

proc insert*(doc: var KdlDoc, idx: int, n: sink KdlNode) =
  ## Insert a top-level node at `idx`. `idx == doc.nodes.len` appends;
  ## values outside `[0, doc.nodes.len]` clamp to the nearest end.
  let i = max(0, min(idx, doc.nodes.len))
  doc.nodes.insert(n, i)
  doc.mutated = true

proc addArg*(n: var KdlNode, doc: var KdlDoc, v: KdlValue) {.inline.} =
  ## Append a positional argument entry.
  n.entries.add(KdlEntry(kind: keArgument, argValue: v, span: n.span))
  doc.mutated = true

proc setArg*(n: var KdlNode, doc: var KdlDoc, idx: int,
             v: KdlValue): bool =
  ## Replace the `idx`-th positional argument's value. Index is among
  ## arguments only (properties skipped). Returns false when out of
  ## range.
  var argSeen = 0
  for i in 0 ..< n.entries.len:
    if n.entries[i].kind == keArgument:
      if argSeen == idx:
        n.entries[i] = KdlEntry(kind: keArgument, argValue: v,
                                span: n.entries[i].span)
        doc.mutated = true
        return true
      inc argSeen
  false

proc removeArg*(n: var KdlNode, doc: var KdlDoc, idx: int): bool =
  ## Remove the `idx`-th positional argument. Returns false when out of
  ## range.
  var argSeen = 0
  for i in 0 ..< n.entries.len:
    if n.entries[i].kind == keArgument:
      if argSeen == idx:
        n.entries.delete(i)
        doc.mutated = true
        return true
      inc argSeen
  false

proc addChild*(n: var KdlNode, doc: var KdlDoc, c: sink KdlNode) {.inline.} =
  ## Append a child node.
  n.children.add(c)
  doc.mutated = true

proc insertChild*(n: var KdlNode, doc: var KdlDoc, idx: int,
                  c: sink KdlNode) =
  ## Insert a child node at `idx`. Clamps to the seq's bounds.
  let i = max(0, min(idx, n.children.len))
  n.children.insert(c, i)
  doc.mutated = true

proc setProp*(n: var KdlNode, doc: var KdlDoc, name: string, v: KdlValue) =
  ## Set property `name = v`. If a property with that name already
  ## exists, its value is replaced in place (preserving source order).
  ## Otherwise the property is appended.
  let key = doc.interner.intern(name)
  doc.mutated = true
  for i in 0 ..< n.entries.len:
    if n.entries[i].kind == keProperty and n.entries[i].propName == key:
      n.entries[i] = KdlEntry(kind: keProperty, propName: key,
                              propValue: v, span: n.entries[i].span)
      return
  n.entries.add(KdlEntry(kind: keProperty, propName: key, propValue: v,
                         span: n.span))

proc removeProp*(n: var KdlNode, doc: var KdlDoc, name: string): bool =
  ## Remove the first property with the given name. Returns true iff
  ## a property was removed.
  var i = 0
  while i < n.entries.len:
    if n.entries[i].kind == keProperty and
       doc.interner.equals(n.entries[i].propName, name):
      n.entries.delete(i)
      doc.mutated = true
      return true
    inc i
  false

proc removeChild*(n: var KdlNode, doc: var KdlDoc, name: string): int =
  ## Remove every child whose name matches. Returns the number removed.
  var i = 0
  while i < n.children.len:
    if doc.interner.equals(n.children[i].name, name):
      n.children.delete(i)
      inc result
    else:
      inc i
  if result > 0: doc.mutated = true

proc replaceChild*(n: var KdlNode, doc: var KdlDoc, name: string,
                   replacement: sink KdlNode): bool =
  ## Replace the first child with the given name. Returns true iff a
  ## match was found and replaced.
  for i in 0 ..< n.children.len:
    if doc.interner.equals(n.children[i].name, name):
      n.children[i] = replacement
      doc.mutated = true
      return true
  false

proc setName*(n: var KdlNode, doc: var KdlDoc, name: string) {.inline.} =
  ## Change the node's name. Interns the new name via the doc.
  n.name = doc.interner.intern(name)
  doc.mutated = true

proc setTypeAnnotation*(n: var KdlNode, doc: var KdlDoc, tag: string) {.inline.} =
  ## Tag the node with a type annotation.
  n.typeAnnotation = doc.interner.intern(tag)
  doc.mutated = true

proc clearTypeAnnotation*(n: var KdlNode, doc: var KdlDoc) {.inline.} =
  n.typeAnnotation = InvalidInterned
  doc.mutated = true

proc setTypeAnnotation*(v: var KdlValue, doc: var KdlDoc, tag: string) {.inline.} =
  ## Tag a value with a type annotation (e.g. `(ipv4)"1.2.3.4"`).
  v.typeAnnotation = doc.interner.intern(tag)
  doc.mutated = true

proc clearTypeAnnotation*(v: var KdlValue, doc: var KdlDoc) {.inline.} =
  v.typeAnnotation = InvalidInterned
  doc.mutated = true

proc removeNode*(doc: var KdlDoc, name: string): int =
  ## Remove every top-level node with the given name. Returns count.
  var i = 0
  while i < doc.nodes.len:
    if doc.interner.equals(doc.nodes[i].name, name):
      doc.nodes.delete(i)
      inc result
    else:
      inc i
  if result > 0: doc.mutated = true

proc replaceNode*(doc: var KdlDoc, name: string,
                  replacement: sink KdlNode): bool =
  ## Replace the first top-level node with the given name. Returns true
  ## iff a match was found and replaced.
  for i in 0 ..< doc.nodes.len:
    if doc.interner.equals(doc.nodes[i].name, name):
      doc.nodes[i] = replacement
      doc.mutated = true
      return true
  false

