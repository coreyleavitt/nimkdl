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
import ./intern
import ./lexer
import ./numlit
import ./spans

const
  MaxParserDepth* = 256
    ## Maximum recursion depth through `{ children }` blocks.

type
  Parser = object
    tokens: seq[Token]
    cursor: int
    depth: int
    doc: KdlDoc

# ---------------------------------------------------------------------------
# Token-stream helpers
# ---------------------------------------------------------------------------

func atEnd(p: Parser): bool {.inline.} =
  p.cursor >= p.tokens.len or p.tokens[p.cursor].kind == tkEof

func peek(p: Parser, ahead = 0): Token {.inline.} =
  if p.cursor + ahead < p.tokens.len:
    p.tokens[p.cursor + ahead]
  else:
    Token(kind: tkEof, span: pointSpan(StartPosition))

proc advance(p: var Parser): Token {.inline, noSideEffect.} =
  result = p.tokens[p.cursor]
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
    if containsBidiControl(tok.strVal):
      return err[InternedStr, ParseError](initError(peLexInvalidIdentifier,
        tok.span, "bidi control codepoint in type annotation name"))
    handle = p.doc.interner.intern(tok.strVal)
  of tkRawString:
    let tok = p.advance()
    if containsBidiControl(tok.rawVal):
      return err[InternedStr, ParseError](initError(peLexInvalidIdentifier,
        tok.span, "bidi control codepoint in type annotation name"))
    handle = p.doc.interner.intern(tok.rawVal)
  else:
    return err[InternedStr, ParseError](initError(peParseExpected,
      p.peek.span, "expected identifier or string inside type annotation"))
  if not p.check(tkRParen):
    return err[InternedStr, ParseError](initError(peParseExpected,
      p.peek.span, "expected ')' to close type annotation"))
  discard p.advance()  # consume `)`
  ok[InternedStr, ParseError](handle)

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
    if containsBidiControl(tok.strVal):
      return err[KdlValue, ParseError](initError(peLexInvalidIdentifier,
        tok.span, "bidi control codepoint in string value"))
    var v = newStringValue(tok.strVal, tok.span)
    v.typeAnnotation = anno
    return ok[KdlValue, ParseError](v)
  of tkIdent:
    # KDL v2 allows bare identifiers as string values, except for the
    # six reserved keywords (true/false/null/inf/-inf/nan) which must be
    # quoted or `#`-prefixed.
    discard p.advance()
    let identStr = p.doc.interner.lookup(tok.ident)
    if identStr in ReservedBarewords:
      return err[KdlValue, ParseError](initError(peLexReservedKeyword,
        tok.span,
        "reserved keyword '" & identStr & "' cannot be used as a bare " &
        "value; quote it or use '#" & identStr & "'"))
    var v = newStringValue(identStr, tok.span)
    v.typeAnnotation = anno
    return ok[KdlValue, ParseError](v)
  of tkRawString:
    discard p.advance()
    if containsBidiControl(tok.rawVal):
      return err[KdlValue, ParseError](initError(peLexInvalidIdentifier,
        tok.span, "bidi control codepoint in string value"))
    var v = newStringValue(tok.rawVal, tok.span)
    v.typeAnnotation = anno
    return ok[KdlValue, ParseError](v)
  of tkNumber:
    discard p.advance()
    if looksLikeFloat(tok):
      let floatRes = decodeFloatFromToken(tok)
      if floatRes.isErr: return err[KdlValue, ParseError](floatRes.getErr)
      var v = newFloatValue(floatRes.get, tok.span)
      v.typeAnnotation = anno
      return ok[KdlValue, ParseError](v)
    let intRes = decodeIntFromToken(tok)
    if intRes.isErr: return err[KdlValue, ParseError](intRes.getErr)
    var v = newIntValue(intRes.get, tok.span)
    v.typeAnnotation = anno
    return ok[KdlValue, ParseError](v)
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
    return ok[KdlValue, ParseError](v)
  of tkError:
    discard p.advance()
    return err[KdlValue, ParseError](tok.error)
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
    if kw in ReservedBarewords:
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
      if containsBidiControl(tok.strVal):
        return err[KdlEntry, ParseError](initError(peLexInvalidIdentifier,
          tok.span, "bidi control codepoint in property key"))
      key = p.doc.interner.intern(tok.strVal)
    of tkRawString:
      let tok = p.advance()
      if containsBidiControl(tok.rawVal):
        return err[KdlEntry, ParseError](initError(peLexInvalidIdentifier,
          tok.span, "bidi control codepoint in property key"))
      key = p.doc.interner.intern(tok.rawVal)
    else: discard  # unreachable (guarded above)
    discard p.advance()  # consume `=`
    let vRes = p.parseValue()
    if vRes.isErr: return err[KdlEntry, ParseError](vRes.getErr)
    return ok[KdlEntry, ParseError](KdlEntry(
      kind: keProperty, propName: key, propValue: vRes.get,
      span: initSpan(startSpan.start, p.peek.span.start)))
  # Argument path
  let vRes = p.parseValue()
  if vRes.isErr: return err[KdlEntry, ParseError](vRes.getErr)
  ok[KdlEntry, ParseError](newArgument(vRes.get, vRes.get.span))

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
    if identStr in ReservedBarewords:
      return err[KdlNode, ParseError](initError(peLexReservedKeyword,
        tok.span,
        "reserved keyword '" & identStr & "' cannot be used as a bare " &
        "node name; quote it or use '#" & identStr & "'"))
    nameHandle = tok.ident
  of tkString:
    let tok = p.advance()
    if containsBidiControl(tok.strVal):
      return err[KdlNode, ParseError](initError(peLexInvalidIdentifier,
        tok.span, "bidi control codepoint in node name"))
    nameHandle = p.doc.interner.intern(tok.strVal)
  of tkRawString:
    let tok = p.advance()
    if containsBidiControl(tok.rawVal):
      return err[KdlNode, ParseError](initError(peLexInvalidIdentifier,
        tok.span, "bidi control codepoint in node name"))
    nameHandle = p.doc.interner.intern(tok.rawVal)
  of tkError:
    return err[KdlNode, ParseError](p.advance().error)
  else:
    return err[KdlNode, ParseError](initError(peParseExpected,
      p.peek.span, "expected node name"))

  var node = KdlNode(name: nameHandle, typeAnnotation: anno,
                     entries: @[], children: @[], span: startSpan)

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
      return err[KdlNode, ParseError](initError(peParseExpected,
        p.peek.span,
        "'/-' must be followed by an entry or '{' children block"))
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
        node.children = cRes.get
        realChildrenSeen = true
      continue
    # An entry. Spec disallows entries after any children block has been
    # consumed (real or slashdashed).
    if seenChildrenBlock:
      return err[KdlNode, ParseError](initError(peParseUnexpected,
        p.peek.span,
        "entries are not permitted after a children block"))
    let eRes = p.parseEntry()
    if eRes.isErr: return err[KdlNode, ParseError](eRes.getErr)
    if not skip:
      # KDL v2: when a property key repeats, the later assignment wins.
      # Replace any earlier entry with the same key before appending.
      let newEntry = eRes.get
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
    return err[KdlNode, ParseError](p.advance().error)
  else:
    return err[KdlNode, ParseError](initError(peParseUnexpected,
      p.peek.span, "expected newline, ';', or end of node"))

  node.span = initSpan(startSpan.start, p.peek.span.start)
  ok[KdlNode, ParseError](node)

proc parseChildren(p: var Parser): Result[seq[KdlNode], ParseError] {.noSideEffect.} =
  ## Parse `{ node* }`. Caller has confirmed the opening `{`.
  discard p.advance()  # consume `{`
  var nodes: seq[KdlNode] = @[]
  p.skipNewlines()
  while not p.atEnd and not p.check(tkRBrace):
    var skipNode = false
    if p.check(tkSlashDash):
      discard p.advance()
      skipNode = true
    let nRes = p.parseNode()
    if nRes.isErr: return err[seq[KdlNode], ParseError](nRes.getErr)
    if not skipNode:
      nodes.add(nRes.get)
    p.skipNewlines()
  if not p.check(tkRBrace):
    return err[seq[KdlNode], ParseError](initError(peParseExpected,
      p.peek.span, "expected '}' to close children block"))
  discard p.advance()  # consume `}`
  ok[seq[KdlNode], ParseError](nodes)

# ---------------------------------------------------------------------------
# Document parsing
# ---------------------------------------------------------------------------

proc parseDocument(p: var Parser): Result[seq[KdlNode], ParseError] {.noSideEffect.} =
  var nodes: seq[KdlNode] = @[]
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
      nodes.add(nRes.get)
    p.skipNewlines()
  ok[seq[KdlNode], ParseError](nodes)

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
  for t in tokens:
    if t.kind == tkError:
      return err[KdlDoc, ParseError](t.error)
  var p = Parser(tokens: tokens, cursor: 0, depth: 0, doc: doc)
  let dRes = p.parseDocument()
  if dRes.isErr:
    return err[KdlDoc, ParseError](dRes.getErr)
  # The parser may have interned additional strings (quoted node names,
  # quoted property keys) into its local copy of the doc's interner.
  # Reach into p.doc rather than the original `doc` so those interns
  # are preserved.
  p.doc.nodes = dRes.get
  ok[KdlDoc, ParseError](p.doc)
