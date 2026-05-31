## Stage F5 / F12 / F13 — substrate-level properties.
##
## - **P3: cursor safety under arbitrary bytes.** Random byte input
##   never crashes, always terminates in ceEof or ceError. The
##   strongest robustness claim a parser substrate can make.
##
## - **P1: cursor ↔ emitter event round-trip** (lands in F12, needs
##   F11 grammar-aware generator).
##
## - **P2: source → events → bytes → events idempotence** (lands in
##   F13, needs F11).
##
## Gated by NKDL_PROPTEST=1.

import std/[math, unittest]

import proptest

import ../src/cursor
import ../src/doc_build  # tokenAsString — decode token payload back to string
import ../src/emitter
import ../src/intern
import ../src/lexer
import ../src/numlit    # decodeIntFromToken / decodeFloatFromToken
import ../src/spans     # Result.isOk / .get

import ./proptest_helpers

proc driveToEof(src: string): bool =
  ## Drive a cursor over `src`. Returns true iff the cursor reached
  ## ceEof or emitted a ceError without raising. The strong claim is
  ## "completes without raising" — if any exception escapes, proptest
  ## fails the property.
  var interner = initInterner()
  var sref: ref TokenStream
  new(sref)
  sref[] = lex(src)
  var c = initStringCursor(addr sref[], src)
  var steps = 0
  while true:
    let ev = advance(c)
    inc steps
    # Bounded-step guard: a cursor that emits more than ~10× the
    # input length per byte is almost certainly in a stall pattern.
    # If we ever trip this, it's a bug — not a property failure.
    if steps > 10 + src.len * 50:
      doAssert false, "cursor did not converge on input of length " &
                      $src.len
    if ev.kind == ceEof: return true
    # ceError is fine for arbitrary bytes; the property is only that
    # the cursor terminates without raising. Single-shot mode is the
    # default and ceError halts the stream.

proc seekIdentityHolds(src: string): bool =
  ## For every checkpoint position, advancing-to-end then seeking-back-
  ## and-replaying must reproduce the identical event-kind stream. Guards
  ## review #2: Checkpoint must snapshot ALL mutable cursor state (it had
  ## dropped nodeFrames/childrenIsSlashdashed, so a mid-node seek lost the
  ## "this node has children" flags and accepted illegal trailing entries).
  var sref: ref TokenStream
  new(sref)
  sref[] = lex(src)
  var probe = initStringCursor(addr sref[], src)
  var n = 0
  while true:
    let e = advance(probe)
    inc n
    if e.kind in {ceEof, ceError}: break
  for k in 0 ..< n:
    var c = initStringCursor(addr sref[], src)
    for i in 0 ..< k: discard advance(c)
    let ck = c.pos()
    var direct: seq[CursorEventKind]
    while true:
      let e = advance(c)
      direct.add(e.kind)
      if e.kind in {ceEof, ceError}: break
    c.seek(ck)
    var replay: seq[CursorEventKind]
    while true:
      let e = advance(c)
      replay.add(e.kind)
      if e.kind in {ceEof, ceError}: break
    if direct != replay: return false
  true

suite "P3 — cursor safety on arbitrary bytes":

  property "cursor terminates without raising on any string input":
    with Settings(maxExamples: 300, testId: "p3-printable")
    given src in strings(0, 500)
    ensure driveToEof(src)

  property "cursor terminates on KDL-syntax-rich byte alphabets":
    # Bias toward bytes that drive lex/grammar special paths:
    # control codes (newlines, slashdash precursors), brackets,
    # slashes, quotes, hash, equals, parens, semicolons, dot.
    with Settings(maxExamples: 500, testId: "p3-kdl-rich")
    given src in strings(intervals([
      (0x09'i32, 0x0d'i32),
      (0x20'i32, 0x7e'i32),
      (0x00a0'i32, 0x00ff'i32)
    ]), 0, 500)
    ensure driveToEof(src)

  property "seek to any checkpoint replays the identical continuation":
    # pos()/seek() must snapshot the FULL mutable cursor state. Fuzzes
    # KDL-rich bytes; for each, checks identity at every checkpoint
    # position. (Review #2 — Checkpoint had dropped two state fields.)
    with Settings(maxExamples: 400, testId: "p3-seek-identity")
    given src in strings(intervals([
      (0x09'i32, 0x0d'i32),
      (0x20'i32, 0x7e'i32),
      (0x00a0'i32, 0x00ff'i32)
    ]), 0, 200)
    ensure seekIdentityHolds(src)

# ---------------------------------------------------------------------------
# P1 — cursor ↔ emitter event round-trip
# ---------------------------------------------------------------------------

proc tokToGenArg(tok: Token, anno: string,
                 stream: TokenStream, source: string): GenEvent =
  ## Decode a cursor-arg token back into the GenEvent payload shape.
  ## `anno` is the resolved annotation bytes (empty string == none).
  case tok.kind
  of tkString, tkRawString:
    GenEvent(kind: geArgString,
             argStr: tokenAsString(tok, stream, source),
             argStrAnno: anno)
  of tkNumber:
    let asInt = decodeIntFromToken(numberText(source, tok.span), tok.numBase, tok.span)
    if asInt.isOk:
      GenEvent(kind: geArgInt, argInt: asInt.get, argIntAnno: anno)
    else:
      let asFloat = decodeFloatFromToken(numberText(source, tok.span), tok.span)
      doAssert asFloat.isOk, "number token decoded as neither int nor float"
      GenEvent(kind: geArgFloat, argFloat: asFloat.get, argFloatAnno: anno)
  of tkKeyword:
    case tok.keyword
    of kwTrue:  GenEvent(kind: geArgBool, argBool: true, argBoolAnno: anno)
    of kwFalse: GenEvent(kind: geArgBool, argBool: false, argBoolAnno: anno)
    of kwNull:  GenEvent(kind: geArgNull, argNullAnno: anno)
    of kwInf:   GenEvent(kind: geArgFloat, argFloat: Inf, argFloatAnno: anno)
    of kwNegInf: GenEvent(kind: geArgFloat, argFloat: NegInf, argFloatAnno: anno)
    of kwNan:   GenEvent(kind: geArgFloat, argFloat: NaN, argFloatAnno: anno)
  of tkIdent:
    GenEvent(kind: geArgString,
             argStr: tokenAsString(tok, stream, source),
             argStrAnno: anno)
  else:
    doAssert false, "unexpected arg token kind"
    GenEvent(kind: geArgNull)

proc cursorEventsToGen(src: string): seq[GenEvent] =
  ## Drive cursor over `src`, decode each emitted event back to
  ## the span-free GenEvent shape used by the property comparator.
  var interner = initInterner()
  var sref: ref TokenStream
  new(sref)
  sref[] = lex(src)
  var c = initStringCursor(addr sref[], src)
  proc tokTextOrEmpty(idx: int): string =
    if idx < 0: "" else: tokenAsString(sref.tokens[idx], sref[], src)
  while true:
    let ev = advance(c)
    case ev.kind
    of ceNodeBegin:
      let tok = sref.tokens[ev.nodeNameTok]
      result.add(GenEvent(kind: geNodeBegin,
                          nodeName: tokenAsString(tok, sref[], src),
                          nodeAnno: tokTextOrEmpty(ev.nodeAnnoTok)))
    of ceArg:
      let tok = sref.tokens[ev.argTok]
      let anno = tokTextOrEmpty(ev.argAnnoTok)
      result.add(tokToGenArg(tok, anno, sref[], src))
    of ceProp:
      let keyTok = sref.tokens[ev.propKeyTok]
      let valTok = sref.tokens[ev.propValueTok]
      let key = tokenAsString(keyTok, sref[], src)
      let anno = tokTextOrEmpty(ev.propAnnoTok)
      let argShape = tokToGenArg(valTok, anno, sref[], src)
      result.add:
        case argShape.kind
        of geArgString: GenEvent(kind: gePropString,
                                 propStrKey: key, propStrVal: argShape.argStr,
                                 propStrAnno: anno)
        of geArgInt:    GenEvent(kind: gePropInt,
                                 propIntKey: key, propIntVal: argShape.argInt,
                                 propIntAnno: anno)
        of geArgFloat:  GenEvent(kind: gePropFloat,
                                 propFloatKey: key, propFloatVal: argShape.argFloat,
                                 propFloatAnno: anno)
        of geArgBool:   GenEvent(kind: gePropBool,
                                 propBoolKey: key, propBoolVal: argShape.argBool,
                                 propBoolAnno: anno)
        of geArgNull:   GenEvent(kind: gePropNull, propNullKey: key,
                                 propNullAnno: anno)
        else:
          doAssert false, "unexpected prop value shape"
          GenEvent(kind: gePropNull, propNullKey: key, propNullAnno: anno)
    of ceChildrenBegin:   result.add(GenEvent(kind: geChildrenBegin))
    of ceChildrenEnd:     result.add(GenEvent(kind: geChildrenEnd))
    of ceNodeEnd:         result.add(GenEvent(kind: geNodeEnd))
    of ceSlashdashBegin:  result.add(GenEvent(kind: geSlashdashBegin))
    of ceSlashdashEnd:    result.add(GenEvent(kind: geSlashdashEnd))
    of ceEof: return
    of ceError:
      doAssert false, "cursor rejected emitter output — P1 violated"

func eventEqual(a, b: GenEvent): bool =
  ## Span-free GenEvent equality. NaN-safe (Inf equals Inf; NaN
  ## equals NaN by representation, since proptest's float strategy
  ## doesn't produce NaN by default and KDL parses `#nan` → NaN
  ## with the same bit pattern). Annotations are compared bytewise.
  if a.kind != b.kind: return false
  case a.kind
  of geNodeBegin:
    a.nodeName == b.nodeName and a.nodeAnno == b.nodeAnno
  of geNodeEnd, geChildrenBegin, geChildrenEnd,
     geSlashdashBegin, geSlashdashEnd: true
  of geArgNull:
    a.argNullAnno == b.argNullAnno
  of geArgString:
    a.argStr == b.argStr and a.argStrAnno == b.argStrAnno
  of geArgInt:
    a.argInt == b.argInt and a.argIntAnno == b.argIntAnno
  of geArgFloat:
    ((a.argFloat.classify == fcNaN and b.argFloat.classify == fcNaN) or
     a.argFloat == b.argFloat) and
    a.argFloatAnno == b.argFloatAnno
  of geArgBool:
    a.argBool == b.argBool and a.argBoolAnno == b.argBoolAnno
  of gePropString:
    a.propStrKey == b.propStrKey and a.propStrVal == b.propStrVal and
    a.propStrAnno == b.propStrAnno
  of gePropInt:
    a.propIntKey == b.propIntKey and a.propIntVal == b.propIntVal and
    a.propIntAnno == b.propIntAnno
  of gePropFloat:
    a.propFloatKey == b.propFloatKey and
    ((a.propFloatVal.classify == fcNaN and b.propFloatVal.classify == fcNaN) or
     a.propFloatVal == b.propFloatVal) and
    a.propFloatAnno == b.propFloatAnno
  of gePropBool:
    a.propBoolKey == b.propBoolKey and a.propBoolVal == b.propBoolVal and
    a.propBoolAnno == b.propBoolAnno
  of gePropNull:
    a.propNullKey == b.propNullKey and a.propNullAnno == b.propNullAnno

func eventSeqEqual(a, b: seq[GenEvent]): bool =
  if a.len != b.len: return false
  for i in 0 ..< a.len:
    if not eventEqual(a[i], b[i]): return false
  true

suite "P1 — cursor ↔ emitter event round-trip (F12)":

  property "bare-node generated sequence round-trips payload-equally":
    with Settings(maxExamples: 200, testId: "p1-bare-node")
    given events in bareNodeEvents()
    var emit = newBufferEmitter()
    for ev in events: pushGenEvent(emit, ev)
    let bytes = emit.finish()
    let observed = cursorEventsToGen(bytes)
    ensure eventSeqEqual(observed, events)

  property "node-with-typed-args sequence round-trips payload-equally":
    # NodeBegin → 0..N typed args (string/int/float/bool/null) →
    # NodeEnd. Strict payload-aware comparator: every arg's decoded
    # value must match the generator's draw exactly.
    with Settings(maxExamples: 200, testId: "p1-node-args")
    given events in nodeWithArgsEvents()
    var emit = newBufferEmitter()
    for ev in events: pushGenEvent(emit, ev)
    let bytes = emit.finish()
    let observed = cursorEventsToGen(bytes)
    ensure eventSeqEqual(observed, events)

  property "node-with-mixed-entries sequence round-trips payload-equally":
    # NodeBegin → arbitrarily-interleaved args + props → NodeEnd.
    # Exercises the cursor's per-entry kind-discrimination and the
    # emitter's prop key bareword-vs-quoted decision against the
    # generator's draws.
    with Settings(maxExamples: 200, testId: "p1-node-entries")
    given events in nodeWithEntriesEvents()
    var emit = newBufferEmitter()
    for ev in events: pushGenEvent(emit, ev)
    let bytes = emit.finish()
    let observed = cursorEventsToGen(bytes)
    ensure eventSeqEqual(observed, events)

  property "annotated nodes + args round-trip payload-equally":
    # F11.5 — every node-name and every arg-value may carry a
    # `(type)` annotation. The comparator's anno-bytes equality
    # asserts the cursor's resolved annotation token matches what
    # the generator emitted via the emitter's anno parameter.
    with Settings(maxExamples: 200, testId: "p1-annotated-args")
    given events in nodeWithAnnotatedArgsEvents()
    var emit = newBufferEmitter()
    for ev in events: pushGenEvent(emit, ev)
    let bytes = emit.finish()
    let observed = cursorEventsToGen(bytes)
    ensure eventSeqEqual(observed, events)

  property "annotated mixed entries (args + props) round-trip payload-equally":
    # F11.5b — exercises annotations on prop values in addition to
    # args + node names. Prop keys themselves are never annotated
    # per KDL spec.
    with Settings(maxExamples: 200, testId: "p1-annotated-entries")
    given events in nodeWithAnnotatedEntriesEvents()
    var emit = newBufferEmitter()
    for ev in events: pushGenEvent(emit, ev)
    let bytes = emit.finish()
    let observed = cursorEventsToGen(bytes)
    ensure eventSeqEqual(observed, events)

  property "recursive children block sequence round-trips payload-equally":
    # Bounded-depth tree of nodes with optional children blocks.
    # The most expressive shape in the substrate: every nesting
    # boundary, every entry-then-children ordering rule, every
    # children-end → node-end transition gets exercised across
    # many draws.
    with Settings(maxExamples: 200, testId: "p1-recursive-tree")
    given events in nodeWithChildrenEvents()
    var emit = newBufferEmitter()
    for ev in events: pushGenEvent(emit, ev)
    let bytes = emit.finish()
    let observed = cursorEventsToGen(bytes)
    ensure eventSeqEqual(observed, events)

  property "slashdash at all three positions round-trips payload-equally":
    # F11.6 full — exercises entry-position, node-position, AND
    # children-block-position slashdash simultaneously across a
    # depth-bounded tree. The substrate's most demanding round-trip
    # test: every slashdash position the cursor recognizes must
    # surface symmetrically from emitted bytes.
    with Settings(maxExamples: 200, testId: "p1-slashdash-all")
    given events in nodeWithSlashdashAllPositionsEvents()
    var emit = newBufferEmitter()
    for ev in events: pushGenEvent(emit, ev)
    let bytes = emit.finish()
    let observed = cursorEventsToGen(bytes)
    ensure eventSeqEqual(observed, events)

  property "slashdashed entries surface as ceSlashdashBegin/End markers":
    # F11.6 tracer — entry-position slashdash. Each arg/prop has a
    # ~40% chance of being wrapped in `/-`. The cursor must surface
    # the slashdash brackets so the generator's [SlashdashBegin,
    # entry, SlashdashEnd] sequence is recovered exactly.
    with Settings(maxExamples: 200, testId: "p1-slashdash-entry")
    given events in nodeWithSlashdashEntryEvents()
    var emit = newBufferEmitter()
    for ev in events: pushGenEvent(emit, ev)
    let bytes = emit.finish()
    let observed = cursorEventsToGen(bytes)
    ensure eventSeqEqual(observed, events)

  property "top-level multi-node document round-trips payload-equally":
    # F11.7 — 0..N sibling trees at the top level. Adds the
    # csTopLevel state-transition dimension: each NodeEnd at the
    # top must hand off cleanly to the next NodeBegin (or to
    # ceEof).
    with Settings(maxExamples: 150, testId: "p1-top-level")
    given events in topLevelEvents()
    var emit = newBufferEmitter()
    for ev in events: pushGenEvent(emit, ev)
    let bytes = emit.finish()
    let observed = cursorEventsToGen(bytes)
    ensure eventSeqEqual(observed, events)

# ---------------------------------------------------------------------------
# P2 — source → events → bytes → events idempotence (F13)
# ---------------------------------------------------------------------------

suite "P2 — events → bytes → events idempotence":

  property "bytes derived from generated tree are idempotent across re-emit":
    # B = emit(E). Then E' = cursor(B). Then B' = emit(E'). Cursor(B')
    # must agree with cursor(B) at the event level.
    #
    # This is the canonical-form idempotence claim: any bytes the
    # emitter produces from cursor-observed events are themselves
    # already canonical-form, so a second round trip is a fixed
    # point.
    with Settings(maxExamples: 200, testId: "p2-idempotence")
    given events in nodeWithChildrenEvents()
    var emit = newBufferEmitter()
    for ev in events: pushGenEvent(emit, ev)
    let bytes1 = emit.finish()
    let events1 = cursorEventsToGen(bytes1)
    var emit2 = newBufferEmitter()
    for ev in events1: pushGenEvent(emit2, ev)
    let bytes2 = emit2.finish()
    let events2 = cursorEventsToGen(bytes2)
    ensure eventSeqEqual(events1, events2)
