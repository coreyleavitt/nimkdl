## token_text.nim — token → logical string (rfc-core-rebuild §6 determined refactor).
##
## `tokenAsString` resolves a token's logical text content. It depends on nothing
## but `Token` / `TokenStream` (lexer) and `string` — no AST, no interner, no
## builder. Extracting it here severs the `derive_decode → doc_build` edge: Cat-2
## codegen needs token→string but has no business dragging the Cat-3 `doc_build`
## (and through it `ast`) into every consumer's namespace.

import ./lexer
import ./spans

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
