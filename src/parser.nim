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

proc advance(p: var Parser): Token {.inline.} =
  result = p.tokens[p.cursor]
  inc p.cursor

proc check(p: Parser, kind: TokenKind): bool {.inline.} =
  p.peek.kind == kind

proc skipNewlines(p: var Parser) =
  while p.check(tkNewline):
    discard p.advance()

# ---------------------------------------------------------------------------
# Error construction
# ---------------------------------------------------------------------------

func parseErr(code: ParseErrorCode, span: Span, hint = ""): ParseError =
  initError(code, span, hint)

# ---------------------------------------------------------------------------
# Value parsing
# ---------------------------------------------------------------------------

proc parseTypeAnno(p: var Parser): Result[InternedStr, ParseError] =
  ## Consumes `(name)`. Name is a bare ident OR quoted string (incl. "").
  ## Caller has already confirmed the leading `(`.
  discard p.advance()  # consume `(`
  var handle: InternedStr
  case p.peek.kind
  of tkIdent:
    handle = p.advance().ident
  of tkString:
    let tok = p.advance()
    handle = p.doc.interner.intern(tok.strVal)
  else:
    return err[InternedStr, ParseError](parseErr(peParseExpected,
      p.peek.span, "expected identifier or string inside type annotation"))
  if not p.check(tkRParen):
    return err[InternedStr, ParseError](parseErr(peParseExpected,
      p.peek.span, "expected ')' to close type annotation"))
  discard p.advance()  # consume `)`
  ok[InternedStr, ParseError](handle)

proc parseValue(p: var Parser): Result[KdlValue, ParseError] =
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
    var v = newStringValue(tok.strVal, tok.span)
    v.typeAnnotation = anno
    return ok[KdlValue, ParseError](v)
  of tkIdent:
    # KDL v2 allows bare identifiers as string values. The lexer already
    # interned the bytes; resolve them back through the doc's interner
    # so the parser stays a single source of truth on the string contents.
    discard p.advance()
    var v = newStringValue(p.doc.interner.lookup(tok.ident), tok.span)
    v.typeAnnotation = anno
    return ok[KdlValue, ParseError](v)
  of tkRawString:
    discard p.advance()
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
    return err[KdlValue, ParseError](parseErr(peParseExpected, tok.span,
      "expected a value (string, number, keyword)"))

# ---------------------------------------------------------------------------
# Entry parsing (argument vs property)
# ---------------------------------------------------------------------------

proc parseEntry(p: var Parser): Result[KdlEntry, ParseError] =
  ## Entries are either properties (`ident = value`) or arguments (`value`).
  ## We can tell them apart by lookahead: `ident` followed by `=` is a
  ## property; anything else starting with a value (incl. a type-annotated
  ## value) is an argument.
  let startSpan = p.peek.span
  # Reject keyword-shape tokens as property keys per v2 spec.
  if p.peek.kind == tkKeyword and p.peek(1).kind == tkEquals:
    return err[KdlEntry, ParseError](parseErr(peParseUnexpected,
      p.peek.span, "keyword cannot be used as a property key"))
  # Reject bare idents that look like reserved keywords (true/false/null
  # /inf/-inf/nan). v2 forbids these in key position even without `#`.
  if p.peek.kind == tkIdent and p.peek(1).kind == tkEquals:
    let kw = p.doc.interner.lookup(p.peek.ident)
    if kw in ["true", "false", "null", "inf", "-inf", "nan"]:
      return err[KdlEntry, ParseError](parseErr(peParseUnexpected,
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
      key = p.doc.interner.intern(tok.strVal)
    of tkRawString:
      let tok = p.advance()
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
  ## An ident followed by `=` is a property; an ident without `=` would
  ## be ambiguous against the next-node case at the top level, so the
  ## parser only treats `ident =` as an entry-start. Bare values are
  ## entry-starts too.
  let t = p.peek
  if t.kind == tkSlashDash: return true
  if canStartValue(t): return true
  if (t.kind == tkIdent or t.kind == tkString) and
     p.peek(1).kind == tkEquals: return true
  false

proc parseChildren(p: var Parser): Result[seq[KdlNode], ParseError]

proc parseNode(p: var Parser): Result[KdlNode, ParseError] =
  ## Parse a single node. Caller has skipped leading slashdash if any.
  if p.depth >= MaxParserDepth:
    return err[KdlNode, ParseError](parseErr(peParseDepthExceeded,
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
    nameHandle = p.advance().ident
  of tkString:
    let tok = p.advance()
    nameHandle = p.doc.interner.intern(tok.strVal)
  of tkRawString:
    let tok = p.advance()
    nameHandle = p.doc.interner.intern(tok.rawVal)
  of tkError:
    return err[KdlNode, ParseError](p.advance().error)
  else:
    return err[KdlNode, ParseError](parseErr(peParseExpected,
      p.peek.span, "expected node name"))

  var node = KdlNode(name: nameHandle, typeAnnotation: anno,
                     entries: @[], children: @[], span: startSpan)

  # Parse zero or more entries
  while p.canStartEntry:
    var skip = false
    if p.check(tkSlashDash):
      discard p.advance()
      skip = true
    # Could be a children block instead of an entry — check
    if p.check(tkLBrace):
      inc p.depth
      let cRes = p.parseChildren()
      dec p.depth
      if cRes.isErr: return err[KdlNode, ParseError](cRes.getErr)
      if not skip:
        # A real (non-skipped) children block ends the node; nothing
        # may follow before the terminator. A slashdashed block is
        # semantically absent — keep parsing entries after it.
        node.children = cRes.get
        break
      # else: slashdashed block — fall through to keep parsing entries
      continue
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

  # Optional children block (if we didn't already consume one above)
  if p.check(tkLBrace):
    inc p.depth
    let cRes = p.parseChildren()
    dec p.depth
    if cRes.isErr: return err[KdlNode, ParseError](cRes.getErr)
    node.children = cRes.get

  # Terminator
  case p.peek.kind
  of tkNewline, tkSemicolon:
    discard p.advance()
  of tkEof, tkRBrace:
    discard  # Don't consume; the enclosing loop handles it
  of tkError:
    return err[KdlNode, ParseError](p.advance().error)
  else:
    return err[KdlNode, ParseError](parseErr(peParseUnexpected,
      p.peek.span, "expected newline, ';', or end of node"))

  node.span = initSpan(startSpan.start, p.peek.span.start)
  ok[KdlNode, ParseError](node)

proc parseChildren(p: var Parser): Result[seq[KdlNode], ParseError] =
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
    return err[seq[KdlNode], ParseError](parseErr(peParseExpected,
      p.peek.span, "expected '}' to close children block"))
  discard p.advance()  # consume `}`
  ok[seq[KdlNode], ParseError](nodes)

# ---------------------------------------------------------------------------
# Document parsing
# ---------------------------------------------------------------------------

proc parseDocument(p: var Parser): Result[seq[KdlNode], ParseError] =
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
    Result[KdlDoc, ParseError] =
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
