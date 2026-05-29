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
import ./intern
import ./lexer
import ./spans

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
    csAfterChildren     ## a `}` just closed a children block; next event is NodeEnd for the parent

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
    mode*: CursorMode
    halted*: bool      ## set after a ceError in single-shot mode; subsequent advance() returns ceEof

proc initStringCursor*(stream: ptr TokenStream, source: string,
                       mode: CursorMode = cmSingle): StringCursor =
  StringCursor(stream: stream, source: source, tokIdx: 0,
               state: csTopLevel, mode: mode)

template tok(c: StringCursor): Token =
  c.stream[].tokens[c.tokIdx]

proc tryConsumeAnno(c: var StringCursor): int =
  ## If `tok` is `(` followed by `tag )`, parse + return the tag's
  ## token index. Otherwise return -1 and leave tokIdx untouched.
  ## Caller decides whether to emit ceError or recover.
  if c.tok.kind != tkLParen:
    return -1
  let n = c.stream[].tokens.len
  if c.tokIdx + 2 >= n: return -1
  let closeKind = c.stream[].tokens[c.tokIdx + 2].kind
  if closeKind != tkRParen: return -1
  let tagIdx = c.tokIdx + 1
  c.tokIdx += 3
  tagIdx

proc emitMalformedAnnoError(c: var StringCursor, span: Span): CursorEvent =
  ## Construct a synthetic ceError for a malformed `(tag)` annotation.
  ## Single-shot mode halts; accumulating mode recovers by stepping
  ## past the stray `(` so subsequent advance() can re-sync.
  let pe = initError(peParseUnexpected, span,
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

proc peekSlashdashKind(c: StringCursor): SlashdashKind =
  ## Determine which kind of slashdash this is based on what follows the `/-`.
  ## Caller has confirmed c.tok is tkSlashDash.
  let next = c.stream[].tokens[c.tokIdx + 1]
  case next.kind
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
      return CursorEvent(kind: ceEof, span: t.span)
    of tkSlashDash:
      let kind = peekSlashdashKind(c)
      inc c.tokIdx
      c.slashdashStack.add(PendingSlashdash(kind: kind, anchorDepth: c.depth))
      return CursorEvent(kind: ceSlashdashBegin, span: t.span)
    of tkLParen:
      let annoIdx = tryConsumeAnno(c)
      if annoIdx == -1:
        return emitMalformedAnnoError(c, t.span)
      let nameTok = c.tok
      if nameTok.kind != tkIdent:
        return emitMalformedAnnoError(c, t.span)
      let nameIdx = c.tokIdx
      inc c.tokIdx
      c.state = csInNodeEntries
      c.argIdx = 0
      return CursorEvent(kind: ceNodeBegin, span: nameTok.span,
                         nodeNameTok: nameIdx, nodeAnnoTok: annoIdx)
    of tkRBrace:
      # Close of a children block. depth=0 here would be a stray brace
      # (error case — to be wired in Cycle 15+).
      inc c.tokIdx
      dec c.depth
      c.state = csAfterChildren
      return CursorEvent(kind: ceChildrenEnd, span: t.span)
    of tkIdent:
      let nameIdx = c.tokIdx
      inc c.tokIdx
      c.state = csInNodeEntries
      c.argIdx = 0
      return CursorEvent(kind: ceNodeBegin, span: t.span,
                         nodeNameTok: nameIdx, nodeAnnoTok: -1)
    else:
      return CursorEvent(kind: ceEof, span: t.span)
  of csInNodeEntries:
    let t = c.tok
    case t.kind
    of tkEof:
      c.state = csTopLevel
      return CursorEvent(kind: ceNodeEnd, span: t.span)
    of tkNewline, tkSemicolon:
      inc c.tokIdx
      c.state = csTopLevel
      return CursorEvent(kind: ceNodeEnd, span: t.span)
    of tkRBrace:
      # End-of-children terminates the current node implicitly without
      # consuming the brace; outer csTopLevel will emit ChildrenEnd next.
      c.state = csTopLevel
      return CursorEvent(kind: ceNodeEnd, span: t.span)
    of tkLBrace:
      inc c.tokIdx
      inc c.depth
      c.state = csTopLevel
      return CursorEvent(kind: ceChildrenBegin, span: t.span)
    of tkSlashDash:
      let kind = peekSlashdashKind(c)
      inc c.tokIdx
      c.slashdashStack.add(PendingSlashdash(kind: kind, anchorDepth: c.depth))
      return CursorEvent(kind: ceSlashdashBegin, span: t.span)
    of tkLParen:
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
    of tkNumber, tkString, tkRawString, tkKeyword:
      let valIdx = c.tokIdx
      let myArgIdx = c.argIdx
      inc c.argIdx
      inc c.tokIdx
      return CursorEvent(kind: ceArg, span: t.span,
                         argIdx: myArgIdx, argTok: valIdx, argAnnoTok: -1)
    of tkIdent:
      let nextKind = c.stream[].tokens[c.tokIdx + 1].kind
      if nextKind == tkEquals:
        let keyIdx = c.tokIdx
        var valIdx = c.tokIdx + 2
        var annoIdx = -1
        # Prop value may carry an annotation: key = (tag) value
        if c.stream[].tokens[valIdx].kind == tkLParen:
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
      return CursorEvent(kind: ceEof, span: t.span)
  of csAfterChildren:
    # ChildrenEnd was emitted; now emit the parent's NodeEnd implicitly.
    c.state = csTopLevel
    return CursorEvent(kind: ceNodeEnd, span: c.tok.span)

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

proc buildDoc*(c: var StringCursor, sourcePath = "<input>"):
    Result[KdlDoc, ParseError] {.noSideEffect.} =
  ## Cat 3 (AST/DOM) consumer: fold cursor events into a KdlDoc using
  ## an explicit `seq[KdlNode]` stack. Replaces the visitor-protocol
  ## DocBuilder. The cursor is driven to ceEof (single-shot mode);
  ## any ceError surfaces as Err.
  var doc = newDoc(sourcePath)
  doc.sourceText = c.source
  while true:
    let ev = advance(c)
    case ev.kind
    of ceNodeBegin:
      let name = doc.interner.intern(bytes(c, ev.nodeNameTok))
      var node = newNode(doc, "", ev.span)
      node.name = name
      doc.nodes.add(node)   # placeholder; replaced on NodeEnd via stack indexing
    of ceEof:
      doc.parseTopLevelCount = int32(doc.nodes.len)
      return ok[KdlDoc, ParseError](doc)
    of ceError:
      return err[KdlDoc, ParseError](ev.err)
    else: discard

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
