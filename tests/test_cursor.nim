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
  sref[] = lex(src, interner)
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
