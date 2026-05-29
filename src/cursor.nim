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

proc initStringCursor*(stream: ptr TokenStream, source: string): StringCursor =
  StringCursor(stream: stream, source: source, tokIdx: 0, state: csTopLevel)

template tok(c: StringCursor): Token =
  c.stream[].tokens[c.tokIdx]

proc tryConsumeAnno(c: var StringCursor): int =
  ## If `tok` is `(`, parse `( tag )` and return the tag's token index.
  ## Otherwise return -1. Caller is left positioned past the closing `)`.
  if c.tok.kind != tkLParen:
    return -1
  let tagIdx = c.tokIdx + 1
  # Minimal Phase 1 form: assume (ident) or (string). Strict validation
  # comes with the error-path work in Cycle 15.
  c.tokIdx += 3  # consume `(`, tag, `)`
  tagIdx

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
      let nameTok = c.tok
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
