## DocBuilder — visitor that reconstructs a `KdlDoc` from the
## capability-driven visitor protocol in `typed_parser.nim`.
##
## Cycle 9'.1 scope (this slice):
##   - bare-ident node names
##   - recursive children of arbitrary depth
##   - no args, no props, no annotations, no slashdash yet
##
## Later slices add:
##   - 9'.2: type annotations (vcNodeAnno + vcValueAnno)
##   - 9'.3: quoted/raw-string node names
##   - 9'.4: slashdash (vcSlashdash)
##   - etc., until DocBuilder reproduces parser.nim's KdlDoc on every
##     conformance fixture (cycle 9'.9).
##
## When cycle 10 lands, `parse()` in `parser.nim` becomes
## `parseDocumentWith[DocBuilder]` and the hand-written recursive
## descent in `parser.nim` is deleted.

import ./[ast, intern, spans, lexer, typed_parser, numlit]

type
  DocBuilder* = object
    ## Visitor that produces a KdlDoc. State is a stack of currently-
    ## open KdlNode frames. visitBeginNode pushes; visitEndNode pops and
    ## attaches to the parent's children (or to doc.nodes at depth 0).
    ##
    ## Pending annotation slots are side-band: the parser emits
    ## visitNodeTypeAnno BEFORE visitBeginNode, and visitValueTypeAnno
    ## BEFORE the next visitArg / visitProp. The consuming method drains
    ## the slot back to InvalidInterned.
    doc*: KdlDoc
    stack*: seq[KdlNode]
    source*: string
      ## Original input bytes. Needed to recover identifier bytes for
      ## `tkIdent` arg/prop values — parseDocumentWith disables the
      ## lex-side interner for typed-path perf, so the token's `ident`
      ## handle is `InvalidInterned`; we read via the token's span instead.
    pendingNodeAnno: InternedStr
    pendingValueAnno: InternedStr

template visitorCaps*(_: typedesc[DocBuilder]): set[VisitorCap] =
  ## DocBuilder consumes node-name annotations and value annotations
  ## so it can faithfully reconstruct KdlNode.typeAnnotation and
  ## KdlValue.typeAnnotation. Slashdash routing lands in 9'.4.
  {vcArgs, vcProps, vcChildren, vcNodeAnno, vcValueAnno}

proc newDocBuilder*(source: string = "", sourcePath = "<input>"): DocBuilder =
  result = DocBuilder(doc: newDoc(sourcePath), stack: @[],
                      source: source,
                      pendingNodeAnno: InvalidInterned,
                      pendingValueAnno: InvalidInterned)
  result.doc.sourceText = source

proc finish*(b: sink DocBuilder): KdlDoc =
  ## Caller invokes after `parseDocumentWith` returns ok. Returns the
  ## fully-assembled doc.
  result = b.doc
  result.parseTopLevelCount = int32(result.nodes.len)

# ---------------------------------------------------------------------------
# Visitor methods
# ---------------------------------------------------------------------------

proc visitNodeTypeAnno*(b: var DocBuilder, annoStr: openArray[char],
                        annoSpan: Span): Result[void, ParseError] =
  ## Stash for the next visitBeginNode to consume.
  b.pendingNodeAnno = b.doc.interner.intern(annoStr)
  ok(void, ParseError)

proc visitValueTypeAnno*(b: var DocBuilder, annoStr: openArray[char],
                         annoSpan: Span): Result[void, ParseError] =
  ## Stash for the next visitArg / visitProp to consume.
  b.pendingValueAnno = b.doc.interner.intern(annoStr)
  ok(void, ParseError)

proc visitBeginNode*(b: var DocBuilder, nameStr: openArray[char],
                     nodeSpan: Span): Result[void, ParseError] =
  let nameHandle = b.doc.interner.intern(nameStr)
  b.stack.add(KdlNode(name: nameHandle,
                      typeAnnotation: b.pendingNodeAnno,
                      entries: @[], children: @[], span: nodeSpan))
  b.pendingNodeAnno = InvalidInterned
  ok(void, ParseError)

proc buildValue(b: DocBuilder, tok: Token,
                stream: TokenStream): Result[KdlValue, ParseError] =
  ## Token → KdlValue. Single source of truth shared by visitArg + visitProp.
  ## Reads bare-ident bytes from b.source (interner is disabled in
  ## parseDocumentWith, so tok.ident is InvalidInterned).
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
    # Bare-ident as string value (KDL v2 §value). Reserved-bareword
    # guard lands in 9'.5.
    let s = tok.span.start.offset
    let f = tok.span.finish.offset - 1
    ok[KdlValue, ParseError](newStringValue(b.source[s .. f], tok.span))
  else:
    err[KdlValue, ParseError](initError(peParseExpected, tok.span,
      "unsupported value token kind"))

proc visitArg*(b: var DocBuilder, idx: int, tok: Token,
               stream: TokenStream): Result[void, ParseError] =
  let vRes = buildValue(b, tok, stream)
  if vRes.isErr: return err[void, ParseError](vRes.getErr)
  var val = vRes.get
  val.typeAnnotation = b.pendingValueAnno
  b.pendingValueAnno = InvalidInterned
  b.stack[^1].entries.add(KdlEntry(kind: keArgument, argValue: val,
                                    span: tok.span))
  ok(void, ParseError)

proc visitProp*(b: var DocBuilder, keyStr: openArray[char],
                tok: Token, stream: TokenStream): Result[void, ParseError] =
  let key = b.doc.interner.intern(keyStr)
  let vRes = buildValue(b, tok, stream)
  if vRes.isErr: return err[void, ParseError](vRes.getErr)
  var val = vRes.get
  val.typeAnnotation = b.pendingValueAnno
  b.pendingValueAnno = InvalidInterned
  # KDL v2: when a property key repeats within a node, the later
  # assignment wins. Delete any earlier prop entry with the same key
  # before appending. Args with the same name do NOT dedupe (they're
  # positional, not keyed).
  var i = 0
  while i < b.stack[^1].entries.len:
    let e = b.stack[^1].entries[i]
    if e.kind == keProperty and e.propName == key:
      b.stack[^1].entries.delete(i)
    else:
      inc i
  b.stack[^1].entries.add(KdlEntry(kind: keProperty,
                                    propName: key, propValue: val,
                                    span: tok.span))
  ok(void, ParseError)

proc visitBeginChildren*(b: var DocBuilder): Result[void, ParseError] =
  # No state change — parseNodeWith recursion handles nesting.
  # The stack push happens in visitBeginNode for each child node.
  ok(void, ParseError)

proc visitEndChildren*(b: var DocBuilder): Result[void, ParseError] =
  ok(void, ParseError)

proc visitEndNode*(b: var DocBuilder): Result[void, ParseError] =
  ## Pop current node frame and attach to its parent (depth>=1) or
  ## directly to doc.nodes (depth 0).
  let n = b.stack.pop()
  if b.stack.len == 0:
    b.doc.nodes.add(n)
  else:
    b.stack[^1].children.add(n)
  ok(void, ParseError)
