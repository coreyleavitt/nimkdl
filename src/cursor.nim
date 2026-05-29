## Token cursor — the foundation primitive of the three-categories
## architecture (see docs/rfc-three-categories-architecture.md).
##
## The cursor walks a `TokenStream`, applying KDL grammar at the event
## level. Each `advance()` returns a `CursorEvent` (ceNodeBegin, ceArg,
## ceProp, ceChildrenBegin, ceChildrenEnd, ceNodeEnd, ceSlashdashBegin,
## ceSlashdashEnd, ceEof, ceError). The three consumer surfaces ride
## on this cursor independently:
##
## - Cat 1 (streaming): exposes the event stream to user callbacks
## - Cat 2 (typed-derive): codegen emits recursive `decode[T]` over events
## - Cat 3 (AST/DOM): DocBuilder folds events into a KdlDoc via stack
##
## Tokens are referenced by INDEX into the underlying TokenStream rather
## than copied by value into events — keeps events ~16 bytes and avoids
## the Nim case-object-as-case-object-field friction. Consumers call
## `bytes(c, idx)` or `tokenAt(c, idx)` for resolution.

import ./ast
import ./fnv
import ./hashing
import ./intern
import ./lexer
import ./numlit
import ./reserved
import ./spans

const
  MaxParserDepth* = 256
    ## Maximum `{ children }` nesting depth. Exceeding this would
    ## trip Nim's call-stack limit on debug builds (and is a
    ## supply-chain attack vector — adversarial KDL with thousands
    ## of nested braces could DoS a service that does dep-tree walks).
    ## Matches typed_parser.MaxParserDepthValue exactly until Phase 5
    ## deletes that copy.

type
  CursorEventKind* = enum
    ceNodeBegin
    ceArg
    ceProp
    ceChildrenBegin
    ceChildrenEnd
    ceNodeEnd
    ceSlashdashBegin
    ceSlashdashEnd
    ceEof
    ceError

  CursorEvent* = object
    span*: Span
    case kind*: CursorEventKind
    of ceNodeBegin:
      nodeNameTok*: int
      nodeAnnoTok*: int   # -1 if absent
    of ceArg:
      argIdx*: int
      argTok*: int
      argAnnoTok*: int    # -1 if absent
    of ceProp:
      propKeyTok*: int
      propValueTok*: int
      propAnnoTok*: int   # -1 if absent
    of ceError:
      err*: ParseError
    else: discard

  CursorState = enum
    csTopLevel          ## between nodes (top-level or in a children block); expect node head, RBrace, or EOF
    csInNodeEntries     ## inside a node; expect entry, `{`, terminator, RBrace, or EOF

  NodeFrame = object
    seenRealChildren: bool
      ## At-most-one-real-children-block guard. Set when a non-
      ## slashdashed `{...}` block was consumed; rejects subsequent
      ## real children blocks (slashdashed are still allowed).
    seenAnyChildren: bool
      ## No-entries-after-any-children guard. Set when ANY children
      ## block (real OR slashdashed) was consumed; rejects subsequent
      ## entries. Per KDL v2 spec, both children kinds block more
      ## entries from following.

  CursorMode* = enum
    cmSingle         ## first ceError halts the stream (subsequent advance() returns ceEof)
    cmAccumulating   ## ceError is emitted then the cursor re-syncs at the next safe point

  SlashdashKind = enum
    sdEntry             ## /- single entry: SlashdashEnd after next entry event
    sdNode              ## /- node: SlashdashEnd after matching NodeEnd at anchor depth
    sdChildren          ## /- { children }: SlashdashEnd after matching ChildrenEnd at anchor depth

  PendingSlashdash = object
    kind: SlashdashKind
    anchorDepth: int    ## depth at which to match the close event

  StringCursor* = object
    stream*: ptr TokenStream
    source*: string
    tokIdx*: int
    state*: CursorState
    argIdx*: int      ## positional-arg counter within current node; reset at NodeBegin
    depth*: int       ## children-block nesting depth (0 = top-level)
    pendingEnds*: seq[CursorEvent]      ## queued SlashdashEnd / similar deferred emissions
    slashdashStack*: seq[PendingSlashdash]  ## open slashdash brackets awaiting close
    nodeFrames: seq[NodeFrame]          ## one per open node (between NodeBegin/NodeEnd)
    childrenIsSlashdashed: seq[bool]    ## per open children block: was it slashdash-prefixed?
    mode*: CursorMode
    halted*: bool      ## set after a ceError in single-shot mode; subsequent advance() returns ceEof

proc initStringCursor*(stream: ptr TokenStream, source: string,
                       mode: CursorMode = cmSingle): StringCursor =
  StringCursor(stream: stream, source: source, tokIdx: 0,
               state: csTopLevel, mode: mode)

template tok(c: StringCursor): Token =
  c.stream[].tokens[c.tokIdx]

proc tryConsumeAnno(c: var StringCursor): int =
  ## If `tok` is `(` followed by an ident/string/raw-string then `)`,
  ## parse + return the tag's token index. Otherwise return -1 and
  ## leave tokIdx untouched. Caller decides whether to emit ceError
  ## or recover. KDL v2 forbids numbers/keywords as tags.
  if c.tok.kind != tkLParen:
    return -1
  let n = c.stream[].tokens.len
  if c.tokIdx + 2 >= n: return -1
  let tagKind = c.stream[].tokens[c.tokIdx + 1].kind
  if tagKind notin {tkIdent, tkString, tkRawString}: return -1
  let closeKind = c.stream[].tokens[c.tokIdx + 2].kind
  if closeKind != tkRParen: return -1
  let tagIdx = c.tokIdx + 1
  c.tokIdx += 3
  tagIdx

proc currentEntryIsSlashdashed(c: StringCursor): bool {.inline.} =
  c.slashdashStack.len > 0 and c.slashdashStack[^1].kind == sdEntry

proc inSlashdashedChildren(c: StringCursor): bool {.inline.} =
  ## True if the next `{` we're about to consume is the slashdashed
  ## unit (sdChildren on stack at the current depth). Used at
  ## tkLBrace dispatch to allow children even after a real one.
  c.slashdashStack.len > 0 and
    c.slashdashStack[^1].kind == sdChildren and
    c.slashdashStack[^1].anchorDepth == c.depth

proc rejectAfterChildren(c: var StringCursor, span: Span): CursorEvent =
  let pe = initError(peParseUnexpected, span,
                     "entries are not permitted after a children block")
  case c.mode
  of cmSingle: c.halted = true
  of cmAccumulating: inc c.tokIdx
  CursorEvent(kind: ceError, span: span, err: pe)

proc currentNodeSawRealChildren(c: StringCursor): bool {.inline.} =
  c.nodeFrames.len > 0 and c.nodeFrames[^1].seenRealChildren

proc currentNodeSawAnyChildren(c: StringCursor): bool {.inline.} =
  c.nodeFrames.len > 0 and c.nodeFrames[^1].seenAnyChildren

proc needsWsBefore(c: StringCursor): bool {.inline.} =
  ## True if the current token starts an entry whose leading token is
  ## not preceded by whitespace AND we're not currently inside an
  ## entry-slashdash (which lets the slashdashed content abut the `/-`).
  if c.tok.precededByWs: return false
  if c.slashdashStack.len > 0 and c.slashdashStack[^1].kind == sdEntry:
    return false
  true

proc emitAdjacencyError(c: var StringCursor, span: Span): CursorEvent =
  let pe = initError(peParseExpected, span,
                     "whitespace required before this entry")
  case c.mode
  of cmSingle: c.halted = true
  of cmAccumulating:
    # Skip the bad entry's leading token so we don't loop on it.
    inc c.tokIdx
  CursorEvent(kind: ceError, span: span, err: pe)

proc emitMalformedAnnoError(c: var StringCursor, span: Span): CursorEvent =
  ## Construct a synthetic ceError for a malformed `(tag)` annotation.
  ## Single-shot mode halts; accumulating mode recovers by stepping
  ## past the stray `(` so subsequent advance() can re-sync.
  let pe = initError(peParseExpected, span,
                     "malformed type annotation: expected (ident)")
  inc c.tokIdx
  case c.mode
  of cmSingle:
    c.halted = true
  of cmAccumulating:
    c.state = csTopLevel
    c.slashdashStack.setLen(0)
    c.pendingEnds.setLen(0)
  CursorEvent(kind: ceError, span: span, err: pe)

proc bytes*(c: StringCursor, tokIdx: int): string =
  ## Token payload as a freshly-copied string. Ergonomic — binds anywhere
  ## (let, var, check). For zero-copy hot-path dispatch use `bytesEq`.
  let t = c.stream[].tokens[tokIdx]
  result = c.source[int(t.span.offset) ..< int(t.span.endOffset)]

template bytesEq*(c: StringCursor, tokIdx: int, s: string): bool =
  ## Zero-copy compare of the token payload against a literal. The
  ## per-instantiation `cmp` proc resolves to `==` on byte ranges.
  let t = c.stream[].tokens[tokIdx]
  let o = int(t.span.offset)
  let n = int(t.span.length)
  n == s.len and equalMem(unsafeAddr c.source[o], unsafeAddr s[0], n)

proc peekSlashdashKindAt(c: StringCursor, atIdx: int): SlashdashKind =
  ## Determine the slashdash kind given the cursor's state and the
  ## token at `atIdx` (the resolved target after newline skipping).
  if atIdx >= c.stream[].tokens.len: return sdEntry
  case c.stream[].tokens[atIdx].kind
  of tkLBrace: sdChildren
  of tkLParen, tkIdent, tkNumber, tkString, tkRawString, tkKeyword:
    if c.state == csTopLevel: sdNode
    else: sdEntry
  else: sdEntry

proc advanceRaw(c: var StringCursor): CursorEvent =
  # Skip top-level noise between nodes/statements.
  while c.state == csTopLevel and c.tok.kind in {tkNewline, tkSemicolon}:
    inc c.tokIdx

  # Lex error short-circuits regardless of grammar state — the lexer
  # emits tkError at the offending position and the cursor surfaces it
  # immediately as ceError. Single-shot mode then halts the stream;
  # accumulating mode will instead re-sync at the next node boundary
  # (deferred to the recovery cycle).
  if c.tok.kind == tkError:
    let t = c.tok
    let pe = c.stream[].errorPayloads[int(t.errIdx)]
    inc c.tokIdx
    case c.mode
    of cmSingle:
      c.halted = true
    of cmAccumulating:
      # Re-sync: scan forward past lexer-recovery noise (tkString /
      # tkNumber etc.) until the next token that can safely start (or
      # terminate) a node head. Slashdash state is cleared — the bad
      # token broke whatever bracket was open.
      while c.tokIdx < c.stream[].tokens.len:
        let nk = c.stream[].tokens[c.tokIdx].kind
        if nk in {tkIdent, tkLParen, tkSlashDash, tkLBrace, tkRBrace,
                  tkNewline, tkSemicolon, tkEof, tkError}:
          break
        inc c.tokIdx
      c.state = csTopLevel
      c.slashdashStack.setLen(0)
      c.pendingEnds.setLen(0)
    return CursorEvent(kind: ceError, span: t.span, err: pe)

  case c.state
  of csTopLevel:
    let t = c.tok
    case t.kind
    of tkEof:
      if c.depth > 0:
        let pe = initError(peParseExpected, t.span,
                           "unclosed children block at end of input")
        c.halted = true
        return CursorEvent(kind: ceError, span: t.span, err: pe)
      return CursorEvent(kind: ceEof, span: t.span)
    of tkSlashDash:
      let sdSpan = t.span
      inc c.tokIdx
      # Skip past newlines between /- and its target.
      while c.tokIdx < c.stream[].tokens.len and
            c.stream[].tokens[c.tokIdx].kind == tkNewline:
        inc c.tokIdx
      if c.tokIdx >= c.stream[].tokens.len or
         c.stream[].tokens[c.tokIdx].kind in {tkEof, tkSemicolon, tkRBrace}:
        let pe = initError(peParseExpected, sdSpan,
                           "slashdash has no target")
        case c.mode
        of cmSingle: c.halted = true
        of cmAccumulating: discard
        return CursorEvent(kind: ceError, span: sdSpan, err: pe)
      let kind = peekSlashdashKindAt(c, c.tokIdx)
      c.slashdashStack.add(PendingSlashdash(kind: kind, anchorDepth: c.depth))
      return CursorEvent(kind: ceSlashdashBegin, span: sdSpan)
    of tkLParen:
      let annoIdx = tryConsumeAnno(c)
      if annoIdx == -1:
        return emitMalformedAnnoError(c, t.span)
      let nameTok = c.tok
      if nameTok.kind notin {tkIdent, tkString, tkRawString}:
        return emitMalformedAnnoError(c, t.span)
      # Bidi check for quoted/raw names.
      if nameTok.kind == tkString:
        let p = c.stream[].stringPayloads[nameTok.strIdx]
        if containsBidiControl(p):
          let pe = initError(peLexInvalidIdentifier, nameTok.span,
                             "bidi control codepoint in node name")
          c.halted = true
          return CursorEvent(kind: ceError, span: nameTok.span, err: pe)
      elif nameTok.kind == tkRawString:
        let p = c.stream[].rawStringPayloads[nameTok.rawIdx]
        if containsBidiControl(p):
          let pe = initError(peLexInvalidIdentifier, nameTok.span,
                             "bidi control codepoint in node name")
          c.halted = true
          return CursorEvent(kind: ceError, span: nameTok.span, err: pe)
      let nameIdx = c.tokIdx
      inc c.tokIdx
      c.state = csInNodeEntries
      c.argIdx = 0
      c.nodeFrames.add(NodeFrame(seenRealChildren: false))
      return CursorEvent(kind: ceNodeBegin, span: nameTok.span,
                         nodeNameTok: nameIdx, nodeAnnoTok: annoIdx)
    of tkString, tkRawString:
      # Quoted/raw-string node name (no type annotation prefix).
      if t.kind == tkString:
        let p = c.stream[].stringPayloads[t.strIdx]
        if containsBidiControl(p):
          let pe = initError(peLexInvalidIdentifier, t.span,
                             "bidi control codepoint in node name")
          c.halted = true
          return CursorEvent(kind: ceError, span: t.span, err: pe)
      else:
        let p = c.stream[].rawStringPayloads[t.rawIdx]
        if containsBidiControl(p):
          let pe = initError(peLexInvalidIdentifier, t.span,
                             "bidi control codepoint in node name")
          c.halted = true
          return CursorEvent(kind: ceError, span: t.span, err: pe)
      let nameIdx = c.tokIdx
      inc c.tokIdx
      c.state = csInNodeEntries
      c.argIdx = 0
      c.nodeFrames.add(NodeFrame(seenRealChildren: false))
      return CursorEvent(kind: ceNodeBegin, span: t.span,
                         nodeNameTok: nameIdx, nodeAnnoTok: -1)
    of tkRBrace:
      # Close of a children block. Determine whether the closing block
      # was slashdash-prefixed before popping depth — that drives both
      # at-most-one-real-children (only real ones set seenRealChildren)
      # and no-entries-after-any-children (any closure sets seenAnyChildren).
      inc c.tokIdx
      let wasSlashdashed =
        if c.childrenIsSlashdashed.len > 0: c.childrenIsSlashdashed.pop()
        else: false
      dec c.depth
      if c.nodeFrames.len > 0:
        c.nodeFrames[^1].seenAnyChildren = true
        if not wasSlashdashed:
          c.nodeFrames[^1].seenRealChildren = true
      c.state = csInNodeEntries
      return CursorEvent(kind: ceChildrenEnd, span: t.span)
    of tkIdent:
      let nameIdx = c.tokIdx
      inc c.tokIdx
      c.state = csInNodeEntries
      c.argIdx = 0
      c.nodeFrames.add(NodeFrame(seenRealChildren: false))
      return CursorEvent(kind: ceNodeBegin, span: t.span,
                         nodeNameTok: nameIdx, nodeAnnoTok: -1)
    else:
      let pe = initError(peParseUnexpected, t.span,
                         "unexpected token at node boundary")
      case c.mode
      of cmSingle: c.halted = true
      of cmAccumulating: inc c.tokIdx
      return CursorEvent(kind: ceError, span: t.span, err: pe)
  of csInNodeEntries:
    let t = c.tok
    case t.kind
    of tkEof, tkNewline, tkSemicolon, tkRBrace:
      # NodeEnd span ends just BEFORE the terminator (matches visitor
      # protocol's semantics — the node's span covers content only,
      # not the trailing newline/semi/EOF/brace).
      let endSpan = pointSpan(t.span.start)
      if t.kind in {tkNewline, tkSemicolon}:
        inc c.tokIdx
      c.state = csTopLevel
      if c.nodeFrames.len > 0: discard c.nodeFrames.pop()
      return CursorEvent(kind: ceNodeEnd, span: endSpan)
    of tkLBrace:
      # Reject second real children block; slashdashed children blocks
      # are still allowed (they're noise, not structural).
      let isSlashdashed = inSlashdashedChildren(c)
      if not isSlashdashed and currentNodeSawRealChildren(c):
        return rejectAfterChildren(c, t.span)
      if c.depth + 1 > MaxParserDepth:
        let pe = initError(peParseDepthExceeded, t.span,
                           "nesting depth exceeded MaxParserDepth")
        case c.mode
        of cmSingle: c.halted = true
        of cmAccumulating: discard
        return CursorEvent(kind: ceError, span: t.span, err: pe)
      inc c.tokIdx
      inc c.depth
      c.childrenIsSlashdashed.add(isSlashdashed)
      c.state = csTopLevel
      return CursorEvent(kind: ceChildrenBegin, span: t.span)
    of tkSlashDash:
      let sdSpan = t.span
      inc c.tokIdx
      while c.tokIdx < c.stream[].tokens.len and
            c.stream[].tokens[c.tokIdx].kind == tkNewline:
        inc c.tokIdx
      # /- requires a target. EOF / semicolon / rbrace = no target = error.
      if c.tokIdx >= c.stream[].tokens.len or
         c.stream[].tokens[c.tokIdx].kind in {tkEof, tkSemicolon, tkRBrace}:
        let pe = initError(peParseExpected, sdSpan,
                           "slashdash has no target")
        case c.mode
        of cmSingle: c.halted = true
        of cmAccumulating: discard
        return CursorEvent(kind: ceError, span: sdSpan, err: pe)
      let kind = peekSlashdashKindAt(c, c.tokIdx)
      c.slashdashStack.add(PendingSlashdash(kind: kind, anchorDepth: c.depth))
      return CursorEvent(kind: ceSlashdashBegin, span: sdSpan)
    of tkLParen:
      if needsWsBefore(c):
        return emitAdjacencyError(c, t.span)
      if currentNodeSawAnyChildren(c) and not currentEntryIsSlashdashed(c):
        return rejectAfterChildren(c, t.span)
      # Arg with type annotation: (tag) value
      let annoIdx = tryConsumeAnno(c)
      if annoIdx == -1:
        return emitMalformedAnnoError(c, t.span)
      if c.tokIdx >= c.stream[].tokens.len:
        return emitMalformedAnnoError(c, t.span)
      let valSpan = c.tok.span
      let valIdx = c.tokIdx
      let myArgIdx = c.argIdx
      inc c.argIdx
      inc c.tokIdx
      return CursorEvent(kind: ceArg, span: valSpan,
                         argIdx: myArgIdx, argTok: valIdx, argAnnoTok: annoIdx)
    of tkNumber, tkKeyword:
      if needsWsBefore(c):
        return emitAdjacencyError(c, t.span)
      if currentNodeSawAnyChildren(c) and not currentEntryIsSlashdashed(c):
        return rejectAfterChildren(c, t.span)
      let valIdx = c.tokIdx
      let myArgIdx = c.argIdx
      inc c.argIdx
      inc c.tokIdx
      return CursorEvent(kind: ceArg, span: t.span,
                         argIdx: myArgIdx, argTok: valIdx, argAnnoTok: -1)
    of tkString, tkRawString:
      # Quoted/raw-string in entry position: prop key if followed by
      # `=`, else arg value. Prop-key form does bidi check.
      if needsWsBefore(c):
        return emitAdjacencyError(c, t.span)
      if currentNodeSawAnyChildren(c) and not currentEntryIsSlashdashed(c):
        return rejectAfterChildren(c, t.span)
      let nextKind = c.stream[].tokens[c.tokIdx + 1].kind
      if nextKind == tkEquals:
        # Bidi check on prop-key payload.
        if t.kind == tkString:
          let p = c.stream[].stringPayloads[t.strIdx]
          if containsBidiControl(p):
            let pe = initError(peLexInvalidIdentifier, t.span,
                               "bidi control codepoint in property key")
            c.halted = true
            return CursorEvent(kind: ceError, span: t.span, err: pe)
        else:
          let p = c.stream[].rawStringPayloads[t.rawIdx]
          if containsBidiControl(p):
            let pe = initError(peLexInvalidIdentifier, t.span,
                               "bidi control codepoint in property key")
            c.halted = true
            return CursorEvent(kind: ceError, span: t.span, err: pe)
        let keyIdx = c.tokIdx
        var valIdx = c.tokIdx + 2
        var annoIdx = -1
        if valIdx >= c.stream[].tokens.len or
           c.stream[].tokens[valIdx].kind in {tkEof, tkNewline, tkSemicolon, tkRBrace}:
          let pe = initError(peParseExpected, t.span,
                             "property is missing a value")
          case c.mode
          of cmSingle: c.halted = true
          of cmAccumulating: inc c.tokIdx
          return CursorEvent(kind: ceError, span: t.span, err: pe)
        if c.stream[].tokens[valIdx].kind == tkLParen:
          if valIdx + 3 >= c.stream[].tokens.len:
            let pe = initError(peParseExpected, t.span,
                               "property value has malformed annotation")
            case c.mode
            of cmSingle: c.halted = true
            of cmAccumulating: inc c.tokIdx
            return CursorEvent(kind: ceError, span: t.span, err: pe)
          annoIdx = valIdx + 1
          valIdx += 3
        c.tokIdx = valIdx + 1
        return CursorEvent(kind: ceProp, span: t.span,
                           propKeyTok: keyIdx, propValueTok: valIdx,
                           propAnnoTok: annoIdx)
      else:
        let valIdx = c.tokIdx
        let myArgIdx = c.argIdx
        inc c.argIdx
        inc c.tokIdx
        return CursorEvent(kind: ceArg, span: t.span,
                           argIdx: myArgIdx, argTok: valIdx, argAnnoTok: -1)
    of tkIdent:
      if needsWsBefore(c):
        return emitAdjacencyError(c, t.span)
      if currentNodeSawAnyChildren(c) and not currentEntryIsSlashdashed(c):
        return rejectAfterChildren(c, t.span)
      let nextKind = c.stream[].tokens[c.tokIdx + 1].kind
      if nextKind == tkEquals:
        let keyIdx = c.tokIdx
        var valIdx = c.tokIdx + 2
        var annoIdx = -1
        # Prop value may carry an annotation: key = (tag) value
        if valIdx >= c.stream[].tokens.len or
           c.stream[].tokens[valIdx].kind in {tkEof, tkNewline, tkSemicolon, tkRBrace}:
          let pe = initError(peParseExpected, t.span,
                             "property is missing a value")
          case c.mode
          of cmSingle: c.halted = true
          of cmAccumulating: inc c.tokIdx
          return CursorEvent(kind: ceError, span: t.span, err: pe)
        if c.stream[].tokens[valIdx].kind == tkLParen:
          if valIdx + 3 >= c.stream[].tokens.len:
            let pe = initError(peParseExpected, t.span,
                               "property value has malformed annotation")
            case c.mode
            of cmSingle: c.halted = true
            of cmAccumulating: inc c.tokIdx
            return CursorEvent(kind: ceError, span: t.span, err: pe)
          annoIdx = valIdx + 1
          valIdx += 3   # past `(`, tag, `)`
        c.tokIdx = valIdx + 1
        return CursorEvent(kind: ceProp, span: t.span,
                           propKeyTok: keyIdx, propValueTok: valIdx,
                           propAnnoTok: annoIdx)
      else:
        let valIdx = c.tokIdx
        let myArgIdx = c.argIdx
        inc c.argIdx
        inc c.tokIdx
        return CursorEvent(kind: ceArg, span: t.span,
                           argIdx: myArgIdx, argTok: valIdx, argAnnoTok: -1)
    else:
      let pe = initError(peParseUnexpected, t.span,
                         "unexpected token in node entries")
      case c.mode
      of cmSingle: c.halted = true
      of cmAccumulating: inc c.tokIdx
      return CursorEvent(kind: ceError, span: t.span, err: pe)

proc advance*(c: var StringCursor): CursorEvent =
  ## Public entry point: drains queued events first, then generates the
  ## next grammar event, then inspects the slashdash stack to see if the
  ## just-emitted event closes a bracket (queuing SlashdashEnd if so).
  if c.halted:
    return CursorEvent(kind: ceEof, span: c.tok.span)
  if c.pendingEnds.len > 0:
    result = c.pendingEnds[0]
    c.pendingEnds.delete(0)
    return

  result = advanceRaw(c)

  if c.slashdashStack.len == 0:
    return
  let top = c.slashdashStack[^1]
  let closes =
    case top.kind
    of sdEntry:    result.kind in {ceArg, ceProp}
    of sdNode:     result.kind == ceNodeEnd and c.depth == top.anchorDepth
    of sdChildren: result.kind == ceChildrenEnd and c.depth == top.anchorDepth
  if closes:
    discard c.slashdashStack.pop()
    c.pendingEnds.add(CursorEvent(kind: ceSlashdashEnd, span: result.span))

type
  Checkpoint* = object
    ## Opaque snapshot of cursor state. O(1) to capture, O(state) to
    ## restore. The slashdash stack + pending queue are sequence-typed,
    ## so a checkpoint owns its own copies (the cursor's mutations
    ## after pos() can't see-through into a saved Checkpoint).
    tokIdx*: int
    state*: CursorState
    argIdx*: int
    depth*: int
    pendingEnds*: seq[CursorEvent]
    slashdashStack*: seq[PendingSlashdash]
    halted*: bool

proc pos*(c: StringCursor): Checkpoint =
  Checkpoint(tokIdx: c.tokIdx, state: c.state, argIdx: c.argIdx,
             depth: c.depth, pendingEnds: c.pendingEnds,
             slashdashStack: c.slashdashStack, halted: c.halted)

proc seek*(c: var StringCursor, ck: Checkpoint) =
  c.tokIdx = ck.tokIdx
  c.state = ck.state
  c.argIdx = ck.argIdx
  c.depth = ck.depth
  c.pendingEnds = ck.pendingEnds
  c.slashdashStack = ck.slashdashStack
  c.halted = ck.halted

proc skip*(c: var StringCursor) =
  ## Consume events until the current node's ceNodeEnd is emitted.
  ## Contract: call immediately after a ceNodeBegin. On return the
  ## cursor is positioned to emit the next event after the node.
  ## Handles arbitrary children-block nesting within the skipped node.
  var childrenDepth = 0
  while true:
    let ev = advance(c)
    case ev.kind
    of ceChildrenBegin: inc childrenDepth
    of ceChildrenEnd:   dec childrenDepth
    of ceNodeEnd:
      if childrenDepth == 0: return
    of ceEof, ceError:  return
    else: discard

proc peek*(c: StringCursor): CursorEvent =
  ## Return the next event without consuming it. Two consecutive
  ## peeks are idempotent. Implemented as save → advance → restore;
  ## costs a Checkpoint copy per call (cheap for small stacks).
  var tmp = c
  result = advance(tmp)

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

type
  KdlCursor* = concept c, var mc
    ## The grammar-aware cursor concept. Any type providing this
    ## surface can act as the foundation for Cat 1 / Cat 2 / Cat 3
    ## consumers. StringCursor is the default impl. Future impls:
    ## TokenListCursor (tests without lexer), IncrementalCursor (LSP).
    peek(c) is CursorEvent
    advance(mc) is CursorEvent
    skip(mc)
    bytes(c, 0) is string
    pos(c) is Checkpoint
    seek(mc, Checkpoint())
