## node.nim — self-contained KdlNode / KdlDoc (rfc-core-rebuild §5.2, §9).
##
## A `KdlNode` owns its `name` and `typeAnnotation` as plain strings (prop keys
## are owned by the `KdlEntry` leaf in `value.nim`). There is no interner and no
## `ownerDocument` back-reference, so:
##
##   * `newNode(name)` takes NO document — a detached node is fully usable;
##   * read accessors (`n.name`, `n.prop`, `n.child`, …) are doc-free;
##   * `==` is structural and recursive, cross-doc-correct with no `equalsAcross`.
##
## Absence policy (rfc §9.1): `nil` for nodes (refs are nullable), `Option` for
## values (value types are not). `prop` is **last-wins** per KDL 2.0 §Properties.
##
## NOTE (migration): `entries` / `childNodes` / `rootNodes` are public for now so
## the builder/parser can populate them while the core is ported in. SF hides the
## raw storage behind the mutation API + a `{.dangerous.}` escape (rfc §9.2).

import std/options
import ./value
import ./spans
export value
export spans.Span, spans.offset, spans.length, spans.endOffset, spans.initSpan

type
  KdlNode* = ref object
    name*: string
    typeAnnotation*: Option[string]
    entries*: seq[KdlEntry]
    childNodes*: seq[KdlNode]
    dirty*: bool
      ## Set by every mutator; consulted by the preserving encoder.
    span*: Span
      ## `[offset, offset+length)` byte range of this node's source in the
      ## owning doc's `sourceText` (rfc-consumer-api §4.1, gap S). A plain
      ## 8-byte VALUE — no doc back-pointer, no ORC cycle; the core-rebuild's
      ## doc-free `KdlNode` axiom holds. `length == 0` is the unambiguous
      ## "no source" sentinel (hand-built nodes; zero-initialized). A real
      ## parsed node always has `length >= 1`. The fuller #31 NodeMeta
      ## (parseHash / headLen / entry spans) is a separate, orthogonal future
      ## concern — this field does not anticipate it.

  KdlDoc* = ref object
    sourcePath*: string
    sourceText*: string
    lineMap*: LineMap
      ## Offset→(line,col) map over `sourceText`, built **once** when the doc is
      ## constructed (`setSource`). Node-by-node decode (`decodeNode(doc, node)`,
      ## `decodeChild`) enriches errors against this cached map instead of
      ## rebuilding it per erroring node — turning O(N·n) into O(n + N·log n)
      ## (review #3). Empty (`lineStarts == @[]`) for hand-built docs that never
      ## ran through `setSource`; the decode path falls back to its no-source
      ## re-emit branch for hand-built nodes anyway, so those never read it.
    preserveFormat*: bool
    rootNodes*: seq[KdlNode]

# ── constructors (no doc) ────────────────────────────────────────────────────

func newNode*(name: string): KdlNode =
  ## A detached node. No document, no interner — owns its own name bytes.
  KdlNode(name: name, typeAnnotation: none(string), entries: @[], childNodes: @[])

func newDoc*(sourcePath = "<input>"): KdlDoc =
  KdlDoc(sourcePath: sourcePath, rootNodes: @[])

func setSource*(doc: KdlDoc, sourceText: string) =
  ## Attach the doc's verbatim source and build its `LineMap` **once**, at
  ## construction (node_build). The single source of truth for `doc.sourceText`
  ## + `doc.lineMap` staying in lockstep: any code that wants the cached map
  ## must set the text through here, never by assigning `sourceText` directly.
  doc.sourceText = sourceText
  doc.lineMap = buildLineMap(sourceText)

# ── argument accessors (doc-free) ────────────────────────────────────────────

iterator arguments*(n: KdlNode): KdlValue =
  ## Positional arguments only, in source order.
  for e in n.entries:
    if e.kind == keArgument: yield e.argValue

func arg*(n: KdlNode, idx: int): Option[KdlValue] =
  ## The `idx`-th positional argument, or `none` if out of range. Properties
  ## interleaved among arguments are skipped.
  var seen = 0
  for e in n.entries:
    if e.kind == keArgument:
      if seen == idx: return some(e.argValue)
      inc seen
  none(KdlValue)

func args*(n: KdlNode): seq[KdlValue] =
  for v in n.arguments: result.add v

# ── property accessors (doc-free; last-wins) ─────────────────────────────────

iterator properties*(n: KdlNode): tuple[key: string, value: KdlValue] =
  for e in n.entries:
    if e.kind == keProperty: yield (e.propKey, e.propValue)

func prop*(n: KdlNode, key: string): Option[KdlValue] =
  ## The value of property `key`, or `none` if absent. **Last-wins**: when a key
  ## repeats, the rightmost value is returned (KDL 2.0 §Properties). The parser
  ## collapses duplicates, but the accessor honors the spec for hand-built nodes
  ## too.
  result = none(KdlValue)
  for e in n.entries:
    if e.kind == keProperty and e.propKey == key:
      result = some(e.propValue)   # keep overwriting → rightmost survives

func props*(n: KdlNode): seq[tuple[key: string, value: KdlValue]] =
  for kv in n.properties: result.add kv

# ── child / node accessors (doc-free; nil for absent; by-value seqs) ──────────

func child*(n: KdlNode, name: string): KdlNode =
  ## First child named `name`, or `nil`.
  for c in n.childNodes:
    if c.name == name: return c
  nil

func children*(n: KdlNode): seq[KdlNode] =
  ## All children, by value (rfc §9.2: a `lent` view would dangle across a
  ## mutator call — no borrow checker to prevent it).
  n.childNodes

func children*(n: KdlNode, name: string): seq[KdlNode] =
  for c in n.childNodes:
    if c.name == name: result.add c

func node*(doc: KdlDoc, name: string): KdlNode =
  for n in doc.rootNodes:
    if n.name == name: return n
  nil

func nodes*(doc: KdlDoc): seq[KdlNode] =
  doc.rootNodes

func nodes*(doc: KdlDoc, name: string): seq[KdlNode] =
  for n in doc.rootNodes:
    if n.name == name: result.add n

# ── structural equality (doc-free, recursive) ────────────────────────────────

func `==`*(a, b: KdlNode): bool =
  if a.isNil or b.isNil: return a.isNil and b.isNil
  if a.name != b.name: return false
  if a.typeAnnotation != b.typeAnnotation: return false
  if a.entries != b.entries: return false           # seq[KdlEntry] via value.`==`
  if a.childNodes.len != b.childNodes.len: return false
  for i in 0 ..< a.childNodes.len:
    if a.childNodes[i] != b.childNodes[i]: return false
  true

func `==`*(a, b: KdlDoc): bool =
  if a.isNil or b.isNil: return a.isNil and b.isNil
  if a.rootNodes.len != b.rootNodes.len: return false
  for i in 0 ..< a.rootNodes.len:
    if a.rootNodes[i] != b.rootNodes[i]: return false
  true

func nodeEqual*(a, b: KdlNode): bool {.inline.} = a == b
  ## Structural node equality. Self-contained — no document needed (the
  ## interned-core era's `nodeEqual(aDoc, bDoc, a, b)` collapses to plain
  ## `==` now that names/keys/annotations are owned strings).

func docEqual*(a, b: KdlDoc): bool {.inline.} = a == b
  ## Structural document equality — the doc-free counterpart of the old
  ## `ast.docEqual`. Used by the conformance differential oracle.

# ── typed read conveniences (rfc §9.1) ───────────────────────────────────────
# Each returns `some(x)` when the property/arg exists AND its value kind matches,
# else `none` (absent or wrong kind — both "no usable value of this type").

func propInt*(n: KdlNode, key: string): Option[int64] =
  let v = n.prop(key)
  if v.isSome and v.get.kind == kvInt: some(v.get.intVal) else: none(int64)
func propStr*(n: KdlNode, key: string): Option[string] =
  let v = n.prop(key)
  if v.isSome and v.get.kind == kvString: some(v.get.strVal) else: none(string)
func propBool*(n: KdlNode, key: string): Option[bool] =
  let v = n.prop(key)
  if v.isSome and v.get.kind == kvBool: some(v.get.boolVal) else: none(bool)
func propFloat*(n: KdlNode, key: string): Option[float] =
  let v = n.prop(key)
  if v.isSome and v.get.kind == kvFloat: some(v.get.floatVal) else: none(float)

func argInt*(n: KdlNode, i: int): Option[int64] =
  let v = n.arg(i)
  if v.isSome and v.get.kind == kvInt: some(v.get.intVal) else: none(int64)
func argStr*(n: KdlNode, i: int): Option[string] =
  let v = n.arg(i)
  if v.isSome and v.get.kind == kvString: some(v.get.strVal) else: none(string)
func argBool*(n: KdlNode, i: int): Option[bool] =
  let v = n.arg(i)
  if v.isSome and v.get.kind == kvBool: some(v.get.boolVal) else: none(bool)
func argFloat*(n: KdlNode, i: int): Option[float] =
  let v = n.arg(i)
  if v.isSome and v.get.kind == kvFloat: some(v.get.floatVal) else: none(float)

# ── mutation API (rfc §9.2) — doc-free; every mutator sets `dirty` ────────────

proc setName*(n: KdlNode, name: string) =
  n.name = name; n.dirty = true

proc setTypeAnnotation*(n: KdlNode, anno: Option[string]) =
  n.typeAnnotation = anno; n.dirty = true

proc addArg*(n: KdlNode, v: KdlValue) =
  n.entries.add(newArgument(v)); n.dirty = true

proc setArg*(n: KdlNode, idx: int, v: KdlValue): bool {.discardable.} =
  ## Replace the value of the `idx`-th positional argument (properties
  ## interleaved among args are skipped). Returns false (no-op) if `idx` is out
  ## of range — `addArg` to append.
  var seen = 0
  for i in 0 ..< n.entries.len:
    if n.entries[i].kind == keArgument:
      if seen == idx:
        n.entries[i].argValue = v; n.dirty = true
        return true
      inc seen
  false

proc removeArg*(n: KdlNode, idx: int): bool {.discardable.} =
  ## Remove the `idx`-th positional argument; false (no-op) if out of range.
  var seen = 0
  for i in 0 ..< n.entries.len:
    if n.entries[i].kind == keArgument:
      if seen == idx:
        n.entries.delete(i); n.dirty = true; return true
      inc seen
  false

proc setProp*(n: KdlNode, key: string, v: KdlValue) =
  ## Upsert: replace the (single) existing entry for `key` if present, else
  ## append. KDL is last-wins, so a node never holds duplicate keys — `addProp`
  ## is deliberately absent (it would only manufacture that footgun).
  var i = 0
  while i < n.entries.len:
    if n.entries[i].kind == keProperty and n.entries[i].propKey == key:
      n.entries.delete(i)
    else: inc i
  n.entries.add(newProperty(key, v)); n.dirty = true

proc removeProp*(n: KdlNode, key: string): bool {.discardable.} =
  ## Remove the property `key`; returns true iff one was present.
  var i = 0
  while i < n.entries.len:
    if n.entries[i].kind == keProperty and n.entries[i].propKey == key:
      n.entries.delete(i); n.dirty = true; return true
    else: inc i
  false

proc setPropInt*(n: KdlNode, key: string, v: int64) = n.setProp(key, newKdlInt(v))
proc setPropStr*(n: KdlNode, key: string, v: string) = n.setProp(key, newKdlString(v))
proc setPropBool*(n: KdlNode, key: string, v: bool) = n.setProp(key, newKdlBool(v))
proc setPropFloat*(n: KdlNode, key: string, v: float) = n.setProp(key, newKdlFloat(v))

proc addChild*(n: KdlNode, child: KdlNode) =
  n.childNodes.add(child); n.dirty = true

proc insertChild*(n: KdlNode, idx: int, child: KdlNode) =
  ## Insert `child` at position `idx`, clamped to `[0, len]`.
  n.childNodes.insert(child, max(0, min(idx, n.childNodes.len)))
  n.dirty = true

proc replaceChild*(n: KdlNode, idx: int, child: KdlNode): bool {.discardable.} =
  ## Replace the child at `idx`; returns false (no-op) if `idx` is out of range.
  if idx < 0 or idx >= n.childNodes.len: return false
  n.childNodes[idx] = child; n.dirty = true
  true

proc clone*(n: KdlNode): KdlNode =
  ## Deep copy of `n` and its subtree, fully independent of the original. Trivial
  ## under owned strings: `entries` are value objects (copied on seq assignment);
  ## children recurse. No interner / doc / offset remapping.
  result = KdlNode(name: n.name, typeAnnotation: n.typeAnnotation,
                   entries: n.entries, dirty: n.dirty)
  result.childNodes = newSeqOfCap[KdlNode](n.childNodes.len)
  for c in n.childNodes:
    result.childNodes.add(clone(c))

proc removeChild*(n: KdlNode, name: string): int {.discardable.} =
  ## Remove every child named `name`; returns how many were removed.
  var i = 0
  while i < n.childNodes.len:
    if n.childNodes[i].name == name:
      n.childNodes.delete(i); inc result
    else: inc i
  if result > 0: n.dirty = true

proc add*(doc: KdlDoc, n: KdlNode) =
  ## Append a top-level node.
  doc.rootNodes.add(n)

proc insert*(doc: KdlDoc, idx: int, n: KdlNode) =
  ## Insert a top-level node at position `idx`, clamped to `[0, len]`.
  doc.rootNodes.insert(n, max(0, min(idx, doc.rootNodes.len)))

# ── traversal (rfc §9.4) ─────────────────────────────────────────────────────

iterator descendants*(n: KdlNode): KdlNode =
  ## Every node in `n`'s subtree (excluding `n` itself), pre-order DFS.
  ## Iterative — Nim forbids recursive inline iterators.
  var stack: seq[KdlNode] = @[]
  for i in countdown(n.childNodes.high, 0): stack.add(n.childNodes[i])
  while stack.len > 0:
    let cur = stack.pop()
    yield cur
    for i in countdown(cur.childNodes.high, 0): stack.add(cur.childNodes[i])

func find*(n: KdlNode, name: string): KdlNode =
  ## First descendant named `name` (pre-order), or `nil`. Returns the live ref —
  ## mutate through it. To remove it, use `findPath` (no parent pointers).
  for d in n.descendants:
    if d.name == name: return d
  nil

func findPathInto(n: KdlNode, name: string, path: var seq[KdlNode]): bool =
  path.add(n)
  if n.name == name: return true
  for c in n.childNodes:
    if findPathInto(c, name, path): return true
  discard path.pop()
  false

func findPath*(root: KdlNode, name: string): seq[KdlNode] =
  ## The chain from `root` down to the first node (pre-order, `root` inclusive)
  ## named `name`. Empty if no match. The removal-of-found companion: the
  ## second-to-last element is the match's parent.
  if not findPathInto(root, name, result):
    result = @[]

# ── predicate selection (rfc §9.4) — typed superset of KQL matchers ───────────

proc where*(nodes: openArray[KdlNode], pred: proc(n: KdlNode): bool): seq[KdlNode] =
  for n in nodes:
    if pred(n): result.add n

proc first*(nodes: openArray[KdlNode], pred: proc(n: KdlNode): bool): KdlNode =
  for n in nodes:
    if pred(n): return n
  nil

proc only*(nodes: openArray[KdlNode], pred: proc(n: KdlNode): bool): KdlNode =
  ## Exactly one match → that node; zero or more than one → `nil`.
  var count = 0
  for n in nodes:
    if pred(n): result = n; inc count
  if count != 1: result = nil

proc byName*(name: string): proc(n: KdlNode): bool =
  result = proc(n: KdlNode): bool = n.name == name

proc hasProp*(key: string): proc(n: KdlNode): bool =
  result = proc(n: KdlNode): bool = n.prop(key).isSome

proc propEq*(key: string, v: KdlValue): proc(n: KdlNode): bool =
  result = proc(n: KdlNode): bool = n.prop(key) == some(v)
