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

import std/macros

import ./ast
import ./fnv
import ./intern
import ./lexer
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
    ## Span-bearing event. Token indices are `int32` (cap 2.1B —
    ## effectively unlimited) so the 3-index variants pack into 12
    ## bytes instead of 24, shrinking the whole struct from 48B to
    ## 24B on x86-64. `err` is a `ref ParseError` so the error path
    ## stays heap-allocated (rare; one per error) and the common
    ## success path doesn't pay for a 32-byte inline ParseError
    ## per event.
    span*: Span
    case kind*: CursorEventKind
    of ceNodeBegin:
      nodeNameTok*: int32
      nodeAnnoTok*: int32   # -1 if absent
    of ceArg:
      argIdx*: int32
      argTok*: int32
      argAnnoTok*: int32    # -1 if absent
    of ceProp:
      propKeyTok*: int32
      propValueTok*: int32
      propAnnoTok*: int32   # -1 if absent
    of ceError:
      err*: ref ParseError
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
    peekedValid*: bool
    peekedEvent*: CursorEvent

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

proc heapErr(pe: sink ParseError): ref ParseError {.inline.} =
  ## Box a ParseError onto the heap for embedding in a CursorEvent.
  ## Per the cursor RFC (B-option for size compaction): every ceError
  ## carries `ref ParseError` instead of inline ParseError, which keeps
  ## CursorEvent at 24 bytes (return-in-registers eligible on SysV)
  ## without losing self-containedness for accumulating-mode
  ## consumers (each event still owns its own error).
  new(result)
  result[] = pe

proc rejectAfterChildren(c: var StringCursor, span: Span): CursorEvent =
  let pe = initError(peParseUnexpected, span,
                     "entries are not permitted after a children block")
  case c.mode
  of cmSingle: c.halted = true
  of cmAccumulating: inc c.tokIdx
  CursorEvent(kind: ceError, span: span, err: heapErr(pe))

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
  CursorEvent(kind: ceError, span: span, err: heapErr(pe))

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
  CursorEvent(kind: ceError, span: span, err: heapErr(pe))

proc bytes*(c: StringCursor, tokIdx: int): string {.inline.} =
  ## Token payload as a freshly-copied string. Ergonomic — binds anywhere
  ## (let, var, check). For compile-time-known-literal hot-path dispatch
  ## use `bytesEqLit`.
  let t = c.stream[].tokens[tokIdx]
  result = c.source[int(t.span.offset) ..< int(t.span.endOffset)]

macro bytesEqLit*(c: untyped, tokIdx: untyped, s: static[string]): bool =
  ## Compile-time-folded byte comparison of the token at `tokIdx`
  ## against the static literal `s`. The macro expands to inline
  ## byte loads + equality checks that the compiler folds (and
  ## often vectorizes) because every operand is known at compile
  ## time — both the length check and each byte's expected value.
  ##
  ## Benchmarks vs the previous template-based bytesEq (which used
  ## C `equalMem`): ~22% faster per call for typical 4-12 byte
  ## keys (2.29 vs 2.79 ns), AND works in NimVM without a `when
  ## nimvm` branch (no `addr` or FFI involved), AND is a single
  ## codepath.
  ##
  ## This is the codegen-emitted hot path's comparison primitive.
  ## A runtime-bytes-vs-runtime-bytes comparison still needs the
  ## utility helper at runtime; we don't have a consumer for that
  ## currently, so cursor.nim no longer carries one.
  let tokSym = genSym(nskLet, "tok")
  let offSym = genSym(nskLet, "off")
  let n = s.len
  let nLit = newIntLitNode(n)
  let lenCheck = quote do:
    int(`tokSym`.span.length) == `nLit`
  if n == 0:
    return quote do:
      block:
        let `tokSym` = `c`.stream[].tokens[`tokIdx`]
        `lenCheck`
  var byteChain: NimNode = nil
  for i in 0 ..< n:
    let charLit = newLit(s[i])
    let idxLit = newIntLitNode(i)
    let access = quote do:
      `c`.source[`offSym` + `idxLit`]
    let cmpExpr = quote do:
      `access` == `charLit`
    if byteChain == nil:
      byteChain = cmpExpr
    else:
      byteChain = infix(byteChain, "and", cmpExpr)
  result = quote do:
    block:
      let `tokSym` = `c`.stream[].tokens[`tokIdx`]
      let `offSym` = int(`tokSym`.span.offset)
      `lenCheck` and `byteChain`

proc tokenBytesHash*(c: StringCursor, tokIdx: int): uint32 {.inline.} =
  ## FNV-1a 32-bit hash over the source bytes of token at `tokIdx`.
  ## Used by deriveDecode's perfect-hash kdlProp dispatch (Stage D5).
  ## The macro precomputes hashes for known wire-keys at compile time
  ## and emits a `case tokenBytesHash(c, propKeyTok):` dispatch with
  ## those compile-time constants as branch labels — O(1) prop lookup
  ## for wide types. Each branch still bytesEqLit-confirms (handles
  ## the astronomically unlikely runtime collision from an unknown key).
  let t = c.stream[].tokens[tokIdx]
  let o = int(t.span.offset)
  let n = int(t.span.length)
  result = 0x811C9DC5'u32
  for i in 0 ..< n:
    result = result xor uint32(uint8(c.source[o + i]))
    result = result * 0x01000193'u32

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
    return CursorEvent(kind: ceError, span: t.span, err: heapErr(pe))

  case c.state
  of csTopLevel:
    let t = c.tok
    case t.kind
    of tkEof:
      if c.depth > 0:
        let pe = initError(peParseExpected, t.span,
                           "unclosed children block at end of input")
        c.halted = true
        return CursorEvent(kind: ceError, span: t.span, err: heapErr(pe))
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
        return CursorEvent(kind: ceError, span: sdSpan, err: heapErr(pe))
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
        let p = tokenText(c.stream[], nameTok)
        if containsBidiControl(p):
          let pe = initError(peLexInvalidIdentifier, nameTok.span,
                             "bidi control codepoint in node name")
          c.halted = true
          return CursorEvent(kind: ceError, span: nameTok.span, err: heapErr(pe))
      elif nameTok.kind == tkRawString:
        let p = tokenText(c.stream[], nameTok)
        if containsBidiControl(p):
          let pe = initError(peLexInvalidIdentifier, nameTok.span,
                             "bidi control codepoint in node name")
          c.halted = true
          return CursorEvent(kind: ceError, span: nameTok.span, err: heapErr(pe))
      let nameIdx = c.tokIdx
      inc c.tokIdx
      c.state = csInNodeEntries
      c.argIdx = 0
      c.nodeFrames.add(NodeFrame(seenRealChildren: false))
      return CursorEvent(kind: ceNodeBegin, span: nameTok.span,
                         nodeNameTok: int32(nameIdx), nodeAnnoTok: int32(annoIdx))
    of tkString, tkRawString:
      # Quoted/raw-string node name (no type annotation prefix).
      if t.kind == tkString:
        let p = tokenText(c.stream[], t)
        if containsBidiControl(p):
          let pe = initError(peLexInvalidIdentifier, t.span,
                             "bidi control codepoint in node name")
          c.halted = true
          return CursorEvent(kind: ceError, span: t.span, err: heapErr(pe))
      else:
        let p = tokenText(c.stream[], t)
        if containsBidiControl(p):
          let pe = initError(peLexInvalidIdentifier, t.span,
                             "bidi control codepoint in node name")
          c.halted = true
          return CursorEvent(kind: ceError, span: t.span, err: heapErr(pe))
      let nameIdx = c.tokIdx
      inc c.tokIdx
      c.state = csInNodeEntries
      c.argIdx = 0
      c.nodeFrames.add(NodeFrame(seenRealChildren: false))
      return CursorEvent(kind: ceNodeBegin, span: t.span,
                         nodeNameTok: int32(nameIdx), nodeAnnoTok: -1)
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
                         nodeNameTok: int32(nameIdx), nodeAnnoTok: -1)
    else:
      let pe = initError(peParseUnexpected, t.span,
                         "unexpected token at node boundary")
      case c.mode
      of cmSingle: c.halted = true
      of cmAccumulating: inc c.tokIdx
      return CursorEvent(kind: ceError, span: t.span, err: heapErr(pe))
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
        return CursorEvent(kind: ceError, span: t.span, err: heapErr(pe))
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
        return CursorEvent(kind: ceError, span: sdSpan, err: heapErr(pe))
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
                         argIdx: int32(myArgIdx), argTok: int32(valIdx), argAnnoTok: int32(annoIdx))
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
                         argIdx: int32(myArgIdx), argTok: int32(valIdx), argAnnoTok: -1)
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
          let p = tokenText(c.stream[], t)
          if containsBidiControl(p):
            let pe = initError(peLexInvalidIdentifier, t.span,
                               "bidi control codepoint in property key")
            c.halted = true
            return CursorEvent(kind: ceError, span: t.span, err: heapErr(pe))
        else:
          let p = tokenText(c.stream[], t)
          if containsBidiControl(p):
            let pe = initError(peLexInvalidIdentifier, t.span,
                               "bidi control codepoint in property key")
            c.halted = true
            return CursorEvent(kind: ceError, span: t.span, err: heapErr(pe))
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
          return CursorEvent(kind: ceError, span: t.span, err: heapErr(pe))
        if c.stream[].tokens[valIdx].kind == tkLParen:
          if valIdx + 3 >= c.stream[].tokens.len:
            let pe = initError(peParseExpected, t.span,
                               "property value has malformed annotation")
            case c.mode
            of cmSingle: c.halted = true
            of cmAccumulating: inc c.tokIdx
            return CursorEvent(kind: ceError, span: t.span, err: heapErr(pe))
          annoIdx = valIdx + 1
          valIdx += 3
        c.tokIdx = valIdx + 1
        return CursorEvent(kind: ceProp, span: t.span,
                           propKeyTok: int32(keyIdx), propValueTok: int32(valIdx),
                           propAnnoTok: int32(annoIdx))
      else:
        let valIdx = c.tokIdx
        let myArgIdx = c.argIdx
        inc c.argIdx
        inc c.tokIdx
        return CursorEvent(kind: ceArg, span: t.span,
                           argIdx: int32(myArgIdx), argTok: int32(valIdx), argAnnoTok: -1)
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
          return CursorEvent(kind: ceError, span: t.span, err: heapErr(pe))
        if c.stream[].tokens[valIdx].kind == tkLParen:
          if valIdx + 3 >= c.stream[].tokens.len:
            let pe = initError(peParseExpected, t.span,
                               "property value has malformed annotation")
            case c.mode
            of cmSingle: c.halted = true
            of cmAccumulating: inc c.tokIdx
            return CursorEvent(kind: ceError, span: t.span, err: heapErr(pe))
          annoIdx = valIdx + 1
          valIdx += 3   # past `(`, tag, `)`
        c.tokIdx = valIdx + 1
        return CursorEvent(kind: ceProp, span: t.span,
                           propKeyTok: int32(keyIdx), propValueTok: int32(valIdx),
                           propAnnoTok: int32(annoIdx))
      else:
        let valIdx = c.tokIdx
        let myArgIdx = c.argIdx
        inc c.argIdx
        inc c.tokIdx
        return CursorEvent(kind: ceArg, span: t.span,
                           argIdx: int32(myArgIdx), argTok: int32(valIdx), argAnnoTok: -1)
    else:
      let pe = initError(peParseUnexpected, t.span,
                         "unexpected token in node entries")
      case c.mode
      of cmSingle: c.halted = true
      of cmAccumulating: inc c.tokIdx
      return CursorEvent(kind: ceError, span: t.span, err: heapErr(pe))

proc advance*(c: var StringCursor): CursorEvent =
  ## Public entry point: drains queued events first, then generates the
  ## next grammar event, then inspects the slashdash stack to see if the
  ## just-emitted event closes a bracket (queuing SlashdashEnd if so).
  if c.peekedValid:
    c.peekedValid = false
    return c.peekedEvent
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
    # nodeFrames + childrenIsSlashdashed are part of the cursor's mutable
    # state and MUST be snapshotted too: they carry the per-node
    # "seen children" flags that drive the post-children adjacency rules.
    # Omitting them made a mid-node seek() forget the node's children and
    # accept illegal trailing entries. Private types → unexported fields;
    # Checkpoint is opaque anyway.
    nodeFrames: seq[NodeFrame]
    childrenIsSlashdashed: seq[bool]
    halted*: bool
    peekedValid*: bool
    peekedEvent*: CursorEvent

proc pos*(c: StringCursor): Checkpoint =
  Checkpoint(tokIdx: c.tokIdx, state: c.state, argIdx: c.argIdx,
             depth: c.depth, pendingEnds: c.pendingEnds,
             slashdashStack: c.slashdashStack,
             nodeFrames: c.nodeFrames,
             childrenIsSlashdashed: c.childrenIsSlashdashed,
             halted: c.halted,
             peekedValid: c.peekedValid, peekedEvent: c.peekedEvent)

proc seek*(c: var StringCursor, ck: Checkpoint) =
  c.tokIdx = ck.tokIdx
  c.state = ck.state
  c.argIdx = ck.argIdx
  c.depth = ck.depth
  c.pendingEnds = ck.pendingEnds
  c.slashdashStack = ck.slashdashStack
  c.nodeFrames = ck.nodeFrames
  c.childrenIsSlashdashed = ck.childrenIsSlashdashed
  c.halted = ck.halted
  c.peekedValid = ck.peekedValid
  c.peekedEvent = ck.peekedEvent

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

proc peek*(c: var StringCursor): CursorEvent =
  ## Return the next event without consuming it. Two consecutive
  ## peeks are idempotent.
  ##
  ## Uses an in-cursor one-event lookahead cache. The first peek
  ## runs the state machine and stashes the result on the cursor;
  ## subsequent peeks return the cached value. The next `advance`
  ## drains the cache. Replaces the old "copy cursor → advance copy"
  ## which allocated for the cursor's seq fields per call.
  if c.peekedValid:
    return c.peekedEvent
  c.peekedEvent = advance(c)
  c.peekedValid = true
  c.peekedEvent


type
  KdlCursor* = concept c, var mc
    ## The grammar-aware cursor concept. Any type providing this
    ## surface can act as the foundation for Cat 1 / Cat 2 / Cat 3
    ## consumers. StringCursor is the default impl. Future impls:
    ## TokenListCursor (tests without lexer), IncrementalCursor (LSP).
    peek(mc) is CursorEvent
    advance(mc) is CursorEvent
    skip(mc)
    bytes(c, 0) is string
    pos(c) is Checkpoint
    seek(mc, Checkpoint())
