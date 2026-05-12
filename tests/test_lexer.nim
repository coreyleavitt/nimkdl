## Tests for lexer.nim — exercise each token category, escape decoding,
## position tracking, and error recovery.

import std/[strutils, unittest]

import ../src/intern
import ../src/lexer
import ../src/spans

proc tokenize(src: string): seq[Token] =
  var i = initInterner()
  lex(src, i)

proc tokenizeWith(src: string, i: var Interner): seq[Token] =
  lex(src, i)

# Pulls just the kinds of non-EOF tokens — convenient for structural asserts.
proc kinds(toks: seq[Token]): seq[TokenKind] =
  for t in toks:
    if t.kind != tkEof: result.add(t.kind)

suite "lexer: whitespace and EOF":
  test "empty input yields just EOF":
    let t = tokenize("")
    check t.len == 1
    check t[0].kind == tkEof

  test "whitespace-only input yields just EOF":
    let t = tokenize("   \t  ")
    check t.len == 1
    check t[0].kind == tkEof

  test "newlines are tokens":
    let t = tokenize("\n\n")
    check t.kinds == @[tkNewline, tkNewline]

  test "CRLF normalizes to one newline":
    let t = tokenize("\r\n")
    check t.kinds == @[tkNewline]
    check t[1].kind == tkEof  # one newline + EOF

suite "lexer: punctuation":
  test "all punctuation tokens emitted":
    let t = tokenize("{ } = ; ( ) /-")
    check t.kinds == @[tkLBrace, tkRBrace, tkEquals, tkSemicolon,
                       tkLParen, tkRParen, tkSlashDash]

  test "punctuation positions are precise":
    let t = tokenize("{ }")
    check t[0].span.start.col == 1
    check t[1].span.start.col == 3  # past `{ `

suite "lexer: comments":
  test "line comment consumed":
    let t = tokenize("// hello\nrule")
    check t.kinds == @[tkNewline, tkIdent]

  test "block comment consumed":
    let t = tokenize("/* multi\nline */rule")
    check t.kinds == @[tkIdent]

  test "nested block comment":
    let t = tokenize("/* a /* b */ c */rule")
    check t.kinds == @[tkIdent]

  test "unterminated block comment becomes error":
    let t = tokenize("/* never closed")
    check tkError in t.kinds

suite "lexer: bare identifiers":
  test "single bare ident":
    var i = initInterner()
    let t = tokenizeWith("rule", i)
    check t.kinds == @[tkIdent]
    check i.lookup(t[0].ident) == "rule"

  test "bare ident with hyphen and digits":
    var i = initInterner()
    let t = tokenizeWith("rule-v2-final", i)
    check t.kinds == @[tkIdent]
    check i.lookup(t[0].ident) == "rule-v2-final"

  test "punctuation terminates bare ident":
    let t = tokenize("a;b")
    check t.kinds == @[tkIdent, tkSemicolon, tkIdent]

suite "lexer: regular strings":
  test "simple string":
    let t = tokenize("\"hello\"")
    check t.kinds == @[tkString]
    check t[0].strVal == "hello"

  test "basic escape sequences":
    # KDL v2 removed `\/` from the valid escape set; covered by `unknown
    # escape produces error` test below.
    let t = tokenize("\"\\n\\t\\r\\\"\\\\\"")
    check t.kinds == @[tkString]
    check t[0].strVal == "\n\t\r\"\\"

  test "\\u{XXXX} escape decodes":
    let t = tokenize("\"\\u{2603}\"")  # SNOWMAN
    check t.kinds == @[tkString]
    check t[0].strVal == "\xE2\x98\x83"  # UTF-8 encoding of U+2603

  test "\\u{} surrogate rejected":
    let t = tokenize("\"\\u{D800}\"")
    check tkError in t.kinds

  test "unterminated string becomes error":
    let t = tokenize("\"no close")
    check tkError in t.kinds

  test "literal newline in single-line string is error":
    let t = tokenize("\"split\nhere\"")
    check tkError in t.kinds

  test "unknown escape produces error":
    let t = tokenize("\"\\z\"")
    check tkError in t.kinds

suite "lexer: raw strings":
  test "simple raw string":
    let t = tokenize("#\"raw\"#")
    check t.kinds == @[tkRawString]
    check t[0].rawVal == "raw"

  test "raw string preserves backslashes":
    let t = tokenize("#\"\\n no escape\"#")
    check t.kinds == @[tkRawString]
    check t[0].rawVal == "\\n no escape"

  test "raw string with embedded quote":
    let t = tokenize("##\"has \"# inside\"##")
    check t.kinds == @[tkRawString]
    check t[0].rawVal == "has \"# inside"

  test "unterminated raw string is error":
    let t = tokenize("#\"unclosed")
    check tkError in t.kinds

suite "lexer: raw-string DoS cap (H3)":
  test "exactly MaxRawStringHashes opens is fine":
    let prefix = "#".repeat(MaxRawStringHashes)
    let src = prefix & "\"body\"" & prefix
    let t = tokenize(src)
    check t.kinds == @[tkRawString]
    check t[0].rawVal == "body"

  test "one past cap emits a structured error":
    let prefix = "#".repeat(MaxRawStringHashes + 1)
    let src = prefix & "\"body\"" & prefix
    let t = tokenize(src)
    check tkError in t.kinds

suite "lexer: multi-line strings":
  test "regular multi-line":
    let src = "\"\"\"\n  hello\n  world\n  \"\"\""
    let t = tokenize(src)
    check t.kinds == @[tkString]
    check t[0].strVal == "hello\nworld"

  test "raw multi-line":
    let src = "#\"\"\"\n  raw \\n preserved\n  \"\"\"#"
    let t = tokenize(src)
    check t.kinds == @[tkRawString]
    check t[0].rawVal == "raw \\n preserved"

  test "opening \"\"\" not followed by newline is error":
    let t = tokenize("\"\"\"oops\"\"\"")
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
    let t = tokenize(src)
    check t.kinds == @[tkString]
    check t[0].strVal == " a"

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
    let t = tokenize(src)
    check t.kinds == @[tkString]
    check t[0].strVal == "foo bar\nbaz"

  test "WS-escape consuming all closer indent (F3)":
    # multiline_string_escape_in_closing_line_shallow:
    # `\   """` at column 0; the `\<3sp>` consumes everything → closing
    # prefix is empty.
    let src = "\"\"\"\n  foo \\\nbar\n  baz\n\\   \"\"\""
    let t = tokenize(src)
    check t.kinds == @[tkString]
    check t[0].strVal == "  foo bar\n  baz"

  test "WS-escape crossing newline merges into next line (F4)":
    # multiline_string_wrapped_binary
    let src = "\"\"\"\n    dead\\\n    beef\n    \"\"\""
    let t = tokenize(src)
    check t.kinds == @[tkString]
    check t[0].strVal == "deadbeef"

  test "intermediate line less-indented than closer is error (F5)":
    # multiline_string_escape_newline_at_end_fail
    let src = "\"\"\"\na\n   \\\n\"\"\""
    let t = tokenize(src)
    check tkError in t.kinds

  test "WS-escape that joins closer with non-ws prev is error (F6)":
    # multiline_string_final_whitespace_escape_fail
    let src = "\"\"\"\n  foo\n  bar\\\n  \"\"\""
    let t = tokenize(src)
    check tkError in t.kinds

  test "non-literal-whitespace prefix on intermediate line is error (F7)":
    # multiline_string_non_literal_prefix_fail — `\s` doesn't count as a
    # literal-whitespace codepoint for the prefix-match check, even
    # though `\s` decodes to a space.
    let src = "\"\"\"\n\\s escaped prefix\n  literal prefix\n  \"\"\""
    let t = tokenize(src)
    check tkError in t.kinds

suite "lexer: numbers":
  test "plain decimal":
    let t = tokenize("42")
    check t.kinds == @[tkNumber]
    check t[0].numText == "42"
    check t[0].numBase == nbDecimal
    check not t[0].numNegative

  test "negative decimal":
    let t = tokenize("-7")
    check t.kinds == @[tkNumber]
    check t[0].numNegative
    check t[0].numText == "-7"

  test "decimal with underscores":
    let t = tokenize("1_000_000")
    check t.kinds == @[tkNumber]
    check t[0].numText == "1_000_000"

  test "decimal with fractional + exponent":
    let t = tokenize("1.5e10")
    check t.kinds == @[tkNumber]
    check t[0].numText == "1.5e10"

  test "hex":
    let t = tokenize("0xFF_FF")
    check t.kinds == @[tkNumber]
    check t[0].numBase == nbHex
    check t[0].numText == "0xFF_FF"

  test "octal":
    let t = tokenize("0o755")
    check t.kinds == @[tkNumber]
    check t[0].numBase == nbOctal

  test "binary":
    let t = tokenize("0b1010")
    check t.kinds == @[tkNumber]
    check t[0].numBase == nbBinary

  test "exponent without digits is error":
    let t = tokenize("1e")
    check tkError in t.kinds

  test "hex with no digits is error":
    let t = tokenize("0x")
    check tkError in t.kinds

suite "lexer: keywords":
  test "all six keywords":
    let t = tokenize("#true #false #null #inf #-inf #nan")
    check t.kinds == @[tkKeyword, tkKeyword, tkKeyword,
                       tkKeyword, tkKeyword, tkKeyword]
    check t[0].keyword == kwTrue
    check t[1].keyword == kwFalse
    check t[2].keyword == kwNull
    check t[3].keyword == kwInf
    check t[4].keyword == kwNegInf
    check t[5].keyword == kwNan

  test "unrecognized #word is error":
    let t = tokenize("#bogus")
    check tkError in t.kinds

suite "lexer: line continuation":
  test "backslash + newline is consumed":
    let t = tokenize("a \\\n  b")
    # Two idents separated by what was a continuation (no newline token)
    check t.kinds == @[tkIdent, tkIdent]

suite "lexer: position tracking":
  test "line + col advance correctly":
    let src = "rule\n  child"
    let t = tokenize(src)
    # tokens: ident("rule") @ 1:1, newline @ 1:5, ident("child") @ 2:3
    check t[0].span.start.line == 1
    check t[0].span.start.col == 1
    check t[1].kind == tkNewline
    check t[1].span.start.line == 1
    check t[2].span.start.line == 2
    check t[2].span.start.col == 3

  test "offsets correspond to source bytes":
    let src = "ab"
    let t = tokenize(src)
    check t[0].span.start.offset == 0
    check t[0].span.finish.offset == 2

suite "lexer: realistic KDL fragments":
  test "rule declaration":
    var i = initInterner()
    let src = "rule \"my-rule\" {\n  enabled #true\n}"
    let t = tokenizeWith(src, i)
    check t.kinds == @[
      tkIdent, tkString, tkLBrace, tkNewline,
      tkIdent, tkKeyword, tkNewline,
      tkRBrace
    ]
    check i.lookup(t[0].ident) == "rule"
    check t[1].strVal == "my-rule"

  test "key=value attributes":
    let src = "node a=1 b=#true c=\"hi\""
    let t = tokenize(src)
    check t.kinds == @[
      tkIdent,
      tkIdent, tkEquals, tkNumber,
      tkIdent, tkEquals, tkKeyword,
      tkIdent, tkEquals, tkString
    ]

  test "type annotation parens":
    let src = "(u32)123"
    let t = tokenize(src)
    check t.kinds == @[tkLParen, tkIdent, tkRParen, tkNumber]
