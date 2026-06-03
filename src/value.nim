## value.nim — the shared low-level value leaf (rfc-core-rebuild §5.2 / §6).
##
## `KdlValue` / `KdlEntry` are **self-contained**: they own every byte they need
## to render and compare — `strVal`, `propKey`, and the `typeAnnotation` are plain
## owned strings, not `InternedStr` handles. There is no interner, no document, and
## no back-reference. Consequences, all by construction:
##
##   * a value/entry built in code (no parse, no doc) is fully usable;
##   * `==` is structural — two independently-built values with the same content
##     are equal, with no shared interner (impossible under the handle model);
##   * the leaf imports nothing from the DOM (`ast`) — so Cat-1 (`cursor.resolveValue`),
##     Cat-2 (the `kdlDecodeValue` codec) and Cat-3 (the `ast` node tree) all depend
##     on *this* leaf, never the reverse.
##
## Parse-only metadata (`span`, `parseHash`) deliberately lives elsewhere — on the
## per-node/per-entry sidecar (§5.5), not on these hot structs.

import std/options

type
  KdlValueKind* = enum
    kvString, kvInt, kvBigInt, kvFloat, kvBool, kvNull

  KdlValue* = object
    ## Atomic value carried by an entry. `typeAnnotation` is the v2
    ## `(type)value` prefix: `none` when absent, `some("")` for the
    ## empty annotation `("")value`, `some("x")` otherwise.
    typeAnnotation*: Option[string]
    case kind*: KdlValueKind
    of kvString: strVal*: string
    of kvInt:    intVal*: int64
    of kvBigInt:
      ## Integer magnitude exceeding int64, capped at 128 bits.
      ## Magnitude is `(bigHi shl 64) or bigLo`; `bigNegative` is the sign.
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
    case kind*: KdlEntryKind
    of keArgument:
      argValue*: KdlValue
    of keProperty:
      propKey*: string        ## owned key bytes — no interner handle
      propValue*: KdlValue

# ── constructors ────────────────────────────────────────────────────────────

func newKdlString*(s: string): KdlValue =
  KdlValue(kind: kvString, strVal: s, typeAnnotation: none(string))

func newKdlInt*(i: int64): KdlValue =
  KdlValue(kind: kvInt, intVal: i, typeAnnotation: none(string))

func newKdlBigInt*(bigHi, bigLo: uint64, bigNegative: bool): KdlValue =
  KdlValue(kind: kvBigInt, bigHi: bigHi, bigLo: bigLo,
           bigNegative: bigNegative, typeAnnotation: none(string))

func newKdlFloat*(f: float): KdlValue =
  KdlValue(kind: kvFloat, floatVal: f, typeAnnotation: none(string))

func newKdlBool*(b: bool): KdlValue =
  KdlValue(kind: kvBool, boolVal: b, typeAnnotation: none(string))

func newKdlNull*(): KdlValue =
  KdlValue(kind: kvNull, typeAnnotation: none(string))

func withAnno*(v: KdlValue, anno: string): KdlValue =
  ## Return `v` with `anno` layered onto its `typeAnnotation` when `anno` is
  ## non-empty; an empty `anno` leaves the value's own annotation untouched.
  ## Used by the kdlScalar encode path to apply a `{.kdlReserved.}` tag to the
  ## value the user's `kdlEncodeValue` hook returns (the empty-string default
  ## means "no tag", so a hook-supplied annotation survives).
  result = v
  if anno.len > 0:
    result.typeAnnotation = some(anno)

func newArgument*(v: KdlValue): KdlEntry =
  KdlEntry(kind: keArgument, argValue: v)

func newProperty*(key: string, v: KdlValue): KdlEntry =
  KdlEntry(kind: keProperty, propKey: key, propValue: v)

# ── structural equality (doc-free; no interner) ──────────────────────────────

func `==`*(a, b: KdlValue): bool =
  ## Structural equality. Both the annotation and the payload must match;
  ## different kinds are never equal. No interner / doc needed.
  if a.typeAnnotation != b.typeAnnotation: return false
  if a.kind != b.kind: return false
  case a.kind
  of kvString: a.strVal == b.strVal
  of kvInt:    a.intVal == b.intVal
  of kvBigInt: a.bigHi == b.bigHi and a.bigLo == b.bigLo and
               a.bigNegative == b.bigNegative
  of kvFloat:
    # NaN-aware: structural equality must be reflexive, and two `#nan` values
    # denote the same KDL model (IEEE NaN != NaN is a numeric rule, not a
    # data-model identity rule). `x != x` is the canonical NaN test.
    a.floatVal == b.floatVal or (a.floatVal != a.floatVal and b.floatVal != b.floatVal)
  of kvBool:   a.boolVal == b.boolVal
  of kvNull:   true

func `==`*(a, b: KdlEntry): bool =
  if a.kind != b.kind: return false
  case a.kind
  of keArgument: a.argValue == b.argValue
  of keProperty: a.propKey == b.propKey and a.propValue == b.propValue
