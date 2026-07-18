## node_edit.nim — targeted single-node property preserve-splice (rfc §N-edit).
##
## The bounded single-node subset of the general #31 preserve engine. Sets,
## inserts, or replaces exactly ONE property on the first top-level node named
## `nodeName`, returning new source bytes that are **byte-identical everywhere
## except the changed entry** — comments and formatting outside the touched
## value are preserved verbatim.
##
## Why this exists as a first-class primitive: byte-lossless config editing needs
## per-entry positions, which the self-contained DOM deliberately does not carry
## (`value.nim`: "span/parseHash live elsewhere"). Rather than have every
## consumer re-lex a node's span by hand — brittle, and unsound against comments
## that merely mention the key — nkdl owns the locate + splice, and tests every
## grammar edge case (children block, embedded comment, trailing newline,
## duplicate node) in its own conformance suite.
##
## Scope: single top-level node, single scalar property. The general recursive
## multi-node dirty-splice (#31) is out of scope. If `nodeName` is absent the
## node is appended; if `nodeName` is duplicated the FIRST occurrence is edited
## (the caller owns deduplication — the DOM's own decode is likewise first- or
## last-wins by its rules, not this function's concern).

import std/options
import ./spans        # Result, ParseError, ok, err, Span offset/length/endOffset
import ./value        # KdlValue
import ./node         # KdlNode, KdlDoc, node(doc, name), sourceText
import ./node_build   # parseNodes
import ./lexer        # lex, TokenStream, Token, TokenKind
import ./token_text   # tokenAsString
import ./emitter      # BufferEmitter, pushArgV, pushPropV, pushNodeBeginV, finish

func renderValueLiteral(v: KdlValue): string =
  ## Canonical source text of a bare value (e.g. `#true`, `42`, `"x"`), via the
  ## real emitter so annotations/escapes match the rest of nkdl. `pushArgV`
  ## prepends a separator space; strip it — we splice the literal alone.
  var e = newBufferEmitter()
  e.pushArgV(v)
  result = e.finish()
  if result.len > 0 and result[0] == ' ':
    result = result[1 .. ^1]

func renderPropChunk(key: string, v: KdlValue): string =
  ## ` key=value` with the leading separator space — ready to splice in after a
  ## node's last head entry.
  var e = newBufferEmitter()
  e.pushPropV(key, v)
  e.finish()

func renderNodeLine(nodeName, propName: string, v: KdlValue): string =
  ## `nodeName key=value` — a whole new node line (name auto-quoted if needed).
  var e = newBufferEmitter()
  e.pushNodeBeginV(nodeName, none(string))
  e.pushPropV(propName, v)
  e.finish()

proc setNodePropPreserving*(src: string; nodeName, propName: string;
                            value: KdlValue): Result[string, ParseError]
                            {.raises: [].} =
  ## Set `propName=value` on the first top-level node named `nodeName`, losslessly.
  ## See the module doc for the case matrix and scope. Errors only if `src` is not
  ## valid KDL.
  let pr = parseNodes(src)
  if pr.isErr:
    return err[string, ParseError](pr.getErr)
  let doc = pr.get
  let n = doc.node(nodeName)

  if n.isNil:
    # node absent → append a new node line, guaranteeing a newline boundary so it
    # cannot be swallowed into a preceding `//` comment or fused onto a value.
    var res = src
    if res.len > 0 and res[^1] != '\n':
      res.add('\n')
    res.add(renderNodeLine(nodeName, propName, value))
    res.add('\n')
    return ok[string, ParseError](res)

  let nodeStart = n.span.offset
  let nodeEnd = n.span.offset + n.span.length   # exclusive; excludes terminator
  let ts = lex(src)

  # Walk the node's head tokens (up to its own `{` or the terminator). Tokens
  # carry absolute source spans, so a comment that merely mentions the key is
  # never a token and can never match — comment-safe by construction.
  var lastHeadEnd = -1        # end offset of the last head token before `{`/end
  var valStart = -1          # byte offset just after `=` of a matched property
  var valEnd = -1            # byte offset at the end of that property's value
  var i = 0
  while i < ts.tokens.len and ts.tokens[i].span.offset < nodeStart:
    inc i
  while i < ts.tokens.len:
    let tk = ts.tokens[i]
    if tk.span.offset >= nodeEnd:
      break
    if tk.kind == tkLBrace:   # the node's own children block opens — head ends
      break
    # property detection: <key-token> `=` <value>, key decoded so quoted keys
    # match too. Re-detection on a later duplicate overwrites → last-wins.
    if (tk.kind == tkIdent or tk.kind == tkString or tk.kind == tkRawString) and
       i + 1 < ts.tokens.len and ts.tokens[i + 1].kind == tkEquals and
       tokenAsString(tk, ts, src) == propName:
      let eq = ts.tokens[i + 1]
      var k = i + 2
      if k < ts.tokens.len and ts.tokens[k].kind == tkLParen:
        while k < ts.tokens.len and ts.tokens[k].kind != tkRParen:
          inc k
        inc k                 # step past `)`
      if k < ts.tokens.len:
        valStart = eq.span.endOffset
        valEnd = ts.tokens[k].span.endOffset
    lastHeadEnd = tk.span.endOffset
    inc i

  if valStart >= 0:
    # prop present → replace the value bytes in place
    return ok[string, ParseError](
      src[0 ..< valStart] & renderValueLiteral(value) & src[valEnd .. ^1])

  # prop absent → insert after the last head entry (before `{` if a block exists,
  # else before the terminator). lastHeadEnd is always set (at least the name).
  let insertAt = if lastHeadEnd >= 0: lastHeadEnd else: nodeEnd
  ok[string, ParseError](
    src[0 ..< insertAt] & renderPropChunk(propName, value) & src[insertAt .. ^1])
