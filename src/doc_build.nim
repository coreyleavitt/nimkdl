## doc_build — Cat 3 IN consumer.
##
## Walk cursor events and fold them into a `KdlDoc`. The inverse of
## `doc_emit` (which walks a KdlDoc and pushes events into an
## emitter). Together they're the round-trip pair for the Cat 3
## surface.
##
## Hosted in its own module — parallel to `doc_emit.nim` — instead of
## being baked into `cursor.nim`. The cursor primitive is one
## responsibility (event production); this module is another
## (one specific Cat 3 consumer of that production). Splitting them
## keeps cursor.nim focused on the substrate and removes the
## historical-asymmetric placement vs. doc_emit.
##
## There's a *different* `buildDoc` in `grammar.nim` (the reference-
## interpreter's parse-tree folder); the namespace collision was
## confusing and the grammar version has been renamed
## `buildDocFromParseTree` to disambiguate.

import ./ast
import ./cursor
import ./fnv
import ./hashing
import ./intern
import ./lexer
import ./numlit
import ./reserved
import ./spans

proc tokenAsString*(tok: Token, stream: TokenStream, source: string): string =
  ## Resolve a token's logical text content. For tkIdent, returns the
  ## bareword bytes from source. For tkString / tkRawString, returns
  ## the unescaped payload from the lexer's side tables. For other
  ## kinds, returns the source bytes (rarely used).
  case tok.kind
  of tkString:    stream.stringPayloads[tok.strIdx]
  of tkRawString: stream.rawStringPayloads[tok.rawIdx]
  else:
    let s = int(tok.span.offset)
    let f = int(tok.span.endOffset) - 1
    source[s .. f]

proc buildValueFromTok(tok: Token, stream: TokenStream, source: string):
    Result[KdlValue, ParseError] {.noSideEffect.} =
  ## Token → KdlValue. Mirrors doc_builder.buildValue line-for-line so
  ## the cursor-fold produces semantically-equivalent values.
  case tok.kind
  of tkString:
    ok[KdlValue, ParseError](
      newStringValue(stream.stringPayloads[tok.strIdx], tok.span))
  of tkRawString:
    ok[KdlValue, ParseError](
      newStringValue(stream.rawStringPayloads[tok.rawIdx], tok.span))
  of tkKeyword:
    let v = case tok.keyword
      of kwTrue:   newBoolValue(true, tok.span)
      of kwFalse:  newBoolValue(false, tok.span)
      of kwNull:   newNullValue(tok.span)
      of kwInf:    newFloatValue(Inf, tok.span)
      of kwNegInf: newFloatValue(NegInf, tok.span)
      of kwNan:    newFloatValue(NaN, tok.span)
    ok[KdlValue, ParseError](v)
  of tkNumber:
    let n = stream.numberPayloads[tok.numIdx]
    if looksLikeFloat(n):
      let fRes = decodeFloatFromToken(n, tok.span)
      if fRes.isErr: return err[KdlValue, ParseError](fRes.getErr)
      ok[KdlValue, ParseError](newFloatValue(fRes.get, tok.span))
    else:
      let iRes = decodeIntPromoting(n, tok.span)
      if iRes.isErr: return err[KdlValue, ParseError](iRes.getErr)
      let d = iRes.get
      let v = if d.fits64: newIntValue(d.intVal, tok.span)
              else: newBigIntValue(d.bigHi, d.bigLo, d.negative, tok.span)
      ok[KdlValue, ParseError](v)
  of tkIdent:
    let s = tok.span.start.offset
    let f = tok.span.finish.offset - 1
    ok[KdlValue, ParseError](newStringValue(source[s .. f], tok.span))
  else:
    err[KdlValue, ParseError](initError(peParseExpected, tok.span,
      "unsupported value token kind"))

proc buildDoc*(c: var StringCursor, sourcePath = "<input>",
               preserveFormat: bool = false):
    Result[KdlDoc, ParseError] {.noSideEffect.} =
  ## Cat 3 consumer: fold cursor events into a KdlDoc using an explicit
  ## `seq[KdlNode]` stack. Replaces the visitor-protocol DocBuilder.
  ## On ceError returns Err; consumer can choose accumulating mode +
  ## buildDocAll for multi-error reporting.
  var doc = newDoc(sourcePath)
  doc.sourceText = c.source
  doc.preserveFormat = preserveFormat
  var stack: seq[KdlNode] = @[]
  var childHashes: seq[seq[Hash128]] = @[]
  var slashdashDepth = 0
  while true:
    let ev = advance(c)
    # Inside a slashdash bracket, all AST emission is suppressed;
    # we just track Begin/End nesting to find the matching close.
    if slashdashDepth > 0:
      case ev.kind
      of ceSlashdashBegin: inc slashdashDepth
      of ceSlashdashEnd:   dec slashdashDepth
      of ceError: return err[KdlDoc, ParseError](ev.err)
      of ceEof:
        # Unbalanced — cursor should not normally produce this.
        doc.parseTopLevelCount = int32(doc.nodes.len)
        return ok[KdlDoc, ParseError](doc)
      else: discard
      continue
    case ev.kind
    of ceNodeBegin:
      let nameHandle = doc.interner.intern(tokenAsString(c.stream[].tokens[ev.nodeNameTok], c.stream[], c.source))
      var typeAnno = InvalidInterned
      if ev.nodeAnnoTok != -1:
        typeAnno = doc.interner.intern(tokenAsString(c.stream[].tokens[ev.nodeAnnoTok], c.stream[], c.source))
      # For tagged nodes, extend span backwards to cover the `(` so
      # the doc-level encoder walk's inter-node trivia doesn't dup
      # the tag prefix (see commit 9ee8e38).
      var headStart = ev.span.start
      if ev.nodeAnnoTok != -1:
        let lparenTok = c.stream[].tokens[ev.nodeAnnoTok - 1]
        headStart = lparenTok.span.start
      let headEnd = ev.span.finish
      stack.add(KdlNode(name: nameHandle, typeAnnotation: typeAnno,
                        entries: @[], children: @[],
                        span: initSpan(headStart, headEnd),
                        headLen: uint32(headEnd.offset - headStart.offset)))
      if preserveFormat:
        childHashes.add(@[])
    of ceArg:
      let tok = c.stream[].tokens[ev.argTok]
      let vRes = buildValueFromTok(tok, c.stream[], c.source)
      if vRes.isErr: return err[KdlDoc, ParseError](vRes.getErr)
      var val = vRes.get
      if ev.argAnnoTok != -1:
        let annoStr = tokenAsString(c.stream[].tokens[ev.argAnnoTok], c.stream[], c.source)
        val.typeAnnotation = doc.interner.intern(annoStr)
        let rcheck = validateReserved(annoStr, val)
        if rcheck.isErr: return err[KdlDoc, ParseError](rcheck.getErr)
      # Entry span covers the full entry: `(` of annotation through
      # value token finish. Matches visitor protocol's entrySpan.
      var entryStart = tok.span.start
      if ev.argAnnoTok != -1:
        entryStart = c.stream[].tokens[ev.argAnnoTok - 1].span.start
      let entrySpan = initSpan(entryStart, tok.span.finish)
      var entry = KdlEntry(kind: keArgument, argValue: val, span: entrySpan)
      if preserveFormat:
        entry.parseHash = hashEntry(entry, doc.interner)
      if stack.len > 0:
        stack[^1].entries.add(entry)
    of ceProp:
      let key = doc.interner.intern(tokenAsString(c.stream[].tokens[ev.propKeyTok], c.stream[], c.source))
      let keyTok = c.stream[].tokens[ev.propKeyTok]
      let valTok = c.stream[].tokens[ev.propValueTok]
      let vRes = buildValueFromTok(valTok, c.stream[], c.source)
      if vRes.isErr: return err[KdlDoc, ParseError](vRes.getErr)
      var val = vRes.get
      if ev.propAnnoTok != -1:
        let annoStr = tokenAsString(c.stream[].tokens[ev.propAnnoTok], c.stream[], c.source)
        val.typeAnnotation = doc.interner.intern(annoStr)
        let rcheck = validateReserved(annoStr, val)
        if rcheck.isErr: return err[KdlDoc, ParseError](rcheck.getErr)
      # Repeated prop keys: later-wins.
      var i = 0
      while i < stack[^1].entries.len:
        let e = stack[^1].entries[i]
        if e.kind == keProperty and e.propName == key:
          stack[^1].entries.delete(i)
        else: inc i
      # Entry span covers key start to value finish.
      let entrySpan = initSpan(keyTok.span.start, valTok.span.finish)
      var entry = KdlEntry(kind: keProperty,
                           propName: key, propValue: val, span: entrySpan)
      if preserveFormat:
        entry.parseHash = hashEntry(entry, doc.interner)
      if stack.len > 0:
        stack[^1].entries.add(entry)
    of ceChildrenBegin, ceChildrenEnd:
      discard  # node nesting handled by Begin/End node pairing
    of ceNodeEnd:
      if stack.len == 0: continue  # stray NodeEnd from cursor recovery
      var n = stack.pop()
      n.span = initSpan(n.span.start, ev.span.finish)
      if preserveFormat and childHashes.len > 0:
        let ch = childHashes.pop()
        n.parseHash = hashNodeFromChildHashes(n, doc.interner, ch)
      n.parseEntryCount = int32(n.entries.len)
      n.parseChildCount = int32(n.children.len)
      if stack.len == 0:
        doc.nodes.add(n)
      else:
        let h = n.parseHash
        stack[^1].children.add(n)
        if preserveFormat:
          childHashes[^1].add(h)
    of ceSlashdashBegin:
      inc slashdashDepth
    of ceSlashdashEnd:
      discard  # only reachable when starting depth was 0 (mid-emission close); skip
    of ceEof:
      doc.parseTopLevelCount = int32(doc.nodes.len)
      return ok[KdlDoc, ParseError](doc)
    of ceError:
      return err[KdlDoc, ParseError](ev.err)

proc buildDocAll*(c: var StringCursor, sourcePath = "<input>",
                  preserveFormat: bool = false):
    tuple[doc: KdlDoc, errors: seq[ParseError]] {.noSideEffect.} =
  ## Accumulating-mode variant. Cursor must be in cmAccumulating. Each
  ## ceError is collected; the cursor recovers and emission continues.
  ## Returned doc is partial — holds whatever nodes the recovered
  ## parses produced.
  var doc = newDoc(sourcePath)
  doc.sourceText = c.source
  doc.preserveFormat = preserveFormat
  var stack: seq[KdlNode] = @[]
  var childHashes: seq[seq[Hash128]] = @[]
  var slashdashDepth = 0
  while true:
    let ev = advance(c)
    if slashdashDepth > 0:
      case ev.kind
      of ceSlashdashBegin: inc slashdashDepth
      of ceSlashdashEnd:   dec slashdashDepth
      of ceError:
        result.errors.add(ev.err)
        # On error, drop any open slashdash brackets — recovery clears them.
        slashdashDepth = 0
      of ceEof: break
      else: discard
      continue
    case ev.kind
    of ceNodeBegin:
      let nameHandle = doc.interner.intern(tokenAsString(c.stream[].tokens[ev.nodeNameTok], c.stream[], c.source))
      var typeAnno = InvalidInterned
      if ev.nodeAnnoTok != -1:
        typeAnno = doc.interner.intern(tokenAsString(c.stream[].tokens[ev.nodeAnnoTok], c.stream[], c.source))
      var headStart = ev.span.start
      if ev.nodeAnnoTok != -1:
        let lparenTok = c.stream[].tokens[ev.nodeAnnoTok - 1]
        headStart = lparenTok.span.start
      let headEnd = ev.span.finish
      stack.add(KdlNode(name: nameHandle, typeAnnotation: typeAnno,
                        entries: @[], children: @[],
                        span: initSpan(headStart, headEnd),
                        headLen: uint32(headEnd.offset - headStart.offset)))
      if preserveFormat:
        childHashes.add(@[])
    of ceArg:
      let tok = c.stream[].tokens[ev.argTok]
      let vRes = buildValueFromTok(tok, c.stream[], c.source)
      if vRes.isErr:
        result.errors.add(vRes.getErr)
        continue
      var val = vRes.get
      if ev.argAnnoTok != -1:
        let annoStr = tokenAsString(c.stream[].tokens[ev.argAnnoTok], c.stream[], c.source)
        val.typeAnnotation = doc.interner.intern(annoStr)
        let rcheck = validateReserved(annoStr, val)
        if rcheck.isErr:
          result.errors.add(rcheck.getErr)
          continue
      var entryStart = tok.span.start
      if ev.argAnnoTok != -1:
        entryStart = c.stream[].tokens[ev.argAnnoTok - 1].span.start
      let entrySpan = initSpan(entryStart, tok.span.finish)
      var entry = KdlEntry(kind: keArgument, argValue: val, span: entrySpan)
      if preserveFormat:
        entry.parseHash = hashEntry(entry, doc.interner)
      if stack.len > 0:
        stack[^1].entries.add(entry)
    of ceProp:
      let key = doc.interner.intern(tokenAsString(c.stream[].tokens[ev.propKeyTok], c.stream[], c.source))
      let keyTok = c.stream[].tokens[ev.propKeyTok]
      let valTok = c.stream[].tokens[ev.propValueTok]
      let vRes = buildValueFromTok(valTok, c.stream[], c.source)
      if vRes.isErr:
        result.errors.add(vRes.getErr)
        continue
      var val = vRes.get
      if ev.propAnnoTok != -1:
        let annoStr = tokenAsString(c.stream[].tokens[ev.propAnnoTok], c.stream[], c.source)
        val.typeAnnotation = doc.interner.intern(annoStr)
        let rcheck = validateReserved(annoStr, val)
        if rcheck.isErr:
          result.errors.add(rcheck.getErr)
          continue
      if stack.len > 0:
        var i = 0
        while i < stack[^1].entries.len:
          let e = stack[^1].entries[i]
          if e.kind == keProperty and e.propName == key:
            stack[^1].entries.delete(i)
          else: inc i
        let entrySpan = initSpan(keyTok.span.start, valTok.span.finish)
        var entry = KdlEntry(kind: keProperty,
                             propName: key, propValue: val, span: entrySpan)
        if preserveFormat:
          entry.parseHash = hashEntry(entry, doc.interner)
        stack[^1].entries.add(entry)
    of ceChildrenBegin, ceChildrenEnd: discard
    of ceNodeEnd:
      if stack.len == 0: continue   # recovery dropped the open frame
      var n = stack.pop()
      n.span = initSpan(n.span.start, ev.span.finish)
      if preserveFormat:
        let ch = childHashes.pop()
        n.parseHash = hashNodeFromChildHashes(n, doc.interner, ch)
      n.parseEntryCount = int32(n.entries.len)
      n.parseChildCount = int32(n.children.len)
      if stack.len == 0:
        doc.nodes.add(n)
      else:
        let h = n.parseHash
        stack[^1].children.add(n)
        if preserveFormat:
          childHashes[^1].add(h)
    of ceSlashdashBegin: inc slashdashDepth
    of ceSlashdashEnd: discard
    of ceEof:
      doc.parseTopLevelCount = int32(doc.nodes.len)
      break
    of ceError:
      result.errors.add(ev.err)
      # Don't pop stack frames — the cursor's recovery decides what
      # event to emit next. If it emits a NodeEnd, we'll pop then.
      # Premature popping would close ancestor nodes that may still
      # have valid siblings to come.
  result.doc = doc
