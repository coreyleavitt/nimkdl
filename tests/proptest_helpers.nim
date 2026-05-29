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
    geSlashdashBegin
    geSlashdashEnd

  GenEvent* = object
    ## Span-free counterpart of `CursorEvent`. Carries only the data
    ## the substrate property tests need to compare across the
    ## emitter → cursor round trip.
    ##
    ## `anno` carries an optional `(type)` KDL annotation; empty
    ## string means "no annotation." Lives at the variant level so
    ## node-name, arg-value, and prop-value positions each get one
    ## (matching the emitter's push-proc `anno` parameter).
    case kind*: GenEventKind
    of geNodeBegin:
      nodeName*: string
      nodeAnno*: string
    of geArgString:
      argStr*: string
      argStrAnno*: string
    of geArgInt:
      argInt*: int64
      argIntAnno*: string
    of geArgFloat:
      argFloat*: float
      argFloatAnno*: string
    of geArgBool:
      argBool*: bool
      argBoolAnno*: string
    of geArgNull:
      argNullAnno*: string
    of gePropString:
      propStrKey*: string
      propStrVal*: string
      propStrAnno*: string
    of gePropInt:
      propIntKey*: string
      propIntVal*: int64
      propIntAnno*: string
    of gePropFloat:
      propFloatKey*: string
      propFloatVal*: float
      propFloatAnno*: string
    of gePropBool:
      propBoolKey*: string
      propBoolVal*: bool
      propBoolAnno*: string
    of gePropNull:
      propNullKey*: string
      propNullAnno*: string
    else: discard

proc pushGenEvent*(e: var BufferEmitter, ev: GenEvent) =
  ## Drive an emitter from a single GenEvent. Inverse of the
  ## cursor's emission; tests use this to materialize the generated
  ## sequence into bytes that then get parsed back through the
  ## cursor.
  case ev.kind
  of geNodeBegin:      e.pushNodeBegin(ev.nodeName, ev.nodeAnno)
  of geNodeEnd:        e.pushNodeEnd()
  of geArgString:      e.pushArgString(ev.argStr, ev.argStrAnno)
  of geArgInt:         e.pushArgInt(ev.argInt, ev.argIntAnno)
  of geArgFloat:       e.pushArgFloat(ev.argFloat, ev.argFloatAnno)
  of geArgBool:        e.pushArgBool(ev.argBool, ev.argBoolAnno)
  of geArgNull:        e.pushArgNull(ev.argNullAnno)
  of gePropString:     e.pushPropString(ev.propStrKey, ev.propStrVal, ev.propStrAnno)
  of gePropInt:        e.pushPropInt(ev.propIntKey, ev.propIntVal, ev.propIntAnno)
  of gePropFloat:      e.pushPropFloat(ev.propFloatKey, ev.propFloatVal, ev.propFloatAnno)
  of gePropBool:       e.pushPropBool(ev.propBoolKey, ev.propBoolVal, ev.propBoolAnno)
  of gePropNull:       e.pushPropNull(ev.propNullKey, ev.propNullAnno)
  of geChildrenBegin:  e.pushChildrenBegin()
  of geChildrenEnd:    e.pushChildrenEnd()
  of geSlashdashBegin: e.pushSlashdashBegin()
  of geSlashdashEnd:   e.pushSlashdashEnd()

# ---------------------------------------------------------------------------
# Generators
# ---------------------------------------------------------------------------

# Bareword-safe identifier strategy. Restricting to lower-case ASCII
# letters keeps every drawn name a valid KDL bareword so node/prop
# names never need quoting. Wider character sets land in later
# cycles once the simple cases are proven round-trip-clean.
proc identifiers*(minLen = 1, maxLen = 12): Strategy[string] =
  strings(intervals([(0x61'i32, 0x7a'i32)]), minLen, maxLen)

proc maybeAnno*(src: var DataSource, presenceProb = 0.3): string =
  ## Draw an optional `(type)` annotation. Returns empty string if
  ## absent. Annotations are bareword-safe identifiers for now;
  ## extending to quoted-string annotations rides on the same path
  ## once the simpler case is proven round-trip clean.
  if src.drawBoolean(presenceProb):
    identifiers(1, 8).run(src)
  else:
    ""

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

proc annotatedPropEvents*(): Strategy[GenEvent] =
  ## F11.5b — prop with key + value, value optionally annotated.
  ## Prop annotations attach to the VALUE position only (the key is
  ## a bareword and doesn't take an annotation per KDL spec).
  let keyStrat = identifiers(1, 8)
  let strVals = strings(0, 32)
  let intVals = integers(low(int64), high(int64))
  let floatVals = floats(-1e9, 1e9, allowNan = false)
  let boolVals = booleans()
  newStrategy[GenEvent](proc(src: var DataSource): GenEvent =
    let kindIdx = toInt64(src.drawInteger(
      toInt128(0'i64), toInt128(4'i64), toInt128(0'i64)))
    let key = keyStrat.run(src)
    let anno = maybeAnno(src)
    case kindIdx
    of 0: GenEvent(kind: gePropString, propStrKey: key,
                   propStrVal: strVals.run(src), propStrAnno: anno)
    of 1: GenEvent(kind: gePropInt, propIntKey: key,
                   propIntVal: intVals.run(src), propIntAnno: anno)
    of 2: GenEvent(kind: gePropFloat, propFloatKey: key,
                   propFloatVal: floatVals.run(src), propFloatAnno: anno)
    of 3: GenEvent(kind: gePropBool, propBoolKey: key,
                   propBoolVal: boolVals.run(src), propBoolAnno: anno)
    else: GenEvent(kind: gePropNull, propNullKey: key, propNullAnno: anno))

proc nodeWithAnnotatedEntriesEvents*(maxEntries = 6): Strategy[seq[GenEvent]] =
  ## F11.5 full — node optionally annotated + 0..maxEntries entries
  ## where each entry is an annotated arg or annotated prop.
  let nameStrat = identifiers()
  newStrategy[seq[GenEvent]](proc(src: var DataSource): seq[GenEvent] =
    let name = nameStrat.run(src)
    let nodeAnno = maybeAnno(src)
    let n = int(toInt64(src.drawInteger(
      toInt128(0'i64), toInt128(maxEntries.int64), toInt128(0'i64))))
    result.add(GenEvent(kind: geNodeBegin, nodeName: name, nodeAnno: nodeAnno))
    for _ in 0 ..< n:
      if src.drawBoolean(0.5):
        # Reuse the arg path with an anno
        let kindIdx = toInt64(src.drawInteger(
          toInt128(0'i64), toInt128(4'i64), toInt128(0'i64)))
        let anno = maybeAnno(src)
        let ev = case kindIdx
          of 0: GenEvent(kind: geArgString, argStr: strings(0, 32).run(src),
                         argStrAnno: anno)
          of 1: GenEvent(kind: geArgInt,
                         argInt: integers(low(int64), high(int64)).run(src),
                         argIntAnno: anno)
          of 2: GenEvent(kind: geArgFloat,
                         argFloat: floats(-1e9, 1e9, allowNan = false).run(src),
                         argFloatAnno: anno)
          of 3: GenEvent(kind: geArgBool, argBool: booleans().run(src),
                         argBoolAnno: anno)
          else: GenEvent(kind: geArgNull, argNullAnno: anno)
        result.add(ev)
      else:
        result.add(annotatedPropEvents().run(src))
    result.add(GenEvent(kind: geNodeEnd)))

proc nodeWithAnnotatedArgsEvents*(maxArgs = 6): Strategy[seq[GenEvent]] =
  ## F11.5 — node + typed args where node name and every arg value
  ## may carry an optional `(type)` annotation. Mirrors the KDL
  ## grammar's annotation positions on the value-bearing emitter
  ## entry points.
  let nameStrat = identifiers()
  let argStrings = strings(0, 32)
  let argInts = integers(low(int64), high(int64))
  let argFloats = floats(-1e9, 1e9, allowNan = false)
  let argBools = booleans()
  newStrategy[seq[GenEvent]](proc(src: var DataSource): seq[GenEvent] =
    let name = nameStrat.run(src)
    let nodeAnno = maybeAnno(src)
    let n = int(toInt64(src.drawInteger(
      toInt128(0'i64), toInt128(maxArgs.int64), toInt128(0'i64))))
    result.add(GenEvent(kind: geNodeBegin, nodeName: name, nodeAnno: nodeAnno))
    for _ in 0 ..< n:
      let kindIdx = toInt64(src.drawInteger(
        toInt128(0'i64), toInt128(4'i64), toInt128(0'i64)))
      let anno = maybeAnno(src)
      result.add:
        case kindIdx
        of 0: GenEvent(kind: geArgString, argStr: argStrings.run(src),
                       argStrAnno: anno)
        of 1: GenEvent(kind: geArgInt, argInt: argInts.run(src),
                       argIntAnno: anno)
        of 2: GenEvent(kind: geArgFloat, argFloat: argFloats.run(src),
                       argFloatAnno: anno)
        of 3: GenEvent(kind: geArgBool, argBool: argBools.run(src),
                       argBoolAnno: anno)
        else: GenEvent(kind: geArgNull, argNullAnno: anno)
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

proc nodeWithSlashdashEntryEvents*(maxEntries = 6): Strategy[seq[GenEvent]] =
  ## F11.6 tracer — node whose entries each have an independent
  ## chance of being slashdashed. Cursor will surface
  ## ceSlashdashBegin / ceSlashdashEnd around each wrapped entry.
  let nameStrat = identifiers()
  let argStrat = argEvents()
  let propStrat = propEvents()
  newStrategy[seq[GenEvent]](proc(src: var DataSource): seq[GenEvent] =
    let name = nameStrat.run(src)
    let n = int(toInt64(src.drawInteger(
      toInt128(0'i64), toInt128(maxEntries.int64), toInt128(0'i64))))
    result.add(GenEvent(kind: geNodeBegin, nodeName: name))
    for _ in 0 ..< n:
      let slashed = src.drawBoolean(0.4)
      let entry = if src.drawBoolean(0.5):
        propStrat.run(src)
      else:
        argEvents().run(src)
      if slashed:
        result.add(GenEvent(kind: geSlashdashBegin))
        result.add(entry)
        result.add(GenEvent(kind: geSlashdashEnd))
      else:
        result.add(entry)
    result.add(GenEvent(kind: geNodeEnd)))

proc nodeWithSlashdashAllPositionsEvents*(
    maxDepth = 3, maxEntries = 4, maxChildren = 3): Strategy[seq[GenEvent]] =
  ## F11.6 full — every slashdash position exercised:
  ## - entry-position: each arg/prop independently
  ## - node-position: each child node independently
  ## - children-position: the {...} block itself
  let nameStrat = identifiers()
  let argStrat = argEvents()
  let propStrat = propEvents()

  proc emitEntries(src: var DataSource, dest: var seq[GenEvent]) =
    let n = int(toInt64(src.drawInteger(
      toInt128(0'i64), toInt128(maxEntries.int64), toInt128(0'i64))))
    for _ in 0 ..< n:
      let slashed = src.drawBoolean(0.3)
      let entry = if src.drawBoolean(0.5):
        propStrat.run(src)
      else:
        argStrat.run(src)
      if slashed:
        dest.add(GenEvent(kind: geSlashdashBegin))
        dest.add(entry)
        dest.add(GenEvent(kind: geSlashdashEnd))
      else:
        dest.add(entry)

  proc leaf(): Strategy[seq[GenEvent]] =
    newStrategy[seq[GenEvent]](proc(src: var DataSource): seq[GenEvent] =
      result.add(GenEvent(kind: geNodeBegin, nodeName: nameStrat.run(src)))
      emitEntries(src, result)
      result.add(GenEvent(kind: geNodeEnd)))

  proc extend(child: Strategy[seq[GenEvent]]): Strategy[seq[GenEvent]] =
    newStrategy[seq[GenEvent]](proc(src: var DataSource): seq[GenEvent] =
      result.add(GenEvent(kind: geNodeBegin, nodeName: nameStrat.run(src)))
      emitEntries(src, result)
      let withChildren = src.drawBoolean(0.7)
      if withChildren:
        let slashedBlock = src.drawBoolean(0.2)
        if slashedBlock:
          result.add(GenEvent(kind: geSlashdashBegin))
        result.add(GenEvent(kind: geChildrenBegin))
        let nChildren = int(toInt64(src.drawInteger(
          toInt128(0'i64), toInt128(maxChildren.int64), toInt128(0'i64))))
        for _ in 0 ..< nChildren:
          let slashedNode = src.drawBoolean(0.2)
          let childEvs = child.run(src)
          if slashedNode:
            result.add(GenEvent(kind: geSlashdashBegin))
            result.add(childEvs)
            result.add(GenEvent(kind: geSlashdashEnd))
          else:
            result.add(childEvs)
        result.add(GenEvent(kind: geChildrenEnd))
        if slashedBlock:
          result.add(GenEvent(kind: geSlashdashEnd))
      result.add(GenEvent(kind: geNodeEnd)))

  recursive(leaf(), extend, maxDepth)

proc topLevelEvents*(maxTopNodes = 5,
                     maxDepth = 3,
                     maxEntries = 4,
                     maxChildren = 3): Strategy[seq[GenEvent]] =
  ## F11.7 — top-level document: 0..maxTopNodes sibling trees, each
  ## itself a depth-bounded `nodeWithChildrenEvents`. Exercises the
  ## cursor's csTopLevel state transitions across siblings.
  let inner = nodeWithChildrenEvents(maxDepth, maxEntries, maxChildren)
  newStrategy[seq[GenEvent]](proc(src: var DataSource): seq[GenEvent] =
    let n = int(toInt64(src.drawInteger(
      toInt128(0'i64), toInt128(maxTopNodes.int64), toInt128(0'i64))))
    for _ in 0 ..< n:
      result.add(inner.run(src)))
