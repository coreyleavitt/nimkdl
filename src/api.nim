## api — public typed entry points.
##
## ## Why a separate module
##
## `decode[T]` for `seq[U]` needs `kdlDecode[U]` plus a top-level event
## loop. Neither concern lives naturally in `derive_decode` (whose job
## is per-T macro emission) or in `cursor` (whose job is event
## production). Pulling the entry points into their own module keeps
## the substrate-vs-surface boundary clean.
##
## ## Static dispatch on shape
##
## `decode[T](src)` static-dispatches on whether T is `seq[U]` (top-
## level node list — loop until ceEof, decoding one U per iteration)
## or a single typed shape (one kdlDecode call). Same for `encode[T]`.
##
## ## VM compatibility
##
## The whole pipeline is `{.noSideEffect.}`. Inputs are pure strings;
## intermediate `TokenStream` + `StringCursor` are stack-allocated;
## `kdlDecode` is itself pure. NimVM interprets the entire chain, so
## `embed[T]` is a one-line wrapper.

import ./cursor
import ./derive_decode  # for kdlDecode mixin resolution + Result/ParseError
import ./emitter
import ./intern
import ./lexer
import ./spans

# Intentionally NOT importing derive_encode here. `encode[T]`'s
# `mixin kdlEncode` resolves at the user's instantiation site, where
# the user has invoked `deriveEncode(T)` (typically via `kdl:` or
# directly). Importing it here would only add to the warning surface
# without changing resolution semantics.

export spans  # Result, ParseError visible without extra imports

proc decode*[T](src: string): Result[T, ParseError] {.noSideEffect.} =
  ## Parse `src` and decode into a value of type `T`.
  ##
  ## For object types with `{.kdlNode.}`, expects a single top-level
  ## node and returns the decoded value.
  ##
  ## Returns the first error encountered (single-shot).
  mixin kdlDecode
  var interner = initInterner()
  var stream = lex(src, interner)
  var c = initStringCursor(addr stream, src)
  when T is seq:
    type Elem = typeof(default(T)[0])
    var values: T = @[]
    while c.peek.kind != ceEof:
      var elem: Elem
      let r = kdlDecode(elem, c)
      if r.isErr: return err[T, ParseError](r.getErr)
      values.add(elem)
    ok[T, ParseError](values)
  else:
    var v: T
    let r = kdlDecode(v, c)
    if r.isErr: return err[T, ParseError](r.getErr)
    ok[T, ParseError](v)

proc encode*[T](v: T): string =
  ## Encode `v` to KDL wire bytes.
  ##
  ## For object types with `{.kdlNode.}`, emits a single top-level node.
  mixin kdlEncode
  var e = newBufferEmitter()
  when T is seq:
    for elem in v: kdlEncode(elem, e)
  else:
    kdlEncode(v, e)
  e.finish()

proc decodeAll*[T](src: string):
    tuple[value: T, errors: seq[ParseError]] {.noSideEffect.} =
  ## Multi-error variant of `decode[T]`. T must be `seq[U]` — single-
  ## node decodeAll would be the same as `decode`. On a decoder error
  ## for one top-level node, the cursor advances past the offending
  ## node and decoding continues. Returns the populated partial value
  ## alongside every error encountered.
  static:
    when not (T is seq):
      {.error: "decodeAll[T] requires T to be a seq[U]. For single-node "
              & "decode use decode[T] which already returns Result.".}
  mixin kdlDecode
  type Elem = typeof(default(T)[0])
  var interner = initInterner()
  var stream = lex(src, interner)
  var c = initStringCursor(addr stream, src, cmAccumulating)
  var values: T = @[]
  var errors: seq[ParseError] = @[]
  while c.peek.kind != ceEof:
    let ck = c.pos
    var elem: Elem
    let r = kdlDecode(elem, c)
    if r.isErr:
      errors.add(r.getErr)
      # kdlDecode may have left the cursor mid-node. Replay from the
      # checkpoint and skip the offending node so we land at the next
      # top-level boundary.
      c.seek(ck)
      let head = c.advance
      case head.kind
      of ceNodeBegin: c.skip()
      of ceEof, ceError: break
      else: discard
    else:
      values.add(elem)
  (values, errors)

proc embed*[T](src: static[string]): T =
  ## Compile-time decode of a static KDL source string into `T`. Thin
  ## delegating wrapper over `decode[T]` — single canonical compile-
  ## time decode path. `const cfg = embed[Service](kdlSrc)` materializes
  ## a constant value baked into the binary with zero runtime parse
  ## cost.
  ##
  ## On parse error the wrapped Result's `.get` raises (defect at run
  ## time; `ValueError` propagates as a CT error in VM context). The
  ## ParseError's diagnostic is preserved via `decode[T]` for surface
  ## tools that want the structured value.
  let r = decode[T](src)
  doAssert r.isOk, "embed[T]: " & (if r.isErr: r.getErr.hint else: "")
  r.get
