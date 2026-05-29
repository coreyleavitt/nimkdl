## Grammar-aware event-sequence generator for substrate properties
## P1 and P2 (Stages F11–F13).
##
## Generates a `seq[GenEvent]` — a synthetic event sequence
## structurally equivalent to what the cursor would produce given
## some well-formed KDL source. The generator is a state machine
## drawing from proptest's choice sequence so every produced
## sequence is bracket-balanced and KDL-semantics-valid by
## construction.
##
## Why "synthetic" rather than `CursorEvent`: `CursorEvent` carries
## spans pointing into a real source string; a generator has no
## source. `GenEvent` is the kind+payload subset, span-free. P1's
## equivalence is over `eventDataEqual` (kind + payload), not the
## span-bearing CursorEvent itself.
##
## Build-out (one cycle per shape feature):
## - F11.1 tracer — single bare node
## - F11.2 typed args
## - F11.3 props
## - F11.4 children block (recursive, depth-bounded)
## - F11.5 annotations
## - F11.6 slashdash
## - F11.7 top-level multi-node

import proptest

import ../src/emitter

type
  GenEventKind* = enum
    geNodeBegin
    geNodeEnd
    geArgString
    geArgInt
    geArgFloat
    geArgBool
    geArgNull
    gePropString
    gePropInt
    gePropFloat
    gePropBool
    gePropNull
    geChildrenBegin
    geChildrenEnd

  GenEvent* = object
    ## Span-free counterpart of `CursorEvent`. Carries only the data
    ## the substrate property tests need to compare across the
    ## emitter → cursor round trip.
    case kind*: GenEventKind
    of geNodeBegin:
      nodeName*: string
    of geArgString:
      argStr*: string
    of geArgInt:
      argInt*: int64
    of geArgFloat:
      argFloat*: float
    of geArgBool:
      argBool*: bool
    of gePropString:
      propStrKey*: string
      propStrVal*: string
    of gePropInt:
      propIntKey*: string
      propIntVal*: int64
    of gePropFloat:
      propFloatKey*: string
      propFloatVal*: float
    of gePropBool:
      propBoolKey*: string
      propBoolVal*: bool
    of gePropNull:
      propNullKey*: string
    else: discard

proc pushGenEvent*(e: var BufferEmitter, ev: GenEvent) =
  ## Drive an emitter from a single GenEvent. Inverse of the
  ## cursor's emission; tests use this to materialize the generated
  ## sequence into bytes that then get parsed back through the
  ## cursor.
  case ev.kind
  of geNodeBegin:      e.pushNodeBegin(ev.nodeName)
  of geNodeEnd:        e.pushNodeEnd()
  of geArgString:      e.pushArgString(ev.argStr)
  of geArgInt:         e.pushArgInt(ev.argInt)
  of geArgFloat:       e.pushArgFloat(ev.argFloat)
  of geArgBool:        e.pushArgBool(ev.argBool)
  of geArgNull:        e.pushArgNull()
  of gePropString:     e.pushPropString(ev.propStrKey, ev.propStrVal)
  of gePropInt:        e.pushPropInt(ev.propIntKey, ev.propIntVal)
  of gePropFloat:      e.pushPropFloat(ev.propFloatKey, ev.propFloatVal)
  of gePropBool:       e.pushPropBool(ev.propBoolKey, ev.propBoolVal)
  of gePropNull:       e.pushPropNull(ev.propNullKey)
  of geChildrenBegin:  e.pushChildrenBegin()
  of geChildrenEnd:    e.pushChildrenEnd()

# ---------------------------------------------------------------------------
# Generators
# ---------------------------------------------------------------------------

# Bareword-safe identifier strategy. Restricting to lower-case ASCII
# letters keeps every drawn name a valid KDL bareword so node/prop
# names never need quoting. Wider character sets land in later
# cycles once the simple cases are proven round-trip-clean.
proc identifiers*(minLen = 1, maxLen = 12): Strategy[string] =
  strings(intervals([(0x61'i32, 0x7a'i32)]), minLen, maxLen)

proc bareNodeEvents*(): Strategy[seq[GenEvent]] =
  ## F11.1 tracer — sequence `[NodeBegin(name), NodeEnd]`.
  let nameStrat = identifiers()
  newStrategy[seq[GenEvent]](proc(src: var DataSource): seq[GenEvent] =
    let name = nameStrat.run(src)
    @[GenEvent(kind: geNodeBegin, nodeName: name),
      GenEvent(kind: geNodeEnd)])

proc argEvents*(): Strategy[GenEvent] =
  ## F11.2 — single typed arg. Draws kind, then per-kind payload.
  ## String args constrain to printable ASCII for now (escaping is
  ## exercised separately by P12); numeric kinds span their full
  ## range; null has no payload.
  let argStrings = strings(0, 32)
  let argInts = integers(low(int64), high(int64))
  let argFloats = floats(-1e9, 1e9, allowNan = false)
  let argBools = booleans()
  newStrategy[GenEvent](proc(src: var DataSource): GenEvent =
    let kindIdx = toInt64(src.drawInteger(
      toInt128(0'i64), toInt128(4'i64), toInt128(0'i64)))
    case kindIdx
    of 0: GenEvent(kind: geArgString, argStr: argStrings.run(src))
    of 1: GenEvent(kind: geArgInt,    argInt:   argInts.run(src))
    of 2: GenEvent(kind: geArgFloat,  argFloat: argFloats.run(src))
    of 3: GenEvent(kind: geArgBool,   argBool:  argBools.run(src))
    else: GenEvent(kind: geArgNull))

proc propEvents*(): Strategy[GenEvent] =
  ## F11.3 — single typed prop. Key is a bareword-safe identifier;
  ## value spans the same kind range as args.
  let keyStrat = identifiers(1, 8)
  let strVals = strings(0, 32)
  let intVals = integers(low(int64), high(int64))
  let floatVals = floats(-1e9, 1e9, allowNan = false)
  let boolVals = booleans()
  newStrategy[GenEvent](proc(src: var DataSource): GenEvent =
    let kindIdx = toInt64(src.drawInteger(
      toInt128(0'i64), toInt128(4'i64), toInt128(0'i64)))
    let key = keyStrat.run(src)
    case kindIdx
    of 0: GenEvent(kind: gePropString, propStrKey: key,
                   propStrVal: strVals.run(src))
    of 1: GenEvent(kind: gePropInt, propIntKey: key,
                   propIntVal: intVals.run(src))
    of 2: GenEvent(kind: gePropFloat, propFloatKey: key,
                   propFloatVal: floatVals.run(src))
    of 3: GenEvent(kind: gePropBool, propBoolKey: key,
                   propBoolVal: boolVals.run(src))
    else: GenEvent(kind: gePropNull, propNullKey: key))

proc nodeWithEntriesEvents*(maxEntries = 6): Strategy[seq[GenEvent]] =
  ## F11.3 — node with 0..maxEntries entries, each independently
  ## either an arg or a prop. Mirrors the KDL grammar's interleaving
  ## of args and props within a node entries list.
  ##
  ## Note: KDL v2 requires that no entry follows children, but
  ## these events have no children block, so the rule is vacuously
  ## satisfied. The children-aware generator lands in F11.4.
  let nameStrat = identifiers()
  let argStrat = argEvents()
  let propStrat = propEvents()
  newStrategy[seq[GenEvent]](proc(src: var DataSource): seq[GenEvent] =
    let name = nameStrat.run(src)
    let n = int(toInt64(src.drawInteger(
      toInt128(0'i64), toInt128(maxEntries.int64), toInt128(0'i64))))
    result.add(GenEvent(kind: geNodeBegin, nodeName: name))
    for _ in 0 ..< n:
      let isProp = src.drawBoolean(0.5)
      result.add(if isProp: propStrat.run(src) else: argStrat.run(src))
    result.add(GenEvent(kind: geNodeEnd)))

proc nodeWithArgsEvents*(maxArgs = 6): Strategy[seq[GenEvent]] =
  ## F11.2 — node with 0..maxArgs typed args between NodeBegin and
  ## NodeEnd.
  let nameStrat = identifiers()
  let argStrat = argEvents()
  newStrategy[seq[GenEvent]](proc(src: var DataSource): seq[GenEvent] =
    let name = nameStrat.run(src)
    let n = int(toInt64(src.drawInteger(
      toInt128(0'i64), toInt128(maxArgs.int64), toInt128(0'i64))))
    result.add(GenEvent(kind: geNodeBegin, nodeName: name))
    for _ in 0 ..< n:
      result.add(argStrat.run(src))
    result.add(GenEvent(kind: geNodeEnd)))

proc nodeWithChildrenEvents*(maxDepth = 3,
                             maxEntries = 4,
                             maxChildren = 3): Strategy[seq[GenEvent]] =
  ## F11.4 — node optionally followed by a children block whose
  ## inner content is another bounded-depth node sequence. Built
  ## via `recursive` so proptest's choice-sequence engine bounds
  ## tree depth and shrinks toward the no-children base.
  ##
  ## KDL semantics enforced:
  ## - The children block (if present) immediately follows the
  ##   entries list and precedes NodeEnd
  ## - No entries after children (handled by ordering — entries are
  ##   emitted before the ChildrenBegin marker)
  ## - At most one real children block per node (no slashdash yet —
  ##   that lands in F11.6)
  let nameStrat = identifiers()
  let entryStrat = newStrategy[GenEvent](proc(src: var DataSource): GenEvent =
    if src.drawBoolean(0.5): propEvents().run(src) else: argEvents().run(src))

  proc leaf(): Strategy[seq[GenEvent]] =
    newStrategy[seq[GenEvent]](proc(src: var DataSource): seq[GenEvent] =
      let name = nameStrat.run(src)
      let nEntries = int(toInt64(src.drawInteger(
        toInt128(0'i64), toInt128(maxEntries.int64), toInt128(0'i64))))
      result.add(GenEvent(kind: geNodeBegin, nodeName: name))
      for _ in 0 ..< nEntries:
        result.add(entryStrat.run(src))
      result.add(GenEvent(kind: geNodeEnd)))

  proc extend(child: Strategy[seq[GenEvent]]): Strategy[seq[GenEvent]] =
    newStrategy[seq[GenEvent]](proc(src: var DataSource): seq[GenEvent] =
      let name = nameStrat.run(src)
      let nEntries = int(toInt64(src.drawInteger(
        toInt128(0'i64), toInt128(maxEntries.int64), toInt128(0'i64))))
      result.add(GenEvent(kind: geNodeBegin, nodeName: name))
      for _ in 0 ..< nEntries:
        result.add(entryStrat.run(src))
      # Bias toward including children at this depth — without it
      # the recursive strategy degenerates into mostly-leaves and
      # the property's coverage of nested structures suffers.
      let withChildren = src.drawBoolean(0.7)
      if withChildren:
        result.add(GenEvent(kind: geChildrenBegin))
        let nChildren = int(toInt64(src.drawInteger(
          toInt128(0'i64), toInt128(maxChildren.int64), toInt128(0'i64))))
        for _ in 0 ..< nChildren:
          result.add(child.run(src))
        result.add(GenEvent(kind: geChildrenEnd))
      result.add(GenEvent(kind: geNodeEnd)))

  recursive(leaf(), extend, maxDepth)
