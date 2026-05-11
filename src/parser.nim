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

import std/strutils

import ./ast
import ./intern
import ./lexer
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
  ## Consumes `(IDENT)`. Caller has already confirmed the leading `(`.
  discard p.advance()  # consume `(`
  if not p.check(tkIdent):
    return err[InternedStr, ParseError](parseErr(peParseExpected,
      p.peek.span, "expected identifier inside type annotation"))
  let handle = p.advance().ident
  if not p.check(tkRParen):
    return err[InternedStr, ParseError](parseErr(peParseExpected,
      p.peek.span, "expected ')' to close type annotation"))
  discard p.advance()  # consume `)`
  ok[InternedStr, ParseError](handle)

proc decodeIntLiteral(text: string, base: NumberBase, negative: bool,
                     span: Span): Result[int64, ParseError] =
  ## Parses an integer literal text (the lexer kept the raw source) into
  ## int64. Returns peLexInvalidNumber on overflow.
  var s = text
  # Strip leading +/- and base prefix
  if s.len > 0 and (s[0] == '+' or s[0] == '-'):
    s = s[1 .. ^1]
  if base != nbDecimal and s.len >= 2:
    s = s[2 .. ^1]
  # Strip underscores
  var clean = ""
  for c in s:
    if c != '_': clean.add(c)
  var acc: int64 = 0
  let radix = (case base
               of nbDecimal: 10
               of nbHex: 16
               of nbOctal: 8
               of nbBinary: 2)
  for c in clean:
    let digit =
      case c
      of '0'..'9': int(ord(c) - ord('0'))
      of 'a'..'f': int(ord(c) - ord('a') + 10)
      of 'A'..'F': int(ord(c) - ord('A') + 10)
      else: -1
    if digit < 0 or digit >= radix:
      return err[int64, ParseError](parseErr(peLexInvalidNumber, span,
        "invalid digit for base"))
    # Overflow-safe accumulate
    if acc > (int64.high - int64(digit)) div int64(radix):
      return err[int64, ParseError](parseErr(peLexInvalidNumber, span,
        "integer literal does not fit in int64"))
    acc = acc * int64(radix) + int64(digit)
  if negative: acc = -acc
  ok[int64, ParseError](acc)

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
  of tkRawString:
    discard p.advance()
    var v = newStringValue(tok.rawVal, tok.span)
    v.typeAnnotation = anno
    return ok[KdlValue, ParseError](v)
  of tkNumber:
    discard p.advance()
    # Decide int vs float from the source text: presence of '.' or 'e'/'E'
    # (and the literal isn't hex/oct/bin) marks it as float.
    let isFloat = tok.numBase == nbDecimal and
                  ('.' in tok.numText or 'e' in tok.numText or 'E' in tok.numText)
    if isFloat:
      var s = tok.numText
      # Nim's parseFloat handles signs but doesn't strip underscores
      var clean = ""
      for c in s:
        if c != '_': clean.add(c)
      try:
        let f = parseFloat(clean)
        var v = newFloatValue(f, tok.span)
        v.typeAnnotation = anno
        return ok[KdlValue, ParseError](v)
      except ValueError:
        return err[KdlValue, ParseError](parseErr(peLexInvalidNumber,
          tok.span, "malformed float literal"))
    let intRes = decodeIntLiteral(tok.numText, tok.numBase,
                                   tok.numNegative, tok.span)
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
  # Property: bare ident or quoted string, followed by `=`
  if (p.peek.kind == tkIdent or p.peek.kind == tkString) and
     p.peek(1).kind == tkEquals:
    var key: InternedStr
    case p.peek.kind
    of tkIdent: key = p.advance().ident
    of tkString:
      let tok = p.advance()
      key = p.doc.interner.intern(tok.strVal)
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
  of tkString, tkRawString, tkNumber, tkKeyword, tkLParen: true
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

  # Node names can be bare identifiers OR quoted strings per v2 spec.
  var nameHandle: InternedStr
  case p.peek.kind
  of tkIdent:
    nameHandle = p.advance().ident
  of tkString:
    let tok = p.advance()
    nameHandle = p.doc.interner.intern(tok.strVal)
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
      node.entries.add(eRes.get)

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
