## parser — KDL v2 recursive descent parser.
##
## Consumes the token stream from `lexer.lex` and produces a `KdlDoc`.
## Returns the first error encountered (lexer error tokens count) as
## a `Result.err`. The lexer keeps tokenizing past its own errors, so
## a single parse pass surfaces the first structural problem with full
## source position; if you need all errors at once (LSP / batch lint),
## extend this module with an error-collecting variant.
##
## ## Grammar (informal)
##
##   document   := node*
##   node       := slashdash? typeAnno? IDENT entry* children? terminator
##   entry      := slashdash? (property | argument)
##   property   := IDENT '=' value
##   argument   := value
##   value      := typeAnno? (STRING | RAW_STRING | NUMBER | KEYWORD | IDENT-as-bareword?)
##   typeAnno   := '(' IDENT ')'
##   children   := slashdash? '{' node* '}'
##   terminator := NEWLINE | ';' | EOF
##
## Slashdash (`/-`) is a token that skips the next thing:
##   - `/- node` skips the whole node + children
##   - `/- entry` skips that one entry
##   - `/- { … }` skips the children block
##
## ## Depth bounding
##
## Recursion through `children` blocks is bounded at `MaxParserDepth=256`
## frames. Real configs nest 5-6 levels; the cap is for malicious or
## buggy input. Mirrors the lib/cel pattern.
##
## ## Compile-time use
##
## All parse procs are `{.noSideEffect.}` so they can run at compile time.
## This is what makes `parse[T]` (#528) and `embed[T]` (#529) macros
## possible without escape hatches.

import ./ast
import ./encode  # hashNodeFromChildHashes (parser seeds n.parseHash for emPreserve)
import ./fnv     # Hash128
import ./intern
import ./lexer
import ./numlit
import ./reserved
import ./spans

const
  MaxParserDepth* = 256
    ## Maximum recursion depth through `{ children }` blocks.

type
  Parser = object
    stream: TokenStream
    cursor: int
    depth: int
    doc: KdlDoc
    errorBuf: ptr seq[ParseError]
      ## When non-nil, parseNode and parseEntry log errors here and
      ## skip to the next safe re-sync point instead of aborting. Set
      ## by parseAll; nil for the single-error `parse()` entry point.

# ---------------------------------------------------------------------------
# Token-stream helpers
# ---------------------------------------------------------------------------

func atEnd(p: Parser): bool {.inline.} =
  p.cursor >= p.stream.tokens.len or p.stream.tokens[p.cursor].kind == tkEof

func peek(p: Parser, ahead = 0): Token {.inline.} =
  if p.cursor + ahead < p.stream.tokens.len:
    p.stream.tokens[p.cursor + ahead]
  else:
    Token(kind: tkEof, span: pointSpan(StartPosition))

proc advance(p: var Parser): Token {.inline, noSideEffect.} =
  result = p.stream.tokens[p.cursor]
  inc p.cursor

proc check(p: Parser, kind: TokenKind): bool {.inline, noSideEffect.} =
  p.peek.kind == kind

proc skipNewlines(p: var Parser) {.noSideEffect.} =
  while p.check(tkNewline):
    discard p.advance()

# ---------------------------------------------------------------------------
# Value parsing
# ---------------------------------------------------------------------------

proc parseTypeAnno(p: var Parser): Result[InternedStr, ParseError] {.noSideEffect.} =
  ## Consumes `(name)`. Name is a bare ident OR quoted string (incl. "").
  ## Caller has already confirmed the leading `(`.
  discard p.advance()  # consume `(`
  var handle: InternedStr
  case p.peek.kind
  of tkIdent:
    handle = p.advance().ident
  of tkString:
    let tok = p.advance()
    if containsBidiControl(p.stream.stringPayloads[tok.strIdx]):
      return err[InternedStr, ParseError](initError(peLexInvalidIdentifier,
        tok.span, "bidi control codepoint in type annotation name"))
    handle = p.doc.interner.intern(p.stream.stringPayloads[tok.strIdx])
  of tkRawString:
    let tok = p.advance()
    if containsBidiControl(p.stream.rawStringPayloads[tok.rawIdx]):
      return err[InternedStr, ParseError](initError(peLexInvalidIdentifier,
        tok.span, "bidi control codepoint in type annotation name"))
    handle = p.doc.interner.intern(p.stream.rawStringPayloads[tok.rawIdx])
  else:
    return err[InternedStr, ParseError](initError(peParseExpected,
      p.peek.span, "expected identifier or string inside type annotation"))
  if not p.check(tkRParen):
    return err[InternedStr, ParseError](initError(peParseExpected,
      p.peek.span, "expected ')' to close type annotation"))
  discard p.advance()  # consume `)`
  ok[InternedStr, ParseError](handle)

template returnValidated(p: var Parser, v: KdlValue, anno: InternedStr): untyped =
  ## Common tail of each parseValue branch: if a reserved-type tag is
  ## present, validate the value's content per the spec interpretation
  ## (see reserved.nim). Tags absent / unknown / valid → return ok.
  if anno != InvalidInterned:
    let tagStr = p.doc.interner.lookup(anno)
    let rcheck = validateReserved(tagStr, v)
    if rcheck.isErr: return err[KdlValue, ParseError](rcheck.getErr)
  return ok[KdlValue, ParseError](v)

proc parseValue(p: var Parser): Result[KdlValue, ParseError] {.noSideEffect.} =
  ## Reads an optional type annotation prefix + a literal value.
  var anno = InvalidInterned
  if p.check(tkLParen):
    let r = p.parseTypeAnno()
    if r.isErr: return err[KdlValue, ParseError](r.getErr)
    anno = r.get
  let tok = p.peek
  case tok.kind
  of tkString:
    discard p.advance()
    if containsBidiControl(p.stream.stringPayloads[tok.strIdx]):
      return err[KdlValue, ParseError](initError(peLexInvalidIdentifier,
        tok.span, "bidi control codepoint in string value"))
    var v = newStringValue(p.stream.stringPayloads[tok.strIdx], tok.span)
    v.typeAnnotation = anno
    returnValidated(p, v, anno)
  of tkIdent:
    # KDL v2 allows bare identifiers as string values, except for the
    # six reserved keywords (true/false/null/inf/-inf/nan) which must be
    # quoted or `#`-prefixed.
    discard p.advance()
    let identStr = p.doc.interner.lookup(tok.ident)
    if isReservedBareword(identStr):
      return err[KdlValue, ParseError](initError(peLexReservedKeyword,
        tok.span,
        "reserved keyword '" & identStr & "' cannot be used as a bare " &
        "value; quote it or use '#" & identStr & "'"))
    var v = newStringValue(identStr, tok.span)
    v.typeAnnotation = anno
    returnValidated(p, v, anno)
  of tkRawString:
    discard p.advance()
    if containsBidiControl(p.stream.rawStringPayloads[tok.rawIdx]):
      return err[KdlValue, ParseError](initError(peLexInvalidIdentifier,
        tok.span, "bidi control codepoint in string value"))
    var v = newStringValue(p.stream.rawStringPayloads[tok.rawIdx], tok.span)
    v.typeAnnotation = anno
    returnValidated(p, v, anno)
  of tkNumber:
    discard p.advance()
    let n = p.stream.numberPayloads[tok.numIdx]
    if looksLikeFloat(n):
      let floatRes = decodeFloatFromToken(n, tok.span)
      if floatRes.isErr: return err[KdlValue, ParseError](floatRes.getErr)
      var v = newFloatValue(floatRes.get, tok.span)
      v.typeAnnotation = anno
      returnValidated(p, v, anno)
    let intRes = decodeIntPromoting(n, tok.span)
    if intRes.isErr: return err[KdlValue, ParseError](intRes.getErr)
    let d = intRes.get
    var v = if d.fits64: newIntValue(d.intVal, tok.span)
            else: newBigIntValue(d.bigHi, d.bigLo, d.negative, tok.span)
    v.typeAnnotation = anno
    returnValidated(p, v, anno)
  of tkKeyword:
    discard p.advance()
    var v: KdlValue
    case tok.keyword
    of kwTrue:   v = newBoolValue(true, tok.span)
    of kwFalse:  v = newBoolValue(false, tok.span)
    of kwNull:   v = newNullValue(tok.span)
    of kwInf:    v = newFloatValue(Inf, tok.span)
    of kwNegInf: v = newFloatValue(NegInf, tok.span)
    of kwNan:    v = newFloatValue(NaN, tok.span)
    v.typeAnnotation = anno
    returnValidated(p, v, anno)
  of tkError:
    discard p.advance()
    return err[KdlValue, ParseError](p.stream.errorPayloads[tok.errIdx])
  else:
    return err[KdlValue, ParseError](initError(peParseExpected, tok.span,
      "expected a value (string, number, keyword)"))

# ---------------------------------------------------------------------------
# Entry parsing (argument vs property)
# ---------------------------------------------------------------------------

proc parseEntry(p: var Parser): Result[KdlEntry, ParseError] {.noSideEffect.} =
  ## Entries are either properties (`ident = value`) or arguments (`value`).
  ## We can tell them apart by lookahead: `ident` followed by `=` is a
  ## property; anything else starting with a value (incl. a type-annotated
  ## value) is an argument.
  let startSpan = p.peek.span
  # Reject keyword-shape tokens as property keys per v2 spec.
  if p.peek.kind == tkKeyword and p.peek(1).kind == tkEquals:
    return err[KdlEntry, ParseError](initError(peParseUnexpected,
      p.peek.span, "keyword cannot be used as a property key"))
  # Reject bare idents that look like reserved keywords (true/false/null
  # /inf/-inf/nan). v2 forbids these in key position even without `#`.
  if p.peek.kind == tkIdent and p.peek(1).kind == tkEquals:
    let kw = p.doc.interner.lookup(p.peek.ident)
    if isReservedBareword(kw):
      return err[KdlEntry, ParseError](initError(peLexReservedKeyword,
        p.peek.span,
        "reserved keyword '" & kw & "' cannot be used as a property key"))
  # Property: bare ident, quoted string, or raw string followed by `=`.
  if (p.peek.kind == tkIdent or p.peek.kind == tkString or
      p.peek.kind == tkRawString) and
     p.peek(1).kind == tkEquals:
    var key: InternedStr
    case p.peek.kind
    of tkIdent: key = p.advance().ident
    of tkString:
      let tok = p.advance()
      if containsBidiControl(p.stream.stringPayloads[tok.strIdx]):
        return err[KdlEntry, ParseError](initError(peLexInvalidIdentifier,
          tok.span, "bidi control codepoint in property key"))
      key = p.doc.interner.intern(p.stream.stringPayloads[tok.strIdx])
    of tkRawString:
      let tok = p.advance()
      if containsBidiControl(p.stream.rawStringPayloads[tok.rawIdx]):
        return err[KdlEntry, ParseError](initError(peLexInvalidIdentifier,
          tok.span, "bidi control codepoint in property key"))
      key = p.doc.interner.intern(p.stream.rawStringPayloads[tok.rawIdx])
    else: discard  # unreachable (guarded above)
    discard p.advance()  # consume `=`
    let vRes = p.parseValue()
    if vRes.isErr: return err[KdlEntry, ParseError](vRes.getErr)
    # Span ends at the value's last byte, NOT at the next token. The
    # emPreserve splice path uses entry.span to extract source bytes,
    # and including trailing whitespace would shadow the spacing the
    # user authored between this entry and the next.
    let lastTokEnd = p.stream.tokens[p.cursor - 1].span.finish
    return ok[KdlEntry, ParseError](KdlEntry(
      kind: keProperty, propName: key, propValue: vRes.get,
      span: initSpan(startSpan.start, lastTokEnd)))
  # Argument path. Capture start before parseValue so the entry's
  # span includes any preceding `(typeAnno)` bytes too, and end at
  # the last consumed token (not the next, to keep trailing whitespace
  # out of the span — see property-branch comment above).
  let argStart = p.peek.span.start
  let vRes = p.parseValue()
  if vRes.isErr: return err[KdlEntry, ParseError](vRes.getErr)
  let lastTokEnd = p.stream.tokens[p.cursor - 1].span.finish
  ok[KdlEntry, ParseError](KdlEntry(
    kind: keArgument, argValue: vRes.get,
    span: initSpan(argStart, lastTokEnd)))

# ---------------------------------------------------------------------------
# Node parsing
# ---------------------------------------------------------------------------

func canStartValue(t: Token): bool {.inline.} =
  case t.kind
  of tkString, tkRawString, tkNumber, tkKeyword, tkLParen, tkIdent: true
  else: false

func canStartEntry(p: Parser): bool =
  ## True if the next token can begin an entry (argument or property).
  ## Three classes start an entry:
  ##   - slashdash (skips the next entry)
  ##   - any value-shaped token (string / raw string / number / keyword /
  ##     `(` for typed value / bare ident for v2 string-value)
  ##   - any name-shape (ident / string / raw string) followed by `=`
  ##     which is the property-key path
  ##
  ## The third clause overlaps with the second for ident/string/raw —
  ## a property-shaped lookahead is just a more specific form of
  ## value-shaped lookahead. We keep the explicit clause so the
  ## property recognition is greppable, not an accidental fall-through.
  let t = p.peek
  if t.kind == tkSlashDash: return true
  if canStartValue(t): return true
  if (t.kind == tkIdent or t.kind == tkString or
      t.kind == tkRawString) and
     p.peek(1).kind == tkEquals: return true
  false

proc parseChildren(p: var Parser): Result[seq[KdlNode], ParseError] {.noSideEffect.}

proc parseNode(p: var Parser): Result[KdlNode, ParseError] {.noSideEffect.} =
  ## Parse a single node. Caller has skipped leading slashdash if any.
  if p.depth >= MaxParserDepth:
    return err[KdlNode, ParseError](initError(peParseDepthExceeded,
      p.peek.span, "nesting depth exceeded MaxParserDepth"))

  let startSpan = p.peek.span
  var anno = InvalidInterned
  if p.check(tkLParen):
    let r = p.parseTypeAnno()
    if r.isErr: return err[KdlNode, ParseError](r.getErr)
    anno = r.get

  # Node names can be bare identifiers, quoted strings, or raw strings.
  var nameHandle: InternedStr
  case p.peek.kind
  of tkIdent:
    let tok = p.advance()
    let identStr = p.doc.interner.lookup(tok.ident)
    if isReservedBareword(identStr):
      return err[KdlNode, ParseError](initError(peLexReservedKeyword,
        tok.span,
        "reserved keyword '" & identStr & "' cannot be used as a bare " &
        "node name; quote it or use '#" & identStr & "'"))
    nameHandle = tok.ident
  of tkString:
    let tok = p.advance()
    if containsBidiControl(p.stream.stringPayloads[tok.strIdx]):
      return err[KdlNode, ParseError](initError(peLexInvalidIdentifier,
        tok.span, "bidi control codepoint in node name"))
    nameHandle = p.doc.interner.intern(p.stream.stringPayloads[tok.strIdx])
  of tkRawString:
    let tok = p.advance()
    if containsBidiControl(p.stream.rawStringPayloads[tok.rawIdx]):
      return err[KdlNode, ParseError](initError(peLexInvalidIdentifier,
        tok.span, "bidi control codepoint in node name"))
    nameHandle = p.doc.interner.intern(p.stream.rawStringPayloads[tok.rawIdx])
  of tkError:
    let errTok = p.advance(); return err[KdlNode, ParseError](p.stream.errorPayloads[errTok.errIdx])
  else:
    return err[KdlNode, ParseError](initError(peParseExpected,
      p.peek.span, "expected node name"))

  # Per-node entries + children seqs stay at default capacity. Pre-sizing
  # was measured: a `newSeqOfCap(2)` cost more per node than the reallocs
  # it saved (regressions on tight-loop tiny-doc benches outweighed any
  # win on entry-heavy nodes). Variance per node is too high for a single
  # heuristic to be net positive.
  var node = KdlNode(name: nameHandle, typeAnnotation: anno,
                     entries: @[], children: @[], span: startSpan)

  # Helpers for accumulating-mode (parseAll) entry-level recovery.
  template accumulating(): bool = not p.errorBuf.isNil
  template pushEntryErr(e: ParseError) =
    p.errorBuf[].add(e)
  template skipToEntryBoundary() =
    ## Advance until the next "safe to resume" position: a node
    ## terminator, the start of a children block, or a fresh entry-
    ## start token preceded by whitespace. No unconditional advance —
    ## parseValue/parseEntry typically already left the cursor past
    ## the failed entry. Forward progress is guarded by the caller via
    ## the savedCursor pattern below.
    while not p.atEnd:
      let k = p.peek.kind
      if k == tkNewline or k == tkSemicolon or
         k == tkLBrace or k == tkRBrace or k == tkEof:
        break
      if p.peek.precededByWs and p.canStartEntry: break
      discard p.advance()

  # Parse zero or more entries, then zero or more children blocks.
  # Spec rule (from corpus slashdash_multiple_child_blocks and the paired
  # _fail case): once *any* children block (real or slashdashed) has been
  # consumed, no more entries are permitted. Real and slashdashed children
  # blocks may freely interleave, but at most one real block contributes.
  var seenChildrenBlock = false
  var realChildrenSeen = false
  while true:
    var skip = false
    if p.check(tkSlashDash):
      discard p.advance()
      skip = true
      # Slashdash consumes any whitespace/newlines/comments before its
      # target — the lexer already drops comments + plain whitespace,
      # but newlines are emitted as significant tokens and must be
      # skipped here so `node foo /-\n2 3` reads `/-` then the next
      # entry across the newline.
      p.skipNewlines()
    # canStartEntry must be evaluated AFTER the slashdash skip so the
    # newly-positioned token is what we test against.
    if not skip and not p.canStartEntry and not p.check(tkLBrace): break
    if skip and not p.canStartEntry and not p.check(tkLBrace):
      # Slashdash consumed but the next token cannot begin an entry or
      # children-block — give a targeted diagnostic instead of letting
      # parseEntry fall through to a generic "expected a value" error.
      let e = initError(peParseExpected, p.peek.span,
        "'/-' must be followed by an entry or '{' children block")
      if accumulating():
        pushEntryErr(e); skipToEntryBoundary(); continue
      return err[KdlNode, ParseError](e)
    # Could be a children block instead of an entry — check
    if p.check(tkLBrace):
      inc p.depth
      let cRes = p.parseChildren()
      dec p.depth
      if cRes.isErr: return err[KdlNode, ParseError](cRes.getErr)
      seenChildrenBlock = true
      if not skip:
        if realChildrenSeen:
          return err[KdlNode, ParseError](initError(peParseUnexpected,
            p.peek.span, "a node may have at most one real children block"))
        node.children = cRes.take    # sink-move, avoids deep-copy of subtree
        realChildrenSeen = true
      continue
    # An entry. Spec disallows entries after any children block has been
    # consumed (real or slashdashed).
    if seenChildrenBlock:
      let e = initError(peParseUnexpected, p.peek.span,
        "entries are not permitted after a children block")
      if accumulating():
        pushEntryErr(e); skipToEntryBoundary(); continue
      return err[KdlNode, ParseError](e)
    # Token-adjacency: spec corpus `zero_space_before_*_fail` requires
    # whitespace (or a newline / `;` / `/-`) before every entry-start
    # token. The lexer stamps `precededByWs` for us.
    if not skip and not p.peek.precededByWs:
      let e = initError(peParseExpected, p.peek.span,
        "whitespace required before this entry")
      if accumulating():
        pushEntryErr(e); skipToEntryBoundary(); continue
      return err[KdlNode, ParseError](e)
    let savedCursor = p.cursor
    let eRes = p.parseEntry()
    if eRes.isErr:
      if accumulating():
        pushEntryErr(eRes.getErr)
        # Forward-progress guard: if parseEntry left the cursor in
        # place (failed before advancing), we must move it manually
        # or skipToEntryBoundary will see "safe right here" and loop.
        if p.cursor == savedCursor: discard p.advance()
        skipToEntryBoundary(); continue
      return err[KdlNode, ParseError](eRes.getErr)
    if not skip:
      # KDL v2: when a property key repeats, the later assignment wins.
      # Replace any earlier entry with the same key before appending.
      var newEntry = eRes.get
      newEntry.parseHash = hashEntry(newEntry, p.doc.interner)
      if newEntry.kind == keProperty:
        var i = 0
        while i < node.entries.len:
          if node.entries[i].kind == keProperty and
             node.entries[i].propName == newEntry.propName:
            node.entries.delete(i)
          else:
            inc i
      node.entries.add(newEntry)

  # Terminator
  case p.peek.kind
  of tkNewline, tkSemicolon:
    discard p.advance()
  of tkEof, tkRBrace:
    discard  # Don't consume; the enclosing loop handles it
  of tkError:
    let errTok = p.advance(); return err[KdlNode, ParseError](p.stream.errorPayloads[errTok.errIdx])
  else:
    return err[KdlNode, ParseError](initError(peParseUnexpected,
      p.peek.span, "expected newline, ';', or end of node"))

  # Span ends at the LAST consumed token, not at the next token's
  # start. The terminator (newline / `;`) and any leading whitespace
  # before the next node belong to the inter-node gap, not to this
  # node — keeping them out of node.span means encode's emPreserve
  # splice path doesn't drag in the spacing the user authored
  # between sibling nodes.
  let lastTokEnd =
    if p.cursor > 0: p.stream.tokens[p.cursor - 1].span.finish
    else: startSpan.start
  node.span = initSpan(startSpan.start, lastTokEnd)
  node.parseEntryCount = int32(node.entries.len)
  node.parseChildCount = int32(node.children.len)
  # Bottom-up: children's parseHash is already populated by the recursive
  # nodeRule calls above, so we can assemble this node's hash in O(1) by
  # combining stored child hashes — instead of re-hashing the whole
  # subtree via `hashNodeContent`, which would make parsing O(N·d).
  # The two formulations are algebraically equivalent on unmutated trees;
  # `tests/test_hash_complexity.nim` pins both the linearity and the
  # equivalence.
  var childHashes = newSeq[Hash128](node.children.len)
  # Index directly — `for i, c in node.children` binds `c` by value-copy,
  # which deep-copies each KdlNode's children subtree. Direct indexing
  # reads via `lent` so we just touch the parseHash field. Caught by
  # `proc =copy(KdlNode) {.error.}` probe at ast.nim under -d:probeKdlNodeCopy.
  for i in 0 ..< node.children.len:
    childHashes[i] = node.children[i].parseHash
  node.parseHash = hashNodeFromChildHashes(node, p.doc.interner, childHashes)
  ok[KdlNode, ParseError](node)

proc skipToBlockBoundary(p: var Parser) {.noSideEffect.} =
  ## Accumulating-mode children-block recovery. Like skipToRecovery
  ## but balanced-brace-aware: a `{` opens an inner block that the
  ## walk skips over (tracking depth) so we don't accidentally
  ## resume at the WRONG `}` mid-tree. Stops at a newline / `;`
  ## or at the current scope's closing `}` / EOF without consuming
  ## the `}`.
  var depth = 0
  while not p.atEnd:
    let k = p.peek.kind
    if k == tkEof: return
    if depth == 0 and k == tkRBrace: return
    if depth == 0 and (k == tkNewline or k == tkSemicolon):
      discard p.advance()
      return
    if k == tkLBrace: inc depth
    elif k == tkRBrace: dec depth
    discard p.advance()

proc parseChildren(p: var Parser): Result[seq[KdlNode], ParseError] {.noSideEffect.} =
  ## Parse `{ node* }`. Caller has confirmed the opening `{`. In
  ## accumulating mode (p.errorBuf non-nil), inner parseNode errors
  ## are pushed to the buffer and the loop continues with the next
  ## sibling rather than propagating the error up; the parent node
  ## still gets a partial children list.
  discard p.advance()  # consume `{`
  var nodes: seq[KdlNode] = @[]
  p.skipNewlines()
  while not p.atEnd and not p.check(tkRBrace):
    var skipNode = false
    if p.check(tkSlashDash):
      discard p.advance()
      skipNode = true
    let savedCursor = p.cursor
    let nRes = p.parseNode()
    if nRes.isErr:
      if not p.errorBuf.isNil:
        p.errorBuf[].add(nRes.getErr)
        if p.cursor == savedCursor: discard p.advance()
        p.skipToBlockBoundary()
        p.skipNewlines()
        continue
      return err[seq[KdlNode], ParseError](nRes.getErr)
    if not skipNode:
      nodes.add(nRes.take)   # sink-move, see spans.nim::take docs
    p.skipNewlines()
  if not p.check(tkRBrace):
    return err[seq[KdlNode], ParseError](initError(peParseExpected,
      p.peek.span, "expected '}' to close children block"))
  discard p.advance()  # consume `}`
  ok[seq[KdlNode], ParseError](nodes)

# ---------------------------------------------------------------------------
# Document parsing
# ---------------------------------------------------------------------------

func estimateDocNodes*(tokenCount: int): int {.inline.} =
  ## Heuristic for pre-allocating `KdlDoc.nodes`. Each top-level node
  ## consumes ~5+ tokens (name + entry + entry + terminator at minimum;
  ## typically more). Estimating at `tokens/5` slightly over-shoots
  ## the common case so the seq doesn't re-grow during parsing.
  ##
  ## Floors at 4 — tiny docs don't benefit from a smaller initial
  ## capacity than the first power-of-two seq growth would land on.
  max(4, tokenCount div 5)


proc parseDocument(p: var Parser): Result[seq[KdlNode], ParseError] {.noSideEffect.} =
  var nodes = newSeqOfCap[KdlNode](estimateDocNodes(p.stream.tokens.len))
  p.skipNewlines()
  while not p.atEnd:
    var skipNode = false
    if p.check(tkSlashDash):
      discard p.advance()
      # Slashdash skips the *next thing*, even across newlines.
      p.skipNewlines()
      skipNode = true
    if p.atEnd: break
    let nRes = p.parseNode()
    if nRes.isErr: return err[seq[KdlNode], ParseError](nRes.getErr)
    if not skipNode:
      nodes.add(nRes.take)   # sink-move, see spans.nim::take docs
    p.skipNewlines()
  ok[seq[KdlNode], ParseError](nodes)

proc skipToRecovery(p: var Parser) {.noSideEffect.} =
  ## Multi-error recovery: advance past the failed construct so the
  ## next parseNode call gets a clean start. We stop at the first
  ## node-terminator token (newline, semicolon, `}`, or EOF) and
  ## consume it. tkError tokens — already-collected lex errors — are
  ## skipped silently since we logged them up front.
  while not p.atEnd:
    let k = p.peek.kind
    if k == tkEof: return
    if k == tkRBrace: return  # let the children-block loop close out
    discard p.advance()
    if k == tkNewline or k == tkSemicolon: return

proc parseDocumentAccumulating(p: var Parser, errors: var seq[ParseError]):
    seq[KdlNode] {.noSideEffect.} =
  ## Multi-error variant of parseDocument. Collects every node-level
  ## failure into `errors` and re-syncs at node terminators, then
  ## continues. Returns the partial node list.
  p.skipNewlines()
  while not p.atEnd:
    var skipNode = false
    if p.check(tkSlashDash):
      discard p.advance()
      p.skipNewlines()
      skipNode = true
    if p.atEnd: break
    let savedCursor = p.cursor
    let nRes = p.parseNode()
    if nRes.isErr:
      errors.add(nRes.getErr)
      # Ensure forward progress even if parseNode left the cursor
      # in place. skipToRecovery will advance to a terminator.
      if p.cursor == savedCursor: discard p.advance()
      p.skipToRecovery()
    else:
      if not skipNode: result.add(nRes.get)
    p.skipNewlines()

# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------

proc parse*(source: string, sourcePath = "<input>"):
    Result[KdlDoc, ParseError] {.noSideEffect.} =
  ## Parse `source` into a `KdlDoc`. Returns the first error encountered
  ## (lexer or parser). The doc owns its interner.
  var doc = newDoc(sourcePath)
  let tokens = lex(source, doc.interner)
  # Early-exit on any inline lex errors so callers get the lex diagnostic,
  # not a downstream parser-confusion diagnostic.
  for t in tokens.tokens:
    if t.kind == tkError:
      return err[KdlDoc, ParseError](tokens.errorPayloads[t.errIdx])
  var p = Parser(stream: tokens, cursor: 0, depth: 0, doc: doc)
  let dRes = p.parseDocument()
  if dRes.isErr:
    return err[KdlDoc, ParseError](dRes.getErr)
  # The parser may have interned additional strings (quoted node names,
  # quoted property keys) into its local copy of the doc's interner.
  # Reach into p.doc rather than the original `doc` so those interns
  # are preserved.
  p.doc.nodes = dRes.take    # sink-move; non-sink .get deep-copies the tree
  p.doc.sourceText = source
  p.doc.parseTopLevelCount = int32(p.doc.nodes.len)
  ok[KdlDoc, ParseError](move p.doc)   # explicit move out of p

proc parseAll*(source: string, sourcePath = "<input>"):
    tuple[doc: KdlDoc, errors: seq[ParseError]] {.noSideEffect.} =
  ## Multi-error variant of `parse`. Collects every lex- and node-level
  ## error into `errors` while continuing to parse the rest of the
  ## source. The returned `doc` is a partial document built from the
  ## nodes that DID parse; consumers can either show the user every
  ## error at once (IDE / CI) or use the partial doc for best-effort
  ## recovery (REPL).
  ##
  ## Caller contract:
  ##   - If `errors.len == 0`, the doc is a valid, complete parse.
  ##   - If `errors.len > 0`, the doc holds whichever nodes survived.
  ##
  ## `parse()` continues to return only the first error and matches
  ## `parseAll(source).errors[0]` when failures exist.
  result.doc = newDoc(sourcePath)
  let tokens = lex(source, result.doc.interner)
  for t in tokens.tokens:
    if t.kind == tkError:
      result.errors.add(tokens.errorPayloads[t.errIdx])
  var p = Parser(stream: tokens, cursor: 0, depth: 0, doc: result.doc,
                 errorBuf: addr result.errors)
  let nodes = parseDocumentAccumulating(p, result.errors)
  p.doc.nodes = nodes
  p.doc.sourceText = source
  p.doc.parseTopLevelCount = int32(p.doc.nodes.len)
  result.doc = p.doc
