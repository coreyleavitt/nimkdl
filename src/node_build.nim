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
import std/tables
import ./value
import ./node
import ./cursor
import ./lexer
import ./token_text
import ./reserved
import ./spans
export node, value, spans  # spans: Result/ParseError accessors used on parseNodes' result

proc dedupPropsLastWins(entries: var seq[KdlEntry]) =
  ## F2: property keys can repeat on the wire; KDL 2.0 last-wins semantics
  ## keep only the LAST occurrence of each key. The per-token incremental
  ## form of this ("on each `ceProp`, rescan every earlier entry and delete
  ## the same-key one") costs O(entries seen so far) PER property, so a node
  ## with N props (duplicate or not — every token pays the full rescan) costs
  ## O(N^2) — a crafted node with ~10^4 bogus props hangs the single-threaded
  ## parser for minutes.
  ##
  ## This does the equivalent dedup in one O(n) pass over the finished node
  ## instead: a Table lookup finds each key's LAST index, then a single
  ## filtering pass keeps every argument and only each prop key's
  ## last-occurrence entry, in original relative order. This reproduces the
  ## incremental version's observable result exactly — the surviving entry's
  ## POSITION is where its *last* occurrence was, not its first (verified: a
  ## repeated key that lands the delete-then-append at the end is exactly
  ## what "keep the last index, drop the rest" also produces) — while making
  ## the property fast path O(1) amortized (a bare append) and dedup a single
  ## O(n) pass at node-close instead of an O(n) rescan per token.
  if entries.len == 0: return
  var lastIdx = initTable[string, int]()
  var propCount = 0
  for i, e in entries:
    if e.kind == keProperty:
      inc propCount
      lastIdx[e.propKey] = i
  if lastIdx.len == propCount: return  # every prop key distinct → nothing to drop
  var deduped = newSeqOfCap[KdlEntry](entries.len)
  for i, e in entries:
    case e.kind
    of keArgument:
      deduped.add(e)
    of keProperty:
      # getOrDefault, not `[]`: every key here was inserted into lastIdx above
      # so the -1 branch never actually triggers, but `[]` can raise KeyError
      # and would infect `parseNodes`'s raises signature for a case that
      # cannot happen. getOrDefault is raises-free.
      if lastIdx.getOrDefault(e.propKey, -1) == i:
        deduped.add(e)
  entries = deduped

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
  doc.setSource(c.source)
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
        # Repeated prop keys are last-wins (KDL 2.0 §Properties), but resolving
        # that HERE, per token, would rescan the whole entries-so-far list on
        # every prop (O(n^2) over a node with n props — F2). Just append; the
        # single O(n) `dedupPropsLastWins` pass at ceNodeEnd resolves duplicates
        # once, for the whole node.
        stack[^1].entries.add(newProperty(key, val))
    of ceChildrenBegin, ceChildrenEnd:
      discard  # node nesting handled by Begin/End node pairing
    of ceNodeEnd:
      if stack.len == 0: continue  # stray NodeEnd from cursor recovery
      let n = stack.pop()
      dedupPropsLastWins(n.entries)
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
  doc.setSource(c.source)
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
        # See buildNodeDoc's ceProp handler (F2): append-only here, dedup once
        # per node (O(n)) at ceNodeEnd rather than rescanning per token (O(n^2)).
        stack[^1].entries.add(newProperty(key, val))
    of ceChildrenBegin, ceChildrenEnd:
      discard
    of ceNodeEnd:
      if stack.len == 0: continue   # recovery dropped the open frame
      let n = stack.pop()
      dedupPropsLastWins(n.entries)
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
  # Build the LineMap ONCE over `source`, not per erroring node: the
  # `enriched(source, ...)` overload rescans the whole source on each call, so
  # an error-dense source paid O(N·n) (the same DoS class as decodeAll, review
  # #3-residual). Enrich every collected error through the prebuilt-map overload
  # instead — O(n + N·log n). Coordinates are byte-identical (same lineColOf over
  # the same absolute offset).
  result = buildNodeDocAll(c, sourcePath)
  let lm = buildLineMap(source)
  for i in 0 ..< result.errors.len:
    result.errors[i] = result.errors[i].enriched(lm, sourcePath)
