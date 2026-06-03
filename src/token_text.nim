## token_text.nim — token → logical string (rfc-core-rebuild §6 determined refactor).
##
## `tokenAsString` resolves a token's logical text content. It depends on nothing
## but `Token` / `TokenStream` (lexer) and `string` — no AST, no interner, no
## builder. Extracting it here severs the `derive_decode → doc_build` edge: Cat-2
## codegen needs token→string but has no business dragging the Cat-3 `doc_build`
## (and through it `ast`) into every consumer's namespace.

import ./lexer
import ./spans
import ./value
import ./numlit

export value  # KdlValue + newKdl* constructors travel with tokenToKdlValue

proc tokenAsString*(tok: Token, stream: TokenStream, source: string): string =
  ## Resolve a token's logical text content. For `tkIdent`, returns the bareword
  ## bytes from source. For `tkString` / `tkRawString`, returns the unescaped
  ## payload from the lexer's side tables. For other kinds, returns the source
  ## bytes (rarely used).
  case tok.kind
  of tkIdent, tkString, tkRawString, tkNumber: tokenText(stream, tok)
  else:
    let s = int(tok.span.offset)
    let f = int(tok.span.endOffset) - 1
    source[s .. f]

proc tokenToKdlValue*(tok: Token, stream: TokenStream, source: string):
    Result[KdlValue, ParseError] {.noSideEffect.} =
  ## Token → self-contained KdlValue, per the §8 token→kind table:
  ## `tkNumber` → kvInt/kvBigInt (or kvFloat when the literal has a
  ## fractional/exponent form), `tkKeyword` → kvBool/kvNull/kvFloat
  ## (#inf/#-inf/#nan), `tkString`/`tkRawString`/`tkIdent` → kvString.
  ##
  ## Single source of truth for the token→value lift: `node_build` (Cat 3
  ## DOM) and the Cat 2 `kdlScalar` decode path both route through here, so
  ## the interchange form is identical on every surface
  ## ([[feedback_audit_for_duplication]]). Returns a `ParseError` only when a
  ## numeric literal overflows the 128-bit cap — that failure is pre-hook, so
  ## the macro never sees it as a hook error.
  case tok.kind
  of tkString, tkRawString:
    ok[KdlValue, ParseError](newKdlString(tokenText(stream, tok)))
  of tkKeyword:
    let v = case tok.keyword
      of kwTrue:   newKdlBool(true)
      of kwFalse:  newKdlBool(false)
      of kwNull:   newKdlNull()
      of kwInf:    newKdlFloat(Inf)
      of kwNegInf: newKdlFloat(NegInf)
      of kwNan:    newKdlFloat(NaN)
    ok[KdlValue, ParseError](v)
  of tkNumber:
    if looksLikeFloat(numberText(source, tok.span), tok.numBase):
      let fRes = decodeFloatFromToken(numberText(source, tok.span), tok.span)
      if fRes.isErr: return err[KdlValue, ParseError](fRes.getErr)
      ok[KdlValue, ParseError](newKdlFloat(fRes.get))
    else:
      let iRes = decodeIntPromoting(numberText(source, tok.span), tok.numBase, tok.span)
      if iRes.isErr: return err[KdlValue, ParseError](iRes.getErr)
      let d = iRes.get
      let v = if d.fits64: newKdlInt(d.intVal)
              else: newKdlBigInt(d.bigHi, d.bigLo, d.negative)
      ok[KdlValue, ParseError](v)
  of tkIdent:
    ok[KdlValue, ParseError](newKdlString(tokenText(stream, tok)))
  else:
    err[KdlValue, ParseError](initError(peParseExpected, tok.span,
      "unsupported value token kind"))
