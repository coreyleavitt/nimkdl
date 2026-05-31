## Tests for lexer.nim — exercise each token category, escape decoding,
## position tracking, and error recovery.
##
## Post-compaction shape: string/raw-string/number payloads live in
## TokenStream side-tables and (line, col) is derived from a LineMap
## over the original source. Helpers in this file bridge those splits
## so the assertion sites can stay readable.

import std/[os, strutils, unittest]

import ../src/ast
import ../src/lexer
import ../src/parser
import ../src/spans

# A captured-source view of one lex run; tests want both the tokens and
# the side-tables (for payloads) plus a LineMap (for line/col asserts).
type LexCtx = object
  src: string
  stream: TokenStream
  lm: LineMap

proc lexAll(src: string): LexCtx =
  LexCtx(src: src, stream: lex(src), lm: buildLineMap(src))

proc tokenize(src: string): seq[Token] =
  lex(src).tokens

proc identText(t: Token, src: string): string =
  ## Bareword (tkIdent) text, read from source via the token span — the
  ## lexer no longer interns, so there is no handle to look up.
  src[t.span.offset ..< t.span.endOffset]

proc tokenizeCtx(src: string): LexCtx =
  lexAll(src)

# Pulls just the kinds of non-EOF tokens — convenient for structural asserts.
proc kinds(toks: seq[Token]): seq[TokenKind] =
  for t in toks:
    if t.kind != tkEof: result.add(t.kind)

proc col(t: Token, ctx: LexCtx): int = ctx.lm.lineColOf(t.span.start.offset).col
proc line(t: Token, ctx: LexCtx): int = ctx.lm.lineColOf(t.span.start.offset).line
proc strVal(t: Token, ctx: LexCtx): string =
  # No-escape single-line strings carry no payload (span-only); resolve
  # uniformly via stringPayload.
  tokenText(ctx.stream, t)
proc rawVal(t: Token, ctx: LexCtx): string =
  tokenText(ctx.stream, t)
proc numText(t: Token, ctx: LexCtx): string =
  ctx.stream.source[t.span.offset ..< t.span.endOffset]
proc numBase(t: Token, ctx: LexCtx): NumberBase =
  t.numBase
proc numNegative(t: Token, ctx: LexCtx): bool =
  let s = numText(t, ctx)
  s.len > 0 and s[0] == '-'

suite "lexer: whitespace and EOF":
  test "empty input yields just EOF":
    let ctx = tokenizeCtx("")
    let t = ctx.stream.tokens
    check t.len == 1
    check t[0].kind == tkEof

  test "whitespace-only input yields just EOF":
    let ctx = tokenizeCtx("   \t  ")
    let t = ctx.stream.tokens
    check t.len == 1
    check t[0].kind == tkEof

  test "newlines are tokens":
    let ctx = tokenizeCtx("\n\n")
    let t = ctx.stream.tokens
    check t.kinds == @[tkNewline, tkNewline]

  test "CRLF normalizes to one newline":
    let ctx = tokenizeCtx("\r\n")
    let t = ctx.stream.tokens
    check t.kinds == @[tkNewline]
    check t[1].kind == tkEof  # one newline + EOF

suite "lexer: punctuation":
  test "all punctuation tokens emitted":
    let ctx = tokenizeCtx("{ } = ; ( ) /-")
    let t = ctx.stream.tokens
    check t.kinds == @[tkLBrace, tkRBrace, tkEquals, tkSemicolon,
                       tkLParen, tkRParen, tkSlashDash]

  test "punctuation positions are precise":
    let ctx = tokenizeCtx("{ }")
    let t = ctx.stream.tokens
    check t[0].col(ctx) == 1
    check t[1].col(ctx) == 3  # past `{ `

suite "lexer: comments":
  test "line comment consumed":
    let ctx = tokenizeCtx("// hello\nrule")
    let t = ctx.stream.tokens
    check t.kinds == @[tkNewline, tkIdent]

  test "block comment consumed":
    let ctx = tokenizeCtx("/* multi\nline */rule")
    let t = ctx.stream.tokens
    check t.kinds == @[tkIdent]

  test "nested block comment":
    let ctx = tokenizeCtx("/* a /* b */ c */rule")
    let t = ctx.stream.tokens
    check t.kinds == @[tkIdent]

  test "unterminated block comment becomes error":
    let ctx = tokenizeCtx("/* never closed")
    let t = ctx.stream.tokens
    check tkError in t.kinds

suite "lexer: bare identifiers":
  test "single bare ident":
    let t = tokenize("rule")
    check t.kinds == @[tkIdent]
    check identText(t[0], "rule") == "rule"

  test "bare ident with hyphen and digits":
    let t = tokenize("rule-v2-final")
    check t.kinds == @[tkIdent]
    check identText(t[0], "rule-v2-final") == "rule-v2-final"

  test "punctuation terminates bare ident":
    let ctx = tokenizeCtx("a;b")
    let t = ctx.stream.tokens
    check t.kinds == @[tkIdent, tkSemicolon, tkIdent]

suite "lexer: regular strings":
  test "simple string":
    let ctx = tokenizeCtx("\"hello\"")
    let t = ctx.stream.tokens
    check t.kinds == @[tkString]
    check t[0].strVal(ctx) == "hello"

  test "basic escape sequences":
    # KDL v2 removed `\/` from the valid escape set; covered by `unknown
    # escape produces error` test below.
    let ctx = tokenizeCtx("\"\\n\\t\\r\\\"\\\\\"")
    let t = ctx.stream.tokens
    check t.kinds == @[tkString]
    check t[0].strVal(ctx) == "\n\t\r\"\\"

  test "\\u{XXXX} escape decodes":
    let ctx = tokenizeCtx("\"\\u{2603}\"")
    let t = ctx.stream.tokens  # SNOWMAN
    check t.kinds == @[tkString]
    check t[0].strVal(ctx) == "\xE2\x98\x83"  # UTF-8 encoding of U+2603

  test "\\u{} surrogate rejected":
    let ctx = tokenizeCtx("\"\\u{D800}\"")
    let t = ctx.stream.tokens
    check tkError in t.kinds

  test "unterminated string becomes error":
    let ctx = tokenizeCtx("\"no close")
    let t = ctx.stream.tokens
    check tkError in t.kinds

  test "literal newline in single-line string is error":
    let ctx = tokenizeCtx("\"split\nhere\"")
    let t = ctx.stream.tokens
    check tkError in t.kinds

  test "unknown escape produces error":
    let ctx = tokenizeCtx("\"\\z\"")
    let t = ctx.stream.tokens
    check tkError in t.kinds

suite "lexer: raw strings":
  test "simple raw string":
    let ctx = tokenizeCtx("#\"raw\"#")
    let t = ctx.stream.tokens
    check t.kinds == @[tkRawString]
    check t[0].rawVal(ctx) == "raw"

  test "raw string preserves backslashes":
    let ctx = tokenizeCtx("#\"\\n no escape\"#")
    let t = ctx.stream.tokens
    check t.kinds == @[tkRawString]
    check t[0].rawVal(ctx) == "\\n no escape"

  test "raw string with embedded quote":
    let ctx = tokenizeCtx("##\"has \"# inside\"##")
    let t = ctx.stream.tokens
    check t.kinds == @[tkRawString]
    check t[0].rawVal(ctx) == "has \"# inside"

  test "unterminated raw string is error":
    let ctx = tokenizeCtx("#\"unclosed")
    let t = ctx.stream.tokens
    check tkError in t.kinds

suite "lexer: raw-string DoS cap (H3)":
  test "exactly MaxRawStringHashes opens is fine":
    let prefix = "#".repeat(MaxRawStringHashes)
    let src = prefix & "\"body\"" & prefix
    let ctx = tokenizeCtx(src)
    let t = ctx.stream.tokens
    check t.kinds == @[tkRawString]
    check t[0].rawVal(ctx) == "body"

  test "one past cap emits a structured error":
    let prefix = "#".repeat(MaxRawStringHashes + 1)
    let src = prefix & "\"body\"" & prefix
    let ctx = tokenizeCtx(src)
    let t = ctx.stream.tokens
    check tkError in t.kinds

suite "lexer: multi-line strings":
  test "regular multi-line":
    let src = "\"\"\"\n  hello\n  world\n  \"\"\""
    let ctx = tokenizeCtx(src)
    let t = ctx.stream.tokens
    check t.kinds == @[tkString]
    check t[0].strVal(ctx) == "hello\nworld"

  test "raw multi-line":
    let src = "#\"\"\"\n  raw \\n preserved\n  \"\"\"#"
    let ctx = tokenizeCtx(src)
    let t = ctx.stream.tokens
    check t.kinds == @[tkRawString]
    check t[0].rawVal(ctx) == "raw \\n preserved"

  test "opening \"\"\" not followed by newline is error":
    let ctx = tokenizeCtx("\"\"\"oops\"\"\"")
    let t = ctx.stream.tokens
    check tkError in t.kinds

  # Slice-5 fixtures: WS-escape resolution happens before dedent.

  test "WS-escape on line before closer extends content into closer-indent (F1)":
    # multiline_string_escape_newline_at_end:
    #   """
    #       a
    #      \
    #   """
    # `\<NL>` is a WS-escape: the line `   \` and its newline are gone,
    # leaving `   """` on the would-be closer line. Closing-prefix is
    # `   `, intermediate line `    a` becomes ` a`.
    let src = "\"\"\"\n    a\n   \\\n\"\"\""
    let ctx = tokenizeCtx(src)
    let t = ctx.stream.tokens
    check t.kinds == @[tkString]
    check t[0].strVal(ctx) == " a"

  test "WS-escape merging lines + closing prefix strip (F2)":
    # multiline_string_escape_in_closing_line:
    #   """
    #     foo \
    #   bar
    #     baz
    #     \   """
    # `\<NL>` joins `foo ` with `bar`. `\<3spaces>` before `"""` consumes
    # the `\` and the 3 spaces. Closing-prefix is `  `.
    let src = "\"\"\"\n  foo \\\nbar\n  baz\n  \\   \"\"\""
    let ctx = tokenizeCtx(src)
    let t = ctx.stream.tokens
    check t.kinds == @[tkString]
    check t[0].strVal(ctx) == "foo bar\nbaz"

  test "WS-escape consuming all closer indent (F3)":
    # multiline_string_escape_in_closing_line_shallow:
    # `\   """` at column 0; the `\<3sp>` consumes everything → closing
    # prefix is empty.
    let src = "\"\"\"\n  foo \\\nbar\n  baz\n\\   \"\"\""
    let ctx = tokenizeCtx(src)
    let t = ctx.stream.tokens
    check t.kinds == @[tkString]
    check t[0].strVal(ctx) == "  foo bar\n  baz"

  test "WS-escape crossing newline merges into next line (F4)":
    # multiline_string_wrapped_binary
    let src = "\"\"\"\n    dead\\\n    beef\n    \"\"\""
    let ctx = tokenizeCtx(src)
    let t = ctx.stream.tokens
    check t.kinds == @[tkString]
    check t[0].strVal(ctx) == "deadbeef"

  test "intermediate line less-indented than closer is error (F5)":
    # multiline_string_escape_newline_at_end_fail
    let src = "\"\"\"\na\n   \\\n\"\"\""
    let ctx = tokenizeCtx(src)
    let t = ctx.stream.tokens
    check tkError in t.kinds

  test "WS-escape that joins closer with non-ws prev is error (F6)":
    # multiline_string_final_whitespace_escape_fail
    let src = "\"\"\"\n  foo\n  bar\\\n  \"\"\""
    let ctx = tokenizeCtx(src)
    let t = ctx.stream.tokens
    check tkError in t.kinds

  test "whitespace-only intermediate lines contribute empty (F8)":
    # multiline_string_whitespace_only.kdl. The fixture has 5 multi-line
    # strings; the whitespace-only-line semantics rule says any
    # intermediate line that contains only whitespace contributes the
    # empty string (NOT its bytes-after-longest-common-prefix). Test
    # via parse(), not raw tokenize, because the fixture file goes
    # through the parser.
    const path = currentSourcePath.parentDir &
      "/conformance/test_cases/input/multiline_string_whitespace_only.kdl"
    let src = readFile(path)
    let res = parse(src)
    check res.isOk
    if res.isOk:
      let doc = res.get
      check doc.nodes.len == 1
      let n = doc.nodes[0]
      check n.entries.len == 5
      check n.entries[0].argValue.strVal == ""
      check n.entries[1].argValue.strVal == ""
      check n.entries[2].argValue.strVal == ""
      check n.entries[3].argValue.strVal == "\n\n    "
      check n.entries[4].argValue.strVal == "\n"

  test "non-literal-whitespace prefix on intermediate line is error (F7)":
    # multiline_string_non_literal_prefix_fail — `\s` doesn't count as a
    # literal-whitespace codepoint for the prefix-match check, even
    # though `\s` decodes to a space.
    let src = "\"\"\"\n\\s escaped prefix\n  literal prefix\n  \"\"\""
    let ctx = tokenizeCtx(src)
    let t = ctx.stream.tokens
    check tkError in t.kinds

suite "lexer: numbers":
  test "plain decimal":
    let ctx = tokenizeCtx("42")
    let t = ctx.stream.tokens
    check t.kinds == @[tkNumber]
    check t[0].numText(ctx) == "42"
    check t[0].numBase(ctx) == nbDecimal
    check not t[0].numNegative(ctx)

  test "negative decimal":
    let ctx = tokenizeCtx("-7")
    let t = ctx.stream.tokens
    check t.kinds == @[tkNumber]
    check t[0].numNegative(ctx)
    check t[0].numText(ctx) == "-7"

  test "decimal with underscores":
    let ctx = tokenizeCtx("1_000_000")
    let t = ctx.stream.tokens
    check t.kinds == @[tkNumber]
    check t[0].numText(ctx) == "1_000_000"

  test "decimal with fractional + exponent":
    let ctx = tokenizeCtx("1.5e10")
    let t = ctx.stream.tokens
    check t.kinds == @[tkNumber]
    check t[0].numText(ctx) == "1.5e10"

  test "hex":
    let ctx = tokenizeCtx("0xFF_FF")
    let t = ctx.stream.tokens
    check t.kinds == @[tkNumber]
    check t[0].numBase(ctx) == nbHex
    check t[0].numText(ctx) == "0xFF_FF"

  test "octal":
    let ctx = tokenizeCtx("0o755")
    let t = ctx.stream.tokens
    check t.kinds == @[tkNumber]
    check t[0].numBase(ctx) == nbOctal

  test "binary":
    let ctx = tokenizeCtx("0b1010")
    let t = ctx.stream.tokens
    check t.kinds == @[tkNumber]
    check t[0].numBase(ctx) == nbBinary

  test "exponent without digits is error":
    let ctx = tokenizeCtx("1e")
    let t = ctx.stream.tokens
    check tkError in t.kinds

  test "hex with no digits is error":
    let ctx = tokenizeCtx("0x")
    let t = ctx.stream.tokens
    check tkError in t.kinds

suite "lexer: keywords":
  test "all six keywords":
    let ctx = tokenizeCtx("#true #false #null #inf #-inf #nan")
    let t = ctx.stream.tokens
    check t.kinds == @[tkKeyword, tkKeyword, tkKeyword,
                       tkKeyword, tkKeyword, tkKeyword]
    check t[0].keyword == kwTrue
    check t[1].keyword == kwFalse
    check t[2].keyword == kwNull
    check t[3].keyword == kwInf
    check t[4].keyword == kwNegInf
    check t[5].keyword == kwNan

  test "unrecognized #word is error":
    let ctx = tokenizeCtx("#bogus")
    let t = ctx.stream.tokens
    check tkError in t.kinds

suite "lexer: line continuation":
  test "backslash + newline is consumed":
    let ctx = tokenizeCtx("a \\\n  b")
    let t = ctx.stream.tokens
    # Two idents separated by what was a continuation (no newline token)
    check t.kinds == @[tkIdent, tkIdent]

suite "lexer: position tracking":
  test "line + col advance correctly":
    let src = "rule\n  child"
    let ctx = tokenizeCtx(src)
    let t = ctx.stream.tokens
    # tokens: ident("rule") @ 1:1, newline @ 1:5, ident("child") @ 2:3
    check t[0].line(ctx) == 1
    check t[0].col(ctx) == 1
    check t[1].kind == tkNewline
    check t[1].line(ctx) == 1
    check t[2].line(ctx) == 2
    check t[2].col(ctx) == 3

  test "offsets correspond to source bytes":
    let src = "ab"
    let ctx = tokenizeCtx(src)
    let t = ctx.stream.tokens
    check t[0].span.start.offset == 0
    check t[0].span.finish.offset == 2

suite "lexer: realistic KDL fragments":
  test "rule declaration":
    let src = "rule \"my-rule\" {\n  enabled #true\n}"
    let ctx = lexAll(src)
    let t = ctx.stream.tokens
    check t.kinds == @[
      tkIdent, tkString, tkLBrace, tkNewline,
      tkIdent, tkKeyword, tkNewline,
      tkRBrace
    ]
    check identText(t[0], src) == "rule"
    check t[1].strVal(ctx) == "my-rule"

  test "key=value attributes":
    let src = "node a=1 b=#true c=\"hi\""
    let ctx = tokenizeCtx(src)
    let t = ctx.stream.tokens
    check t.kinds == @[
      tkIdent,
      tkIdent, tkEquals, tkNumber,
      tkIdent, tkEquals, tkKeyword,
      tkIdent, tkEquals, tkString
    ]

  test "type annotation parens":
    let src = "(u32)123"
    let ctx = tokenizeCtx(src)
    let t = ctx.stream.tokens
    check t.kinds == @[tkLParen, tkIdent, tkRParen, tkNumber]

suite "isBareword — emit/lex mirror invariants":
  ## isBareword is the single source of truth for the bareword/quoted
  ## decision at emit time. Every "yes" answer it gives must be a
  ## string the lexer would re-accept as a bareword. Counterexamples
  ## discovered by P12 get pinned here.

  test "leading-dot-then-digit rejected (P12 counterexample .6rcx)":
    # The lexer rejects `.6...` with peLexInvalidNumber ("number
    # literals need an integer part before the '.'"). isBareword
    # used to allow it because '.' is a valid ident-start in
    # isolation. Mirror the lexer's rule here so the emitter
    # never outputs a key/name that the cursor will refuse.
    check not isBareword(".6")
    check not isBareword(".6rcx")
    check not isBareword(".0")
    # `.` alone is still a fine bareword (the lexer accepts it as ident).
    check isBareword(".")
    # `.x` (non-digit after dot) is still a fine bareword.
    check isBareword(".x")
    check isBareword(".abc")
