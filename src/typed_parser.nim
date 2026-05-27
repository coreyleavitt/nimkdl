## Visitor-based typed parser. The first part of the typed-direct path
## architecture from issue #1.
##
## ## Design (per "E′" recommendation, see issue #1 discussion)
##
## One grammar, many visitors. The parser walks the token stream and
## dispatches into the visitor's methods. Visitors that live in tree:
##   - `DocBuilder` (src/doc_builder.nim) builds the existing `KdlDoc`
##   - `TypedBuilder[T]` (generated from a type inside a `kdl:` block)
##     writes directly into a typed T value
##
## Visitors are duck-typed: any object with the required methods
## satisfies the protocol. The compiler monomorphizes per-visitor so
## the dispatch is static and inline-able.
##
## ## Capability-driven specialization
##
## Each visitor declares a `visitorCaps` template returning a compile-
## time `set[VisitorCap]`. parseDocumentWith branches on `when X in
## visitorCaps(V):` so visitors that don't need a feature don't pay for
## the routing code. Zero abstraction tax: TypedBuilder's hot path
## stays identical to before this refactor.
##
## ## Visitor protocol (core methods, required for all visitors)
##
##   proc visitBeginNode(v: var V, nameStr: openArray[char], nodeSpan: Span):
##       Result[void, ParseError]
##   proc visitArg(v: var V, idx: int, tok: Token, stream: TokenStream):
##       Result[void, ParseError]
##   proc visitProp(v: var V, keyStr: openArray[char],
##                  tok: Token, stream: TokenStream):
##       Result[void, ParseError]
##   proc visitBeginChildren(v: var V): Result[void, ParseError]
##   proc visitEndChildren(v: var V): Result[void, ParseError]
##   proc visitEndNode(v: var V): Result[void, ParseError]
##
## Optional methods (only required if the corresponding cap is declared):
##   visitNodeTypeAnno, visitValueTypeAnno   (vcNodeAnno / vcValueAnno)
##   visitSlashdash                          (vcSlashdash)
##
## All methods return `Result[void, ParseError]` so errors propagate
## without raising (preserves `embed[T]` compile-time-eval semantics).

import ./[lexer, intern, spans]

const MaxParserDepthValue* = 256
  ## Maximum recursion depth through `{ children }` blocks. Re-exported
  ## as `parser.MaxParserDepth` (re-export through a different name to
  ## avoid the symbol clash when both modules are imported via `kdl`).
const MaxParserDepth = MaxParserDepthValue

const MaxAccumulatedErrors* = 1024
  ## Hard cap on accumulating-mode (`errorBuf`) parser-error growth.
  ## A pathological input (e.g. a giant malformed document fed to
  ## `decodeAll`) could otherwise grow the error buffer in proportion
  ## to source size, with non-trivial per-ParseError overhead. Beyond
  ## the cap, accumulation stops and the parser returns early. 1024 is
  ## chosen as well past the "I want to see every error in my config"
  ## use case (which is typically dozens, never thousands) while still
  ## giving a generous batch-lint ceiling.

type
  VisitorCap* = enum
    ## Capabilities a visitor opts into. parseDocumentWith gates routing
    ## code per cap so unused features cost nothing.
    vcArgs            ## visitArg events for positional values
    vcProps           ## visitProp events for `key=value`
    vcChildren        ## visitBeginChildren / visitEndChildren + recursion
    vcNodeAnno        ## visitNodeTypeAnno before visitBeginNode
    vcValueAnno       ## visitValueTypeAnno before visitArg / visitProp
    vcSlashdash       ## visitSlashdash before slashdash'd thing

func openArrayToString*(s: openArray[char]): string {.noSideEffect.} =
  ## VM-friendly conversion. `cast[string](@seq[char])` blows up in
  ## NimVM ("does not support 'cast' from tySequence to tyString"); a
  ## newString + byte-copy works both at runtime and at compile time.
  ## Used in error messages only — the hot-path dispatch uses bytesEq.
  result = newString(s.len)
  for i in 0 ..< s.len: result[i] = s[i]

func bytesEq*(s: openArray[char], lit: static string): bool
    {.inline, noSideEffect.} =
  ## Zero-alloc byte compare against a compile-time-known string.
  if s.len != lit.len: return false
  for i in 0 ..< lit.len:
    if s[i] != lit[i]: return false
  true

# ---------------------------------------------------------------------------
# Recovery helpers (accumulating-mode only — used by parseAllWith)
# ---------------------------------------------------------------------------

proc skipToRecovery(stream: TokenStream, cursor: var int) {.noSideEffect.} =
  ## Top-level node-level recovery: advance past the failed construct,
  ## stop at + consume the next node terminator (newline, `;`, `}`, EOF).
  while cursor < stream.tokens.len:
    let k = stream.tokens[cursor].kind
    if k == tkEof: return
    if k == tkRBrace: return  # let the enclosing children loop handle
    inc cursor
    if k == tkNewline or k == tkSemicolon: return

proc skipToBlockBoundary(stream: TokenStream, cursor: var int)
    {.noSideEffect.} =
  ## Children-block recovery: balanced-brace-aware skip. Stops at a
  ## newline / `;` at depth 0 (consumed) or at the current scope's
  ## closing `}` / EOF (not consumed).
  var depth = 0
  while cursor < stream.tokens.len:
    let k = stream.tokens[cursor].kind
    if k == tkEof: return
    if depth == 0 and k == tkRBrace: return
    if depth == 0 and (k == tkNewline or k == tkSemicolon):
      inc cursor
      return
    if k == tkLBrace: inc depth
    elif k == tkRBrace: dec depth
    inc cursor

proc skipToEntryBoundary(stream: TokenStream, cursor: var int)
    {.noSideEffect.} =
  ## Entry-level recovery inside a node: advance until the next safe
  ## resume position — a node terminator OR a fresh entry-start token.
  ## Doesn't consume terminators (the entry loop's normal break handles
  ## them). Forward progress is the caller's responsibility.
  while cursor < stream.tokens.len:
    let k = stream.tokens[cursor].kind
    if k in {tkNewline, tkSemicolon, tkLBrace, tkRBrace, tkEof}: return
    # An entry-start token preceded by whitespace = safe resume point.
    if stream.tokens[cursor].precededByWs and
       k in {tkIdent, tkString, tkRawString, tkNumber, tkKeyword,
             tkLParen, tkSlashDash}:
      return
    inc cursor

proc parseInto*[T](source: string, sourcePath = "<input>"):
    Result[T, ParseError] =
  ## Typed entry point. Resolves the `kdlBuildVisitor` /
  ## `kdlBuildVisitorSeq` overload emitted for `T` (via its enclosing
  ## `kdl:` block) at instantiation time.
  mixin kdlBuildVisitor, kdlBuildVisitorSeq
  when T is seq:
    type Elem = typeof(default(T)[0])
    kdlBuildVisitorSeq(Elem, source, sourcePath)
  else:
    kdlBuildVisitor(T, source, sourcePath)

# ---------------------------------------------------------------------------
# parseDocumentWith — visitor-parameterized parser
# ---------------------------------------------------------------------------

proc parseNodeWith[V](source: string, visitor: var V,
                      stream: TokenStream, cursor: var int,
                      skip: bool = false, depth: int = 0,
                      errorBuf: ptr seq[ParseError] = nil):
    Result[void, ParseError] {.noSideEffect.}

proc parseDocumentWith*[V](source: string, visitor: var V,
                           sourcePath = "<input>",
                           errorBuf: ptr seq[ParseError] = nil):
    Result[void, ParseError] {.noSideEffect.} =
  ## Walks every top-level node in `source` through `visitor`.
  ##
  ## A leading `/-` slashdash-marks the next node as discarded — its
  ## tokens are still parsed (so syntax errors inside it surface), but
  ## no visitor events fire for it.
  ##
  ## `errorBuf` (default nil) — when non-nil, switches to accumulating
  ## mode: lex errors and parseNodeWith failures are pushed to the
  ## buffer and the parser re-syncs at the next node terminator to keep
  ## going (parseAll's contract). When nil, the first error returns
  ## immediately (parse's contract).
  mixin visitorCaps
  var interner = initInterner()
  interner.disabled = true   # visitors read bytes from source directly
  let stream = lex(source, interner)
  for t in stream.tokens:
    if t.kind == tkError:
      if errorBuf.isNil:
        return err[void, ParseError](stream.errorPayloads[t.errIdx])
      # Cap accumulation: a pathological input with thousands of lex
      # errors (e.g. high-bit bytes sprinkled through MB-sized input)
      # would otherwise grow errorBuf in proportion to source size.
      # Same MaxAccumulatedErrors ceiling as the per-node loop below.
      if errorBuf[].len >= MaxAccumulatedErrors: break
      errorBuf[].add(stream.errorPayloads[t.errIdx])

  var cursor = 0
  template peek(off = 0): Token =
    if cursor + off < stream.tokens.len: stream.tokens[cursor + off]
    else: Token(kind: tkEof, span: pointSpan(StartPosition))

  while true:
    while peek().kind == tkNewline or peek().kind == tkSemicolon: inc cursor
    var skipNode = false
    if peek().kind == tkSlashDash:
      let sdSpan = peek().span
      inc cursor
      while peek().kind == tkNewline: inc cursor
      skipNode = true
      if peek().kind == tkEof:
        if errorBuf.isNil:
          return err[void, ParseError](initError(peParseExpected, sdSpan,
            "'/-' must be followed by a node"))
        errorBuf[].add(initError(peParseExpected, sdSpan,
          "'/-' must be followed by a node"))
        break
    if peek().kind == tkEof: break
    # Cap accumulating-mode errors per MaxAccumulatedErrors. The cap is
    # measured on the visitor's `errorBuf` slice we own here; the visitor
    # may also keep a separate buffer (e.g. the seq wrapper's `errors`)
    # which it bounds on its own side. Stopping at the cap is the
    # parser-side defense against pathological inputs.
    if not errorBuf.isNil and errorBuf[].len >= MaxAccumulatedErrors: break
    let savedCursor = cursor
    let r = parseNodeWith(source, visitor, stream, cursor,
                          skip = skipNode, depth = 0, errorBuf = errorBuf)
    if r.isErr:
      if errorBuf.isNil: return r
      errorBuf[].add(r.getErr)
      if cursor == savedCursor: inc cursor
      skipToRecovery(stream, cursor)

  ok(void, ParseError)

proc parseNodeWith[V](source: string, visitor: var V,
                      stream: TokenStream, cursor: var int,
                      skip: bool = false, depth: int = 0,
                      errorBuf: ptr seq[ParseError] = nil):
    Result[void, ParseError] {.noSideEffect.} =
  ## Parse one node + its entries + (recursively) its children.
  ## When `skip` is true, tokens are still parsed (preserving syntax-
  ## error surfaces) but no visitor events fire — used by slashdash.
  ## `depth` bounds children-block recursion at MaxParserDepth.
  mixin visitorCaps
  const caps = visitorCaps(V)

  template peek(off = 0): Token =
    if cursor + off < stream.tokens.len: stream.tokens[cursor + off]
    else: Token(kind: tkEof, span: pointSpan(StartPosition))

  if depth >= MaxParserDepth:
    return err[void, ParseError](initError(peParseDepthExceeded, peek().span,
      "nesting depth exceeded MaxParserDepth"))

  # Optional `(IDENT|STRING|RAW_STRING)` type annotation. Caps decide
  # whether the event can fire at all (compile-time); `noEmit` lets the
  # caller suppress emission per-call (runtime, used for slashdash'd
  # entries within an otherwise emitting parse).
  # `inLoop: static bool` — when true, errors recover via push+skip+
  # continue (entry-level); when false, errors return immediately
  # (caller handles node-level recovery).
  template handleTypeAnno(canEmit, inLoop: static bool, emitProc: untyped,
                          noEmit: bool) =
    if peek().kind == tkLParen:
      let lParenSpan = peek().span
      inc cursor
      let annoTok = peek()
      if annoTok.kind notin {tkIdent, tkString, tkRawString}:
        let e = initError(peParseExpected, annoTok.span,
          "expected identifier or string inside type annotation")
        when inLoop:
          if errorBuf.isNil: return err[void, ParseError](e)
          errorBuf[].add(e)
          skipToEntryBoundary(stream, cursor)
          continue
        else:
          return err[void, ParseError](e)
      inc cursor
      if peek().kind != tkRParen:
        let e = initError(peParseExpected, peek().span,
          "expected ')' to close type annotation")
        when inLoop:
          if errorBuf.isNil: return err[void, ParseError](e)
          errorBuf[].add(e)
          skipToEntryBoundary(stream, cursor)
          continue
        else:
          return err[void, ParseError](e)
      let rParenSpan = peek().span
      inc cursor
      when canEmit:
        if not noEmit:
          let annoSpan = initSpan(lParenSpan.start, rParenSpan.finish)
          case annoTok.kind
          of tkIdent:
            let s = annoTok.span.start.offset
            let l = annoTok.span.finish.offset - 1
            let r = visitor.emitProc(source.toOpenArray(s, l), annoSpan)
            if r.isErr: return r
          of tkString:
            let p = stream.stringPayloads[annoTok.strIdx]
            let r = visitor.emitProc(p.toOpenArray(0, p.high), annoSpan)
            if r.isErr: return r
          of tkRawString:
            let p = stream.rawStringPayloads[annoTok.rawIdx]
            let r = visitor.emitProc(p.toOpenArray(0, p.high), annoSpan)
            if r.isErr: return r
          else: discard  # unreachable

  template handleNodeAnno(noEmit: bool) =
    when vcNodeAnno in caps:
      handleTypeAnno(true, false, visitNodeTypeAnno, noEmit)
    else:
      handleTypeAnno(false, false, visitNodeTypeAnno, noEmit)

  template handleValueAnno(noEmit: bool) =
    when vcValueAnno in caps:
      handleTypeAnno(true, true, visitValueTypeAnno, noEmit)
    else:
      handleTypeAnno(false, true, visitValueTypeAnno, noEmit)

  handleNodeAnno(skip)   # optional (type) before node name

  let nameTok = peek()
  if nameTok.kind notin {tkIdent, tkString, tkRawString}:
    return err[void, ParseError](initError(peParseExpected, nameTok.span,
      "expected node name"))
  inc cursor

  # Bare ident → read from source (skips interner roundtrip).
  # Quoted/raw → use the lexer's payload table (escapes already
  # resolved). The visitor sees the SAME unescaped bytes either way.
  # Validate node-name shape (reject reserved barewords + bidi controls)
  # whether or not we'll emit — KDL v2 forbids these regardless.
  case nameTok.kind
  of tkIdent:
    # Reserved-bareword rejection happens at lex time (lexer emits
    # tkError for `inf`/`nan`/etc. before they ever reach here).
    let s = nameTok.span.start.offset
    let l = nameTok.span.finish.offset - 1
    if not skip:
      let bRes = visitor.visitBeginNode(source.toOpenArray(s, l), nameTok.span)
      if bRes.isErr: return bRes
  of tkString:
    let p = stream.stringPayloads[nameTok.strIdx]
    if containsBidiControl(p):
      return err[void, ParseError](initError(peLexInvalidIdentifier, nameTok.span,
        "bidi control codepoint in node name"))
    if not skip:
      let bRes = visitor.visitBeginNode(p.toOpenArray(0, p.high), nameTok.span)
      if bRes.isErr: return bRes
  of tkRawString:
    let p = stream.rawStringPayloads[nameTok.rawIdx]
    if containsBidiControl(p):
      return err[void, ParseError](initError(peLexInvalidIdentifier, nameTok.span,
        "bidi control codepoint in node name"))
    if not skip:
      let bRes = visitor.visitBeginNode(p.toOpenArray(0, p.high), nameTok.span)
      if bRes.isErr: return bRes
  else: discard   # unreachable

  var argIdx = 0
  # KDL v2 spec: once any children block (real or slashdash'd) has been
  # consumed, no more entries may appear. At most one REAL block may
  # contribute children; slashdash'd ones may freely interleave.
  var seenChildrenBlock = false
  var realChildrenSeen = false
  while true:
    # Entry-level slashdash: skips the next single entry OR children block.
    # Chained `/- /-` isn't valid grammar (the second /- has no entry to
    # skip), so single-`if` lookahead suffices and stays branch-predictable.
    # Single peek per iteration in the hot path. Cache up front; only
    # re-read after we've advanced cursor (slashdash consume / annotation
    # consume). Eliminates 2-3 redundant array-indexed reads per entry.
    var entryStartTok = peek()
    var entrySkip = skip
    var sawSlashdash = false
    if entryStartTok.kind == tkSlashDash:
      let sdSpan = entryStartTok.span
      inc cursor
      while peek().kind == tkNewline: inc cursor
      entrySkip = true
      sawSlashdash = true
      entryStartTok = peek()    # re-read after consuming /- and newlines
      if entryStartTok.kind in {tkNewline, tkSemicolon, tkEof, tkRBrace}:
        return err[void, ParseError](initError(peParseExpected, sdSpan,
          "'/-' must be followed by an entry or '{' children block"))

    let hadValueAnno = entryStartTok.kind == tkLParen
    var t = entryStartTok
    if hadValueAnno:
      handleValueAnno(entrySkip)
      # cursor advanced past `(type)` — refresh the value-token cache
      t = peek()

    # Fast-path dispatch. Cold-validation arms (hadValueAnno follow-ups,
    # entries-after-children, precededByWs) live inside the case branches
    # so the compiler only emits them in the paths where they can fire.
    case t.kind
    of tkNewline, tkSemicolon, tkEof, tkRBrace:
      if hadValueAnno:
        return err[void, ParseError](initError(peParseExpected, t.span,
          "type annotation must be followed by a value"))
      break
    of tkLBrace:
      # Children block. Inner nodes recurse through parseNodeWith with
      # skip = entrySkip; visitor children-boundary events fire iff
      # vcChildren is declared AND the enclosing node isn't skipped.
      if not entrySkip and realChildrenSeen:
        return err[void, ParseError](initError(peParseUnexpected, t.span,
          "a node may have at most one real children block"))
      inc cursor   # consume `{`
      seenChildrenBlock = true
      if not entrySkip:
        realChildrenSeen = true
      when vcChildren in caps:
        if not entrySkip:
          let bcRes = visitor.visitBeginChildren()
          if bcRes.isErr: return bcRes
      while true:
        # Inter-child separators: newline AND semicolon.
        while peek().kind == tkNewline or peek().kind == tkSemicolon: inc cursor
        if peek().kind == tkRBrace: break
        if peek().kind == tkEof:
          return err[void, ParseError](initError(peParseExpected, peek().span,
            "expected `}` to close children block"))
        # Inner-node slashdash within children
        var innerSkip = entrySkip
        if peek().kind == tkSlashDash:
          let sdSpan = peek().span
          inc cursor
          while peek().kind == tkNewline: inc cursor
          innerSkip = true
          if peek().kind == tkRBrace or peek().kind == tkEof:
            return err[void, ParseError](initError(peParseExpected, sdSpan,
              "'/-' must be followed by a child node"))
        when vcChildren in caps:
          let savedCursor = cursor
          let cRes = parseNodeWith(source, visitor, stream, cursor,
                                   skip = innerSkip, depth = depth + 1,
                                   errorBuf = errorBuf)
          if cRes.isErr:
            if errorBuf.isNil: return cRes
            errorBuf[].add(cRes.getErr)
            if cursor == savedCursor: inc cursor
            skipToBlockBoundary(stream, cursor)
            continue
        else:
          # Cap absent — walk and discard without recursion.
          var depth = 1
          while depth > 0 and peek().kind != tkEof:
            case peek().kind
            of tkLBrace: inc depth
            of tkRBrace: dec depth
            else: discard
            if depth > 0: inc cursor
          if peek().kind == tkRBrace: break
      inc cursor  # consume `}`
      when vcChildren in caps:
        if not entrySkip:
          let ecRes = visitor.visitEndChildren()
          if ecRes.isErr: return ecRes
      # KDL v2 grammar allows multiple slashdash'd children blocks +
      # at most one real one (validated by parser.nim, not here yet —
      # slice 9'.7). Loop to continue eating remaining /-{} blocks.
      continue
    of tkIdent, tkString, tkRawString:
      # Entry-shape validation. In accumulating mode, push the err and
      # skip to entry boundary so the node keeps going with its remaining
      # entries (matches parser.nim's parseAll behavior).
      if not sawSlashdash and not entryStartTok.precededByWs:
        let e = initError(peParseExpected, entryStartTok.span,
          "whitespace required before this entry")
        if errorBuf.isNil: return err[void, ParseError](e)
        errorBuf[].add(e)
        skipToEntryBoundary(stream, cursor)
        continue
      if seenChildrenBlock:
        let e = initError(peParseUnexpected, t.span,
          "entries are not permitted after a children block")
        if errorBuf.isNil: return err[void, ParseError](e)
        errorBuf[].add(e)
        skipToEntryBoundary(stream, cursor)
        continue
      if peek(1).kind == tkEquals:
        if hadValueAnno:
          return err[void, ParseError](initError(peParseExpected, t.span,
            "type annotation cannot precede a property key"))
        let keyTok = peek()
        cursor += 2
        handleValueAnno(entrySkip)
        let valueTok = peek()
        inc cursor
        # Validate key shape unconditionally — bare reserved keywords +
        # bidi-tainted quoted/raw keys are grammar-level errors that
        # apply to every visitor, even those without vcProps.
        # Entry span for props: keyTok start → valueTok finish (matches
        # parser.nim's `initSpan(keyTok.start, valueTok.finish)`).
        let entrySpan = initSpan(keyTok.span.start, valueTok.span.finish)
        case keyTok.kind
        of tkIdent:
          # Bare-keyword rejection already handled at lex time.
          let ks = keyTok.span.start.offset
          let kl = keyTok.span.finish.offset - 1
          when vcProps in caps:
            if not entrySkip:
              let pRes = visitor.visitProp(source.toOpenArray(ks, kl),
                                          valueTok, stream, entrySpan)
              if pRes.isErr:
                if errorBuf.isNil: return pRes
                errorBuf[].add(pRes.getErr)
                skipToEntryBoundary(stream, cursor)
                continue
        of tkString:
          let p = stream.stringPayloads[keyTok.strIdx]
          if containsBidiControl(p):
            return err[void, ParseError](initError(peLexInvalidIdentifier,
              keyTok.span, "bidi control codepoint in property key"))
          when vcProps in caps:
            if not entrySkip:
              let pRes = visitor.visitProp(p.toOpenArray(0, p.high),
                                          valueTok, stream, entrySpan)
              if pRes.isErr:
                if errorBuf.isNil: return pRes
                errorBuf[].add(pRes.getErr)
                skipToEntryBoundary(stream, cursor)
                continue
        of tkRawString:
          let p = stream.rawStringPayloads[keyTok.rawIdx]
          if containsBidiControl(p):
            return err[void, ParseError](initError(peLexInvalidIdentifier,
              keyTok.span, "bidi control codepoint in property key"))
          when vcProps in caps:
            if not entrySkip:
              let pRes = visitor.visitProp(p.toOpenArray(0, p.high),
                                          valueTok, stream, entrySpan)
              if pRes.isErr:
                if errorBuf.isNil: return pRes
                errorBuf[].add(pRes.getErr)
                skipToEntryBoundary(stream, cursor)
                continue
        else: discard   # unreachable
      else:
        # Arg value. tkIdent here is a bare-id string per KDL v2; the
        # reserved-keyword rejection happens at lex time so anything
        # reaching here is admissible. Bidi-control rejection for quoted
        # strings still happens here (lexer doesn't yet pre-classify those).
        if t.kind == tkString:
          let p = stream.stringPayloads[t.strIdx]
          if containsBidiControl(p):
            return err[void, ParseError](initError(peLexInvalidIdentifier,
              t.span, "bidi control codepoint in string value"))
        elif t.kind == tkRawString:
          let p = stream.rawStringPayloads[t.rawIdx]
          if containsBidiControl(p):
            return err[void, ParseError](initError(peLexInvalidIdentifier,
              t.span, "bidi control codepoint in string value"))
        inc cursor
        when vcArgs in caps:
          if not entrySkip:
            let entrySpan = initSpan(entryStartTok.span.start, t.span.finish)
            let aRes = visitor.visitArg(argIdx, t, stream, entrySpan)
            if aRes.isErr:
              if errorBuf.isNil: return aRes
              errorBuf[].add(aRes.getErr)
              skipToEntryBoundary(stream, cursor)
              continue
            inc argIdx
    of tkNumber, tkKeyword:
      if not sawSlashdash and not entryStartTok.precededByWs:
        return err[void, ParseError](initError(peParseExpected,
          entryStartTok.span, "whitespace required before this entry"))
      if seenChildrenBlock:
        return err[void, ParseError](initError(peParseUnexpected, t.span,
          "entries are not permitted after a children block"))
      inc cursor
      when vcArgs in caps:
        if not entrySkip:
          let entrySpan = initSpan(entryStartTok.span.start, t.span.finish)
          let aRes = visitor.visitArg(argIdx, t, stream, entrySpan)
          if aRes.isErr:
            if errorBuf.isNil: return aRes
            errorBuf[].add(aRes.getErr)
            skipToEntryBoundary(stream, cursor)
            continue
          inc argIdx
    else:
      let e = initError(peParseUnexpected, t.span,
        "unexpected token in node entries")
      if errorBuf.isNil: return err[void, ParseError](e)
      errorBuf[].add(e)
      # Ensure forward progress — `else`-branch tokens (e.g. tkEquals)
      # are NOT consumed by the case above, so skipToEntryBoundary would
      # stop right here. Bump once first.
      if cursor < stream.tokens.len: inc cursor
      skipToEntryBoundary(stream, cursor)
      continue

  if not skip:
    # Final span = start of first consumed token to end of last consumed
    # token. visitor.visitEndNode receives this so the visitor can stamp
    # KdlNode.span correctly (required by the preserve-format encoder
    # which uses spans to splice source bytes).
    let endOff =
      if cursor > 0: stream.tokens[cursor - 1].span.finish
      else: nameTok.span.finish
    let nodeFullSpan = initSpan(nameTok.span.start, endOff)
    let eRes = visitor.visitEndNode(nodeFullSpan)
    if eRes.isErr: return eRes
  ok(void, ParseError)

proc parseWith*[V](source: string, visitor: var V,
                   sourcePath = "<input>"): Result[void, ParseError] =
  ## Single-node convenience. Delegates to parseDocumentWith so the
  ## LBrace/children/recovery logic lives in one place.
  parseDocumentWith(source, visitor, sourcePath)
