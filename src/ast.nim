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

import std/[math, strutils]

import ./intern
import ./spans

const
  KdlReprMaxDepth* = 32
    ## Defensive cap on `$` recursion. Doc trees never reach this depth
    ## in practice (rule files top out around 5-6); the cap guards against
    ## pathological inputs.

type
  KdlValueKind* = enum
    kvString, kvInt, kvFloat, kvBool, kvNull

  KdlValue* = object
    ## Atomic value carried by an entry. `typeAnnotation` is the v2
    ## `(type)value` prefix; `InvalidInterned` when absent.
    typeAnnotation*: InternedStr
    span*: Span
    case kind*: KdlValueKind
    of kvString: strVal*: string
    of kvInt:    intVal*: int64
    of kvFloat:  floatVal*: float
    of kvBool:   boolVal*: bool
    of kvNull:   discard

  KdlEntryKind* = enum
    keArgument   ## positional value after a node name (e.g. `rule "id"`)
    keProperty   ## key=value pair (e.g. `enabled=#true`)

  KdlEntry* = object
    span*: Span
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
    name*: InternedStr
    typeAnnotation*: InternedStr
    entries*: seq[KdlEntry]
    children*: seq[KdlNode]
    span*: Span

  KdlDoc* = object
    ## A parsed KDL document. The interner is owned by the doc; all
    ## InternedStr handles inside `nodes` reference it.
    ##
    ## `sourcePath` is the file path (or "<input>" / "<test>" etc.)
    ## for diagnostics; it doesn't open the file.
    sourcePath*: string
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

