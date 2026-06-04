## node_build.nim — fold cursor events into a self-contained node.KdlDoc.
##
## The strangler replacement for `doc_build.buildDoc`: same cursor-event walk,
## but it builds the owned-string `node`/`value` types (no interner, no
## `ownerDocument`). When `parser.parse()` swaps onto `parseNodes`, the interned
## `doc_build` + `ast` core retire (rfc-core-rebuild §SB).
##
## This slice covers the structural core — nodes, typed args, props (last-wins),
## children, node + value type annotations, slashdash discard. The preserve-mode
## sidecar (span/parseHash) and reserved-tag validation (currently typed to the
## old `ast.KdlValue`) rejoin in later slices.

import std/options
import ./value
import ./node
import ./cursor
import ./lexer
import ./token_text
import ./reserved
import ./spans
export node, value, spans  # spans: Result/ParseError accessors used on parseNodes' result

func nodeStartOffset(c: StringCursor, ev: CursorEvent): int {.inline.} =
  ## True byte offset of a node's first source character (rfc-consumer-api S1).
  ##
  ## `ceNodeBegin.span` is the NAME-token span — correct for a bare/quoted
  ## node, but for an annotated node `(tag) name ...` the real first byte is
  ## the `(` paren, which sits one token before the annotation tag. The cursor
  ## exposes `ev.nodeAnnoTok` (the tag-token index, -1 if absent), so the paren
  ## is `nodeAnnoTok - 1`. (Verified against cursor.tryConsumeAnno: the tag is
  ## emitted at `c.tokIdx + 1` with `(` consumed at `c.tokIdx`.)
  if ev.nodeAnnoTok != -1:
    c.stream[].tokens[ev.nodeAnnoTok - 1].span.offset   # '(' paren token
  else:
    ev.span.offset                                       # name-token offset

proc buildNodeDoc*(c: var StringCursor, sourcePath = "<input>"):
    Result[KdlDoc, ParseError] {.noSideEffect.} =
  ## Fold cursor events into a self-contained KdlDoc via an explicit node stack.
  var doc = newDoc(sourcePath)
  doc.sourceText = c.source
  var stack: seq[KdlNode] = @[]
  var slashdashDepth = 0
  while true:
    let ev = advance(c)
    if slashdashDepth > 0:
      # Inside a slashdash bracket all emission is suppressed; just track nesting.
      case ev.kind
      of ceSlashdashBegin: inc slashdashDepth
      of ceSlashdashEnd:   dec slashdashDepth
      of ceError: return err[KdlDoc, ParseError](ev.err[])
      of ceEof:   return ok[KdlDoc, ParseError](doc)
      else: discard
      continue
    case ev.kind
    of ceNodeBegin:
      let name = tokenAsString(c.stream[].tokens[ev.nodeNameTok], c.stream[], c.source)
      var typeAnno = none(string)
      if ev.nodeAnnoTok != -1:
        typeAnno = some(tokenAsString(c.stream[].tokens[ev.nodeAnnoTok], c.stream[], c.source))
      stack.add(KdlNode(name: name, typeAnnotation: typeAnno,
                        entries: @[], childNodes: @[],
                        span: initSpan(nodeStartOffset(c, ev), 0)))
    of ceArg:
      let tok = c.stream[].tokens[ev.argTok]
      let vRes = tokenToKdlValue(tok, c.stream[], c.source)
      if vRes.isErr: return err[KdlDoc, ParseError](vRes.getErr)
      var val = vRes.get
      if ev.argAnnoTok != -1:
        let annoStr = tokenAsString(c.stream[].tokens[ev.argAnnoTok], c.stream[], c.source)
        val.typeAnnotation = some(annoStr)
        let rcheck = validateReserved(annoStr, val, tok.span)
        if rcheck.isErr: return err[KdlDoc, ParseError](rcheck.getErr)
      if stack.len > 0:
        stack[^1].entries.add(newArgument(val))
    of ceProp:
      let key = tokenAsString(c.stream[].tokens[ev.propKeyTok], c.stream[], c.source)
      let valTok = c.stream[].tokens[ev.propValueTok]
      let vRes = tokenToKdlValue(valTok, c.stream[], c.source)
      if vRes.isErr: return err[KdlDoc, ParseError](vRes.getErr)
      var val = vRes.get
      if ev.propAnnoTok != -1:
        let annoStr = tokenAsString(c.stream[].tokens[ev.propAnnoTok], c.stream[], c.source)
        val.typeAnnotation = some(annoStr)
        let rcheck = validateReserved(annoStr, val, valTok.span)
        if rcheck.isErr: return err[KdlDoc, ParseError](rcheck.getErr)
      if stack.len > 0:
        # Repeated prop keys: last-wins — drop any earlier entry with this key.
        var i = 0
        while i < stack[^1].entries.len:
          let e = stack[^1].entries[i]
          if e.kind == keProperty and e.propKey == key:
            stack[^1].entries.delete(i)
          else: inc i
        stack[^1].entries.add(newProperty(key, val))
    of ceChildrenBegin, ceChildrenEnd:
      discard  # node nesting handled by Begin/End node pairing
    of ceNodeEnd:
      if stack.len == 0: continue  # stray NodeEnd from cursor recovery
      let n = stack.pop()
      n.span = initSpan(n.span.offset, ev.span.offset - n.span.offset)
      if stack.len == 0:
        doc.rootNodes.add(n)
      else:
        stack[^1].childNodes.add(n)
    of ceSlashdashBegin:
      inc slashdashDepth
    of ceSlashdashEnd:
      discard  # only reachable when starting depth was 0 (mid-emission close)
    of ceEof:
      return ok[KdlDoc, ParseError](doc)
    of ceError:
      return err[KdlDoc, ParseError](ev.err[])

proc parseNodes*(source: string, sourcePath = "<input>"):
    Result[KdlDoc, ParseError] {.noSideEffect.} =
  ## lex → cursor → buildNodeDoc. The self-contained-DOM counterpart of
  ## `parser.parse()`.
  var stream = lex(source)
  var c = initStringCursor(addr stream, source)
  # Public boundary: enrich the error with line/col + sourcePath once, here,
  # where `source` is in hand (rfc-consumer-api §4.4). `buildNodeDoc` itself
  # produces source-less errors (it only sees the cursor).
  let r = buildNodeDoc(c, sourcePath)
  if r.isErr:
    return err[KdlDoc, ParseError](r.getErr.enriched(source, sourcePath))
  r

proc buildNodeDocAll*(c: var StringCursor, sourcePath = "<input>"):
    Parsed[KdlDoc] {.noSideEffect.} =
  ## Accumulating variant: cursor must be in cmAccumulating. Each `ceError` is
  ## collected and the cursor recovers; the returned doc is partial — it holds
  ## whatever the recovered parses produced. Mirrors `doc_build.buildDocAll`.
  var doc = newDoc(sourcePath)
  doc.sourceText = c.source
  result.value = doc
  var stack: seq[KdlNode] = @[]
  var slashdashDepth = 0
  while true:
    let ev = advance(c)
    if slashdashDepth > 0:
      case ev.kind
      of ceSlashdashBegin: inc slashdashDepth
      of ceSlashdashEnd:   dec slashdashDepth
      of ceError:
        result.errors.add(ev.err[])
        slashdashDepth = 0   # recovery clears open slashdash brackets
      of ceEof: break
      else: discard
      continue
    case ev.kind
    of ceNodeBegin:
      let name = tokenAsString(c.stream[].tokens[ev.nodeNameTok], c.stream[], c.source)
      var typeAnno = none(string)
      if ev.nodeAnnoTok != -1:
        typeAnno = some(tokenAsString(c.stream[].tokens[ev.nodeAnnoTok], c.stream[], c.source))
      stack.add(KdlNode(name: name, typeAnnotation: typeAnno,
                        entries: @[], childNodes: @[],
                        span: initSpan(nodeStartOffset(c, ev), 0)))
    of ceArg:
      let tok = c.stream[].tokens[ev.argTok]
      let vRes = tokenToKdlValue(tok, c.stream[], c.source)
      if vRes.isErr:
        result.errors.add(vRes.getErr); continue
      var val = vRes.get
      if ev.argAnnoTok != -1:
        let annoStr = tokenAsString(c.stream[].tokens[ev.argAnnoTok], c.stream[], c.source)
        val.typeAnnotation = some(annoStr)
        let rcheck = validateReserved(annoStr, val, tok.span)
        if rcheck.isErr:
          result.errors.add(rcheck.getErr); continue
      if stack.len > 0:
        stack[^1].entries.add(newArgument(val))
    of ceProp:
      let key = tokenAsString(c.stream[].tokens[ev.propKeyTok], c.stream[], c.source)
      let valTok = c.stream[].tokens[ev.propValueTok]
      let vRes = tokenToKdlValue(valTok, c.stream[], c.source)
      if vRes.isErr:
        result.errors.add(vRes.getErr); continue
      var val = vRes.get
      if ev.propAnnoTok != -1:
        let annoStr = tokenAsString(c.stream[].tokens[ev.propAnnoTok], c.stream[], c.source)
        val.typeAnnotation = some(annoStr)
        let rcheck = validateReserved(annoStr, val, valTok.span)
        if rcheck.isErr:
          result.errors.add(rcheck.getErr); continue
      if stack.len > 0:
        var i = 0
        while i < stack[^1].entries.len:
          let e = stack[^1].entries[i]
          if e.kind == keProperty and e.propKey == key:
            stack[^1].entries.delete(i)
          else: inc i
        stack[^1].entries.add(newProperty(key, val))
    of ceChildrenBegin, ceChildrenEnd:
      discard
    of ceNodeEnd:
      if stack.len == 0: continue   # recovery dropped the open frame
      let n = stack.pop()
      n.span = initSpan(n.span.offset, ev.span.offset - n.span.offset)
      if stack.len == 0:
        result.value.rootNodes.add(n)
      else:
        stack[^1].childNodes.add(n)
    of ceSlashdashBegin:
      inc slashdashDepth
    of ceSlashdashEnd:
      discard
    of ceEof:
      break
    of ceError:
      result.errors.add(ev.err[])

proc parseNodesAll*(source: string, sourcePath = "<input>"):
    Parsed[KdlDoc] {.noSideEffect.} =
  ## Multi-error variant of `parseNodes`. The self-contained-DOM counterpart of
  ## `parser.parseAll()`.
  var stream = lex(source)
  var c = initStringCursor(addr stream, source, mode = cmAccumulating)
  # Public boundary: enrich every collected error with line/col + sourcePath
  # once, here, where `source` is in hand (rfc-consumer-api §4.4).
  result = buildNodeDocAll(c, sourcePath)
  for i in 0 ..< result.errors.len:
    result.errors[i] = result.errors[i].enriched(source, sourcePath)
