## Test the curated public API surface (M6).
##
## `import nkdl` is supposed to give the public surface only — lexer
## internals (Token / TokenKind / Lexer / lex) live in `nkdl/lexer`
## and are not part of `import nkdl`.

import std/unittest

import ../src/nkdl   # the curated `import nkdl` umbrella

suite "public API surface (M6)":
  test "AST types are reachable":
    check compiles(block:
      var d = newDoc()
      let n = d.newNode("rule")
      discard n)

  test "parse / decode / embed surface":
    check compiles(block:
      let r = parse("rule")
      discard r)

  test "encode surface":
    check compiles(block:
      let r = parse("rule")
      if r.isOk: discard encode(r.get))

  test "referenceInterpret surface":
    check compiles(block:
      let r = referenceInterpret("rule")
      discard r)

  test "path DSL surface":
    type X = object
      a*: int
    let xs = @[X(a: 1), X(a: 2)]
    check compiles(block:
      for v in xs.where(it.a > 0): discard v)

  test "Result combinators (M4)":
    check compiles(block:
      let r = ok[int, string](5).map(proc(v: int): int = v * 2)
      discard r.isOk)

  test "lexer internals are NOT in the umbrella":
    # The hygiene test: writing `Token`, `TokenKind`, `Lexer`, or
    # calling `lex(...)` directly should NOT compile against the
    # `import nkdl` namespace. Users who need them go through
    # `import nkdl/lexer`.
    check not compiles(typeof(Token))
    check not compiles(typeof(TokenKind))
    check not compiles(typeof(Lexer))
    check not compiles(block:
      var i = initInterner()
      discard lex("rule", i))