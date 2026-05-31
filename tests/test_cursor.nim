## Unit tests for src/cursor.nim — the token-cursor primitive that
## the three consumer surfaces (Cat 1 streaming, Cat 2 typed-derive,
## Cat 3 AST/DOM) ride on.
##
## Tests are written against the *public* concept surface
## (`peek`, `advance`, `skip`, `bytes`, `tokenAt`, `pos`, `seek`)
## and the StringCursor default impl. They exercise grammar
## coverage one slice at a time, mirroring the order the rewrite
## phases will consume them.

import std/unittest

import ../src/cursor
import ../src/intern
import ../src/lexer
import ../src/spans

## Helper: lex `src`, store the TokenStream on the heap so the cursor's
## `ptr` stays valid for the duration of the test, return a cursor over it.
## The `ref TokenStream` is held by the cursor lifetime indirectly through
## the test's `c` variable (Nim's GC keeps the ref alive while reachable).
type CursorFixture = ref object
  stream*: ref TokenStream
  cursor*: StringCursor

proc mkCursor(src: string): CursorFixture =
  var interner = initInterner()
  var sref: ref TokenStream
  new(sref)
  sref[] = lex(src)
  result = CursorFixture(stream: sref,
                         cursor: initStringCursor(addr sref[], src))

template advance(f: CursorFixture): CursorEvent = advance(f.cursor)

suite "cursor — empty input":
  test "empty source emits ceEof immediately":
    let f = mkCursor("")
    check advance(f).kind == ceEof

suite "cursor — single node":
  test "lone bareword node emits NodeBegin, NodeEnd, Eof":
    let f = mkCursor("foo")
    check advance(f).kind == ceNodeBegin
    check advance(f).kind == ceNodeEnd
    check advance(f).kind == ceEof

suite "cursor — positional args":
  test "node with one numeric arg":
    let f = mkCursor("foo 42")
    check advance(f).kind == ceNodeBegin
    let arg = advance(f)
    check arg.kind == ceArg
    check arg.argIdx == 0
    check advance(f).kind == ceNodeEnd
    check advance(f).kind == ceEof

suite "cursor — properties":
  test "node with one property":
    let f = mkCursor("foo x=1")
    check advance(f).kind == ceNodeBegin
    let prop = advance(f)
    check prop.kind == ceProp
    check advance(f).kind == ceNodeEnd
    check advance(f).kind == ceEof

suite "cursor — bytes accessor":
  test "bytes() resolves bareword node name":
    let f = mkCursor("foo")
    let nb = advance(f)
    check nb.kind == ceNodeBegin
    check bytes(f.cursor, nb.nodeNameTok) == "foo"

suite "cursor — multiple top-level nodes":
  test "semicolon separates two nodes":
    let f = mkCursor("foo;bar")
    check advance(f).kind == ceNodeBegin
    check advance(f).kind == ceNodeEnd
    let nb2 = advance(f)
    check nb2.kind == ceNodeBegin
    check bytes(f.cursor, nb2.nodeNameTok) == "bar"
    check advance(f).kind == ceNodeEnd
    check advance(f).kind == ceEof

suite "cursor — children block":
  test "node with single child":
    let f = mkCursor("foo { bar }")
    check advance(f).kind == ceNodeBegin       # foo
    check advance(f).kind == ceChildrenBegin
    let cb = advance(f)
    check cb.kind == ceNodeBegin               # bar
    check bytes(f.cursor, cb.nodeNameTok) == "bar"
    check advance(f).kind == ceNodeEnd         # bar end
    check advance(f).kind == ceChildrenEnd
    check advance(f).kind == ceNodeEnd         # foo end
    check advance(f).kind == ceEof

suite "cursor — type annotations":
  test "node with type annotation `(u8)foo`":
    let f = mkCursor("(u8)foo")
    let nb = advance(f)
    check nb.kind == ceNodeBegin
    check nb.nodeAnnoTok != -1
    check bytes(f.cursor, nb.nodeAnnoTok) == "u8"
    check bytes(f.cursor, nb.nodeNameTok) == "foo"

  test "arg with type annotation `foo (i32)42`":
    let f = mkCursor("foo (i32)42")
    check advance(f).kind == ceNodeBegin
    let arg = advance(f)
    check arg.kind == ceArg
    check arg.argAnnoTok != -1
    check bytes(f.cursor, arg.argAnnoTok) == "i32"

  test "prop with type annotation `foo x=(u8)1`":
    let f = mkCursor("foo x=(u8)1")
    check advance(f).kind == ceNodeBegin
    let pr = advance(f)
    check pr.kind == ceProp
    check pr.propAnnoTok != -1
    check bytes(f.cursor, pr.propAnnoTok) == "u8"

suite "cursor — errors (single-shot)":
  test "lex error emits ceError then halts to ceEof":
    let f = mkCursor("\"unterminated")
    let ev = advance(f)
    check ev.kind == ceError
    # Single-shot: after the first error, the stream is done.
    check advance(f).kind == ceEof
    check advance(f).kind == ceEof  # idempotent after halt

proc mkAccumCursor(src: string): CursorFixture =
  ## Same as mkCursor but with accumulating error mode — cursor recovers
  ## after each ceError and keeps emitting events.
  var interner = initInterner()
  var sref: ref TokenStream
  new(sref)
  sref[] = lex(src)
  result = CursorFixture(stream: sref,
                         cursor: initStringCursor(addr sref[], src,
                                                  mode = cmAccumulating))

suite "cursor — errors (accumulating)":
  test "lex error followed by recovery to next node":
    let f = mkAccumCursor("\"unterm\nfoo")
    check advance(f).kind == ceError
    let nb = advance(f)
    check nb.kind == ceNodeBegin
    check bytes(f.cursor, nb.nodeNameTok) == "foo"
    check advance(f).kind == ceNodeEnd
    check advance(f).kind == ceEof

suite "cursor — slashdash brackets":
  test "entry slashdash brackets a single arg":
    let f = mkCursor("foo /-42 13")
    check advance(f).kind == ceNodeBegin
    check advance(f).kind == ceSlashdashBegin
    let a1 = advance(f)
    check a1.kind == ceArg
    check advance(f).kind == ceSlashdashEnd
    let a2 = advance(f)
    check a2.kind == ceArg
    check advance(f).kind == ceNodeEnd
    check advance(f).kind == ceEof

  test "top-level node slashdash brackets the whole node":
    let f = mkCursor("/- foo")
    check advance(f).kind == ceSlashdashBegin
    check advance(f).kind == ceNodeBegin
    check advance(f).kind == ceNodeEnd
    check advance(f).kind == ceSlashdashEnd
    check advance(f).kind == ceEof

  test "children slashdash brackets the whole children block":
    let f = mkCursor("foo /-{ bar }")
    check advance(f).kind == ceNodeBegin       # foo
    check advance(f).kind == ceSlashdashBegin
    check advance(f).kind == ceChildrenBegin
    check advance(f).kind == ceNodeBegin       # bar
    check advance(f).kind == ceNodeEnd
    check advance(f).kind == ceChildrenEnd
    check advance(f).kind == ceSlashdashEnd
    check advance(f).kind == ceNodeEnd         # foo
    check advance(f).kind == ceEof

suite "cursor — peek":
  # peek() returns the next event WITHOUT advancing. Needed by Cat 2
  # codegen which dispatches on the next event kind to choose between
  # entries loop, children loop, or terminator.
  test "peek returns next event without consuming it":
    let f = mkCursor("foo")
    check peek(f.cursor).kind == ceNodeBegin
    check peek(f.cursor).kind == ceNodeBegin   # idempotent
    check advance(f).kind == ceNodeBegin       # cursor still at NodeBegin
    check advance(f).kind == ceNodeEnd

  test "peek on empty input returns ceEof (not the zero enum value)":
    # Guards against the trivial false-pass where peek returns a
    # zero-initialized CursorEvent (kind == first enum member).
    let f = mkCursor("")
    check peek(f.cursor).kind == ceEof

suite "cursor — concept satisfaction":
  test "StringCursor satisfies KdlCursor concept at compile time":
    check StringCursor is KdlCursor

suite "cursor — annotation requires name":
  test "type annotation followed by no name is an error":
    let f = mkCursor("(u8)\n")
    var sawError = false
    for _ in 0 ..< 10:
      let ev = advance(f)
      if ev.kind == ceError: sawError = true; break
      if ev.kind == ceEof: break
    check sawError

  test "annotation with number-as-tag is rejected":
    # (123)foo — KDL v2: annotations must be ident or string, not number.
    let f = mkCursor("(123)foo")
    var sawError = false
    for _ in 0 ..< 10:
      let ev = advance(f)
      if ev.kind == ceError: sawError = true; break
      if ev.kind == ceEof: break
    check sawError

suite "cursor — adjacency rule":
  test "entry directly abutted to node name is rejected":
    # `foo"bar"` — no whitespace between foo and "bar".
    let f = mkCursor("foo\"bar\"")
    var sawError = false
    for _ in 0 ..< 10:
      let ev = advance(f)
      if ev.kind == ceError: sawError = true; break
      if ev.kind == ceEof: break
    check sawError

  test "entry preceded by whitespace is accepted":
    let f = mkCursor("foo \"bar\"")
    var nb, arg = 0
    for _ in 0 ..< 10:
      let ev = advance(f)
      if ev.kind == ceNodeBegin: inc nb
      elif ev.kind == ceArg: inc arg
      elif ev.kind == ceEof: break
    check nb == 1
    check arg == 1

  test "slashdashed entry bypasses adjacency check":
    # `foo/-"bar"` — adjacent to foo but slashdash-prefixed so it's
    # allowed; the slashdashed content can be tight against /-.
    let f = mkCursor("foo /-\"bar\"")
    var sawError = false
    for _ in 0 ..< 10:
      let ev = advance(f)
      if ev.kind == ceError: sawError = true; break
      if ev.kind == ceEof: break
    check not sawError

suite "cursor — no entries after children":
  test "entry after children block is rejected":
    # `foo { x } b=2` — KDL v2 requires children to be the LAST
    # component of a node. b=2 after `}` is rejected.
    let f = mkCursor("foo { x } b=2")
    var sawError = false
    for _ in 0 ..< 20:
      let ev = advance(f)
      if ev.kind == ceError: sawError = true; break
      if ev.kind == ceEof: break
    check sawError

  test "children block followed by newline terminator is OK":
    let f = mkCursor("foo { x }\nbar")
    var nb = 0
    for _ in 0 ..< 20:
      let ev = advance(f)
      if ev.kind == ceError: break
      if ev.kind == ceNodeBegin: inc nb
      if ev.kind == ceEof: break
    check nb == 3   # foo, x, bar

suite "cursor — unclosed children":
  test "unclosed children block at EOF is rejected":
    let f = mkCursor("foo {")
    var sawError = false
    for _ in 0 ..< 20:
      let ev = advance(f)
      if ev.kind == ceError: sawError = true; break
      if ev.kind == ceEof: break
    check sawError

  test "unclosed children block with content at EOF is rejected":
    let f = mkCursor("foo { bar")
    var sawError = false
    for _ in 0 ..< 20:
      let ev = advance(f)
      if ev.kind == ceError: sawError = true; break
      if ev.kind == ceEof: break
    check sawError

suite "cursor — quoted prop keys":
  test "quoted string as prop key emits Prop":
    let f = mkCursor("foo \"my key\"=1")
    check advance(f).kind == ceNodeBegin
    check advance(f).kind == ceProp
    check advance(f).kind == ceNodeEnd
    check advance(f).kind == ceEof

  test "bidi control in quoted prop key is rejected":
    let f = mkCursor("foo \"abc‮def\"=1")
    var sawError = false
    for _ in 0 ..< 10:
      let ev = advance(f)
      if ev.kind == ceError: sawError = true; break
      if ev.kind == ceEof: break
    check sawError

suite "cursor — quoted node names":
  test "quoted string as node name emits NodeBegin":
    let f = mkCursor("\"my node\"")
    let nb = advance(f)
    check nb.kind == ceNodeBegin
    # nodeNameTok points at the quoted-string token; bytes() returns
    # the QUOTED form (with quotes), but the AST consumer (DocBuilder)
    # resolves the unescaped payload via the stream's stringPayloads
    # using the token kind. The cursor only commits to "this is the
    # name token" — payload resolution is the consumer's concern.
    check advance(f).kind == ceNodeEnd
    check advance(f).kind == ceEof

  test "bidi control in quoted node name is rejected":
    # U+202E RIGHT-TO-LEFT OVERRIDE inside the string payload.
    let f = mkCursor("\"abc‮def\"")
    var sawError = false
    for _ in 0 ..< 10:
      let ev = advance(f)
      if ev.kind == ceError: sawError = true; break
      if ev.kind == ceEof: break
    check sawError

suite "cursor — MaxParserDepth guard":
  test "children nesting beyond MaxParserDepth emits ceError":
    # MaxParserDepth = 256 (typed_parser.MaxParserDepthValue). Build a
    # source with 257 nested `{` after the top-level node head.
    var src = "foo "
    for _ in 0 ..< 257:
      src.add("{ foo ")
    let f = mkCursor(src)
    var sawError = false
    var sawTooDeep = false
    for _ in 0 ..< 1000:
      let ev = advance(f)
      if ev.kind == ceError:
        sawError = true
        if ev.err.code == peParseDepthExceeded: sawTooDeep = true
        break
      if ev.kind == ceEof: break
    check sawError
    check sawTooDeep

suite "cursor — checkpoint round-trip":
  # `pos()` captures cursor state; `seek()` restores it. Two-call
  # invariant: pos → seek (no advance in between) is a no-op; advance
  # → pos → seek → advance must emit the same event as the original
  # second advance. Used by Cat 4 (LSP/incremental).
  test "seek to a saved checkpoint replays the next event":
    let f = mkCursor("foo bar=1 { child }")
    check advance(f).kind == ceNodeBegin   # foo
    let ck = pos(f.cursor)
    let ev1 = advance(f)
    seek(f.cursor, ck)
    let ev2 = advance(f)
    check ev1.kind == ev2.kind
    # Tail of stream after the second consumption must still work.
    discard advance(f)  # ChildrenBegin
    discard advance(f)  # NodeBegin(child)
    discard advance(f)  # NodeEnd(child)
    discard advance(f)  # ChildrenEnd
    discard advance(f)  # NodeEnd(foo)
    check advance(f).kind == ceEof

suite "cursor — skip subtree":
  # `skip()` is the Cat 2 codegen primitive for "unknown child name —
  # consume the whole subtree." Contract: call immediately after a
  # ceNodeBegin; on return, the cursor is positioned past the matching
  # ceNodeEnd, even if the subtree contained arbitrarily-nested
  # children blocks.
  test "skip after NodeBegin consumes args + children + NodeEnd":
    let f = mkCursor("parent { skip_me 1 { inner }; keep_me }")
    check advance(f).kind == ceNodeBegin       # parent
    check advance(f).kind == ceChildrenBegin
    let skipNb = advance(f)
    check skipNb.kind == ceNodeBegin           # skip_me
    check bytes(f.cursor, skipNb.nodeNameTok) == "skip_me"
    skip(f.cursor)
    let keepNb = advance(f)
    check keepNb.kind == ceNodeBegin
    check bytes(f.cursor, keepNb.nodeNameTok) == "keep_me"
    check advance(f).kind == ceNodeEnd         # keep_me
    check advance(f).kind == ceChildrenEnd
    check advance(f).kind == ceNodeEnd         # parent
    check advance(f).kind == ceEof

suite "cursor — deep nesting (the #11 proof)":
  # The bug the visitor-protocol architecture had: `inChildren: bool`
  # can't represent depth-2+ nested children. The cursor uses an
  # integer depth counter (and consumers use the system call stack),
  # so arbitrary depth works by construction.
  test "depth-3 nesting emits perfectly nested events":
    let f = mkCursor("l1 { l2 { l3 } }")
    check advance(f).kind == ceNodeBegin       # l1
    check advance(f).kind == ceChildrenBegin
    check advance(f).kind == ceNodeBegin       # l2
    check advance(f).kind == ceChildrenBegin
    check advance(f).kind == ceNodeBegin       # l3
    check advance(f).kind == ceNodeEnd         # l3 end
    check advance(f).kind == ceChildrenEnd
    check advance(f).kind == ceNodeEnd         # l2 end
    check advance(f).kind == ceChildrenEnd
    check advance(f).kind == ceNodeEnd         # l1 end
    check advance(f).kind == ceEof
