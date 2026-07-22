import std/strutils
import std/options

import ./value
import ./lexer  # isBareword + isDisallowedControl — emitter is the dual of lexer recognition
import ./numlit  # formatInt / formatFloat / formatBigInt — numeric value → wire bytes
import ./spec_literals  # KdlKeywordLiterals + KdlSlashdash — wire bytes single source of truth

# H1 (rfc-consumer-api §4.5): the emitter primitives are the LEAVES of the
# encode chain. They are pure byte-appends over an in-memory buffer —
# structurally total. `func` already gave `{.noSideEffect.}`, but `func` does
# NOT imply `raises:[]`; making it explicit here is what lets the whole encode
# surface (`encode[T]` → derive `kdlEncode` → pushArg*) fold under
# `{.raises:[].}` at the public boundary. Any genuine raiser the compiler finds
# here gets fixed at the root, not hatched.
{.push raises: [].}

## emitter — symmetric OUT-side inverse of `KdlCursor`.
##
## A KdlEmitter accepts push events (NodeBegin / Arg / Prop /
## ChildrenBegin/End / NodeEnd / SlashdashBegin/End) and produces wire
## bytes. The cursor pulls events out of bytes; the emitter pushes
## bytes out of events. P1's foundation invariant — for every cursor
## event stream, an emitter fed those events round-trips to bytes the
## cursor accepts — lives here.
##
## Three OUT producers consume this primitive:
##   - Cat 1 OUT: user code pushes events directly (streaming/SAX)
##   - Cat 2 OUT: deriveEncode-generated `kdlEncode[T]` pushes typed
##     field values (zero KdlValue allocation on the hot path)
##   - Cat 3 OUT: docEmit walks a KdlDoc and pushes events
##
## Push methods are overloaded for zero-overhead at each producer.
## Typed-value methods (`pushArgInt`, `pushArgString`, ...) are the
## codegen path. Token-variant methods (`pushNodeBeginTok`) are the
## round-trip path that consumes cursor token references directly.
## A KdlValue convenience overload exists for docEmit consumers that
## already hold AST values; it dispatches internally to the typed
## variants.
##
## ## Stage A buildout
##
## - A1: tracer — `newBufferEmitter()` + `finish()` returns "" for no
##   events. Establishes the buffer-emitter type as the prod impl.
## - A2-A11: per-cycle accretion (see docs/branch-rebuild-plan.md).
##
## Perf-first decisions baked in from A1:
##   - String buffer growth via `setLen` + raw-byte assignment, not
##     `add()` per call (the same trick the deleted encode.nim used)
##   - Depth-indexed indent prefix cache (added in A5)
##   - Inline accessors so the optimizer can fuse cursor.bytes() with
##     destination writes on the round-trip path

const
  IndentUnit = "    "  ## 4-space indent per nesting level (canonical).
  MaxCachedIndentDepth = 16
    ## Indent prefixes for depths 0..16 live in a const cache; deeper
    ## nesting falls through to a runtime-built prefix. Trades 4×17 =
    ## 68 bytes of rodata for one O(1) lookup per pushNodeBegin in the
    ## hot path.

const Indents: array[0 .. MaxCachedIndentDepth, string] = block:
  var arr: array[0 .. MaxCachedIndentDepth, string]
  for i in 0 .. MaxCachedIndentDepth:
    arr[i] = IndentUnit.repeat(i)
  arr

type
  BufferEmitter* = object
    ## Prod impl: writes wire bytes into an internal string buffer.
    ## `finish()` returns the accumulated string and (logically) ends
    ## the emitter's life.
    buf: string
    depth: int  ## Current children-nesting depth. 0 at top level.
    slashdashPending: bool
      ## Set by `pushSlashdashBegin`; consumed (and cleared) by the
      ## next push that targets a node / entry / children block. The
      ## `/-` marker is a wire-level *prefix* but logically attaches to
      ## whatever item follows — Begin/End brackets in the API give
      ## P1 round-trip symmetry with the cursor's event pair.

func newBufferEmitter*(): BufferEmitter =
  ## Construct a fresh BufferEmitter with an empty buffer.
  BufferEmitter(buf: "")

func finish*(e: var BufferEmitter): string =
  ## Return the accumulated bytes. Subsequent pushes are undefined.
  result = e.buf

func lastByteOrZero*(e: BufferEmitter): char {.inline.} =
  ## Last byte appended so far, or `\0` for an empty buffer. Lets
  ## the preserve-walk decide whether an explicit separator (`\n`)
  ## is required between two top-level emissions without breaking
  ## the buffer's encapsulation.
  if e.buf.len == 0: '\0' else: e.buf[^1]

# ---------------------------------------------------------------------------
# Byte-writing primitives (perf-first)
# ---------------------------------------------------------------------------
#
# All push methods funnel through `appendBytes` and `appendByte`. These
# grow the buffer via `setLen` + raw-byte assignment, mirroring the
# trick the deleted encode.nim used to keep the hot path off the
# `add()` capacity-check loop.

func appendBytes(e: var BufferEmitter, bs: openArray[char]) {.inline.} =
  let oldLen = e.buf.len
  e.buf.setLen(oldLen + bs.len)
  for i in 0 ..< bs.len:
    e.buf[oldLen + i] = bs[i]

func appendByte(e: var BufferEmitter, b: char) {.inline.} =
  let oldLen = e.buf.len
  e.buf.setLen(oldLen + 1)
  e.buf[oldLen] = b

# ---------------------------------------------------------------------------
# Push API — synthesized path (openArray[char])
# ---------------------------------------------------------------------------

func appendIndent(e: var BufferEmitter) {.inline.} =
  if e.depth <= MaxCachedIndentDepth:
    e.appendBytes(Indents[e.depth])
  else:
    for _ in 0 ..< e.depth:
      e.appendBytes(IndentUnit)

func appendQuotedString(e: var BufferEmitter, s: openArray[char])
func appendIdent(e: var BufferEmitter, name: openArray[char]) {.inline.} =
  ## Emit `name` in whichever form the KDL v2 grammar requires: bare
  ## if `lexer.isBareword(name)` accepts it, quoted form otherwise.
  ## Single source of truth — both sides of the parse/emit duality
  ## consult `lexer.isBareword`. When the spec evolves, both update
  ## through that one predicate.
  if isBareword(name):
    e.appendBytes(name)
  else:
    e.appendQuotedString(name)

func appendAnno(e: var BufferEmitter, anno: openArray[char]) {.inline.} =
  ## Emit `(anno)` when anno is non-empty. Empty `anno` is the "no
  ## annotation" sentinel; literal `()` is illegal KDL so the sentinel
  ## is unambiguous. The tag content rides through `appendIdent` —
  ## bareword if the bytes pass `lexer.isBareword`, quoted otherwise.
  ## An explicit empty-string tag `("")` is NOT expressible via the
  ## sentinel; consumers needing it should bypass this helper.
  if anno.len > 0:
    e.appendByte('(')
    e.appendIdent(anno)
    e.appendByte(')')

func consumeSlashdash(e: var BufferEmitter) {.inline.} =
  if e.slashdashPending:
    e.appendBytes(KdlSlashdash)
    e.slashdashPending = false

func pushNodeBegin*(e: var BufferEmitter, name: openArray[char],
                    anno: openArray[char] = "") =
  ## Begin a node with the given name. Subsequent pushArg* / pushProp*
  ## attach entries; pushChildrenBegin / pushChildrenEnd nest a child
  ## block; pushNodeEnd terminates. Caller is responsible for protocol
  ## balance. Empty `anno` means no annotation.
  ##
  ## `name` is routed through `appendIdent` — if `lexer.isBareword`
  ## rejects the byte sequence (empty, leading digit, reserved
  ## keyword, special char, control codepoint, etc.) the wire form
  ## uses quoted-string syntax instead.
  e.appendIndent()
  e.consumeSlashdash()
  e.appendAnno(anno)
  e.appendIdent(name)

func pushNodeEnd*(e: var BufferEmitter) =
  ## Terminate the current node. Canonical mode emits a single newline
  ## as the node terminator.
  e.appendByte('\n')

func pushChildrenBegin*(e: var BufferEmitter) =
  ## Open a child block on the currently-open node. Emits ` {\n` and
  ## increments nesting depth. If a slashdash is pending, the `/-`
  ## marker prefixes the opening brace.
  e.appendByte(' ')
  e.consumeSlashdash()
  e.appendBytes("{\n")
  inc e.depth

func pushChildrenEnd*(e: var BufferEmitter) =
  ## Close the current child block. Decrements depth, emits the
  ## closing `}` at the new (outer) indent. Caller will follow with
  ## pushNodeEnd to terminate the enclosing node.
  dec e.depth
  e.appendIndent()
  e.appendByte('}')

# ---------------------------------------------------------------------------
# Slashdash brackets
# ---------------------------------------------------------------------------

func pushSlashdashBegin*(e: var BufferEmitter) =
  ## Mark the next push (node / arg / prop / children block) as
  ## slashdashed. The actual `/-` bytes are emitted by the next push.
  ## Begin/End brackets give P1 round-trip symmetry with cursor events.
  e.slashdashPending = true

func pushSlashdashEnd*(e: var BufferEmitter) =
  ## Marker for protocol balance — paired with pushSlashdashBegin. No
  ## bytes emitted; the wire form has no closing slashdash token.
  discard

# ---------------------------------------------------------------------------
# Typed-value argument pushes (codegen zero-overhead path)
# ---------------------------------------------------------------------------
#
# deriveEncode emits direct calls to these — no KdlValue construction,
# no kind-discriminant dispatch on the hot path. Each method is
# responsible for the leading separator (space before the value when an
# entry is being added to an open node).

func pushArgInt*(e: var BufferEmitter, v: int64,
                 anno: openArray[char] = "") =
  ## Append a positional integer argument to the currently-open node.
  ## Empty `anno` means no annotation. Numeric formatting goes through
  ## `numlit.formatInt` — the symmetric counterpart of the lexer's
  ## `decodeIntFromToken`. Single source of truth for int → wire bytes.
  e.appendByte(' ')
  e.consumeSlashdash()
  e.appendAnno(anno)
  e.appendBytes(formatInt(v))

# ---------------------------------------------------------------------------
# Typed value formatters (shared between Arg and Prop paths)
# ---------------------------------------------------------------------------

const HexDigits = "0123456789abcdef"

func appendU16Escape(e: var BufferEmitter, b: char) {.inline.} =
  ## Emit `\u{HH}` for a control byte. Lowercase hex matches the
  ## kdl-org corpus's canonical form.
  e.appendBytes("\\u{")
  let u = uint8(b)
  if u < 0x10:
    e.appendByte(HexDigits[int(u)])
  else:
    e.appendByte(HexDigits[int(u shr 4)])
    e.appendByte(HexDigits[int(u and 0x0f)])
  e.appendByte('}')

func appendQuotedString(e: var BufferEmitter, s: openArray[char]) =
  ## Emit `"..."` form. Escape policy is the dual of the lexer's
  ## acceptance rules:
  ##   - Backslash and double-quote always require `\\` / `\"`
  ##   - Common whitespace gets the named escape: \n \r \t \b \f
  ##   - Other control bytes (per `lexer.isDisallowedControl`) need
  ##     `\u{XX}` since the lexer rejects them literally
  ##   - Everything else passes through verbatim
  e.appendByte('"')
  for c in s:
    case c
    of '\\': e.appendBytes("\\\\")
    of '"':  e.appendBytes("\\\"")
    of '\n': e.appendBytes("\\n")
    of '\r': e.appendBytes("\\r")
    of '\t': e.appendBytes("\\t")
    of '\x08': e.appendBytes("\\b")  # backspace
    of '\x0c': e.appendBytes("\\f")  # form feed
    else:
      if isDisallowedControl(c):
        e.appendU16Escape(c)
      else:
        e.appendByte(c)
  e.appendByte('"')

func appendString(e: var BufferEmitter, s: openArray[char]) =
  ## Public name preserved for the typed-value pushArgString /
  ## pushPropString paths. Identical to appendQuotedString.
  e.appendQuotedString(s)

func encodeKdlString*(s: string): string =
  ## Encode `s` as a valid double-quoted KDL v2 string literal (surrounding
  ## quotes INCLUDED), escaping ONLY what KDL requires — `\\`, `\"`, the named
  ## whitespace escapes (`\n \r \t \b \f`), and `\u{XX}` for other control
  ## bytes; every other byte passes through verbatim. Round-trip stable:
  ## re-parsing the result yields back `s`. Use this — not `std/strutils.escape`
  ## (which emits Nim escapes like `\'` that the KDL lexer rejects) — when
  ## splicing an arbitrary value into hand-written KDL text. `func`, so it is
  ## usable in `const`/`static:` context.
  var e = newBufferEmitter()
  e.appendQuotedString(s)
  e.finish()

func appendFloat(e: var BufferEmitter, v: float64) {.inline.} =
  ## Routes through `numlit.formatFloat` — single source of truth for
  ## float → wire bytes, symmetric with `decodeFloatFromToken`. The
  ## module-qualified call disambiguates against `strutils.formatFloat`
  ## (a different signature, accidentally imported as part of strutils
  ## for `IndentUnit.repeat`).
  e.appendBytes(numlit.formatFloat(v))

func appendBool(e: var BufferEmitter, v: bool) {.inline.} =
  if v: e.appendBytes(KdlKeywordLiterals[klTrue])
  else: e.appendBytes(KdlKeywordLiterals[klFalse])

func appendNull(e: var BufferEmitter) {.inline.} =
  e.appendBytes(KdlKeywordLiterals[klNull])

func appendBigInt(e: var BufferEmitter, hi, lo: uint64, negative: bool)
    {.inline.} =
  ## Routes through `numlit.formatBigInt` — single source of truth for
  ## the 128-bit decimal magnitude rendering. Symmetric with
  ## `decodeIntPromoting` on the parse side.
  e.appendBytes(formatBigInt(hi, lo, negative))

# ---------------------------------------------------------------------------
# Typed-value arg pushes (string / float / bool / null)
# ---------------------------------------------------------------------------

func pushArgString*(e: var BufferEmitter, v: openArray[char],
                    anno: openArray[char] = "") =
  e.appendByte(' ')
  e.consumeSlashdash()
  e.appendAnno(anno)
  e.appendString(v)

func pushArgFloat*(e: var BufferEmitter, v: float64,
                   anno: openArray[char] = "") =
  e.appendByte(' ')
  e.consumeSlashdash()
  e.appendAnno(anno)
  e.appendFloat(v)

func pushArgBool*(e: var BufferEmitter, v: bool,
                  anno: openArray[char] = "") =
  e.appendByte(' ')
  e.consumeSlashdash()
  e.appendAnno(anno)
  e.appendBool(v)

func pushArgNull*(e: var BufferEmitter, anno: openArray[char] = "") =
  e.appendByte(' ')
  e.consumeSlashdash()
  e.appendAnno(anno)
  e.appendNull()

func pushArgBigInt*(e: var BufferEmitter, hi, lo: uint64, negative: bool,
                    anno: openArray[char] = "") =
  ## Append a positional >int64 argument (128-bit magnitude + sign). The
  ## value-typed counterpart of the `dispatchValue` bigint path, for the
  ## self-contained node walker (no KdlValue construction).
  e.appendByte(' ')
  e.consumeSlashdash()
  e.appendAnno(anno)
  e.appendBigInt(hi, lo, negative)

# ---------------------------------------------------------------------------
# Typed-value property pushes (codegen zero-overhead path)
# ---------------------------------------------------------------------------

func appendPropPrefix(e: var BufferEmitter, key: openArray[char],
                      anno: openArray[char]) {.inline.} =
  ## Shared lead-in for all pushProp* methods: ` key=(anno)`. The key
  ## rides through `appendIdent` (bareword-or-quoted decision).
  e.appendByte(' ')
  e.consumeSlashdash()
  e.appendIdent(key)
  e.appendByte('=')
  e.appendAnno(anno)

func pushPropInt*(e: var BufferEmitter, key: openArray[char], v: int64,
                  anno: openArray[char] = "") =
  ## Append a `key=int` property to the currently-open node. The key is
  ## emitted as a bareword; quoted-form fallback for non-bareword-safe
  ## keys lands when a real use case surfaces. Empty `anno` means no
  ## value annotation.
  e.appendPropPrefix(key, anno)
  e.appendBytes($v)

func pushPropString*(e: var BufferEmitter, key: openArray[char],
                     v: openArray[char], anno: openArray[char] = "") =
  e.appendPropPrefix(key, anno)
  e.appendString(v)

func pushPropFloat*(e: var BufferEmitter, key: openArray[char], v: float64,
                    anno: openArray[char] = "") =
  e.appendPropPrefix(key, anno)
  e.appendFloat(v)

func pushPropBool*(e: var BufferEmitter, key: openArray[char], v: bool,
                   anno: openArray[char] = "") =
  e.appendPropPrefix(key, anno)
  e.appendBool(v)

func pushPropNull*(e: var BufferEmitter, key: openArray[char],
                   anno: openArray[char] = "") =
  e.appendPropPrefix(key, anno)
  e.appendNull()

func pushPropBigInt*(e: var BufferEmitter, key: openArray[char],
                     hi, lo: uint64, negative: bool,
                     anno: openArray[char] = "") =
  e.appendPropPrefix(key, anno)
  e.appendBigInt(hi, lo, negative)

# ---------------------------------------------------------------------------
# KdlValue convenience dispatcher (Cat 3 docEmit consumers)
# ---------------------------------------------------------------------------
#
# Codegen (Cat 2) goes straight to pushArgInt / pushArgString / etc.
# docEmit holds KdlValue in hand and wants one entry point; these
# dispatchers resolve the value-kind variant and the interned
# typeAnnotation, then forward to the matching typed primitive. The
# interner lookup currently allocates a string (intern.nim:lookup).
# That's the AST convenience tax — the codegen path pays nothing
# because it never constructs a KdlValue.

# ---------------------------------------------------------------------------
# Self-contained value walker pushes (used by node_emit). Annotation is
# Option[string], so `none` vs `some("")` is distinguishable — the latter
# renders `("")` so an explicit empty type annotation round-trips byte-exactly
# (which the string-anno primitives above cannot express).
# ---------------------------------------------------------------------------

func appendAnnoOpt(e: var BufferEmitter, anno: Option[string]) {.inline.} =
  if anno.isSome:
    e.appendByte('(')
    e.appendIdent(anno.get)   # "" → quoted empty → renders as ("")
    e.appendByte(')')

func dispatchValueV(e: var BufferEmitter, v: value.KdlValue) =
  case v.kind
  of value.kvString: e.appendString(v.strVal)
  of value.kvInt:    e.appendBytes(formatInt(v.intVal))
  of value.kvBigInt: e.appendBigInt(v.bigHi, v.bigLo, v.bigNegative)
  of value.kvFloat:  e.appendFloat(v.floatVal)
  of value.kvBool:   e.appendBool(v.boolVal)
  of value.kvNull:   e.appendNull()

func pushArgV*(e: var BufferEmitter, v: value.KdlValue) =
  ## Positional argument from a self-contained KdlValue.
  e.appendByte(' ')
  e.consumeSlashdash()
  e.appendAnnoOpt(v.typeAnnotation)
  e.dispatchValueV(v)

func pushPropV*(e: var BufferEmitter, key: openArray[char], v: value.KdlValue) =
  ## `key=value` property from a self-contained KdlValue.
  e.appendByte(' ')
  e.consumeSlashdash()
  e.appendIdent(key)
  e.appendByte('=')
  e.appendAnnoOpt(v.typeAnnotation)
  e.dispatchValueV(v)

func pushNodeBeginV*(e: var BufferEmitter, name: openArray[char],
                     anno: Option[string]) =
  ## Begin a node with an Option[string] annotation (distinguishes `("")`).
  e.appendIndent()
  e.consumeSlashdash()
  e.appendAnnoOpt(anno)
  e.appendIdent(name)

# ---------------------------------------------------------------------------
# KdlEmitter concept — symmetric inverse of KdlCursor
# ---------------------------------------------------------------------------

type
  KdlEmitter* = concept var e
    ## The OUT-side substrate. Any type providing this surface can act
    ## as the destination for Cat 1 / Cat 2 / Cat 3 OUT producers.
    ## BufferEmitter is the default prod impl. Tracing / size-counting
    ## impls land in the property-test infrastructure (A11+).
    ##
    ## Minimal surface — only the structural events. The typed-value
    ## pushArg*/pushProp* variants and the KdlValue dispatchers live
    ## outside the concept because not every impl needs every value
    ## type (a tracing emitter that just records call patterns doesn't
    ## need to format floats), but every impl needs the structural
    ## bracket pair to round-trip cursor events.
    e.pushNodeBegin("name", "")
    e.pushNodeEnd()
    e.pushChildrenBegin()
    e.pushChildrenEnd()
    e.pushSlashdashBegin()
    e.pushSlashdashEnd()

func pushPreservedBytes*(e: var BufferEmitter, bytes: openArray[char]) =
  ## Escape hatch: emit raw wire bytes verbatim, bypassing the
  ## structural-event protocol. Honest about what it is — the caller
  ## (typically `emitDocPreserve`) is asserting that `bytes` is a
  ## valid KDL fragment whose structural position matches what would
  ## otherwise have come out of pushNodeBegin / ... / pushNodeEnd.
  ##
  ## Stays out of the KdlEmitter concept on purpose: not every impl
  ## can meaningfully accept raw bytes (a tracing emitter that records
  ## structural-event call shapes has nothing to do with raw bytes).
  ## Preserve-mode consumers depend on this BufferEmitter-specific
  ## extension; canonical-mode consumers don't.
  ##
  ## Does NOT touch the depth / slashdashPending state. Preserve-mode
  ## clean-subtree splicing happens at node boundaries where neither
  ## state should be in flight; if the caller breaks that invariant,
  ## subsequent structural pushes produce malformed output. The
  ## constraint is a contract, not a runtime check.
  e.appendBytes(bytes)

template validateKdlEmitter*(T: typedesc) =
  ## Compile-time witness that T satisfies KdlEmitter. Nim's concept
  ## error messages are infamously hostile; this template forces the
  ## check at a known site so failures point at "this type doesn't
  ## satisfy KdlEmitter" instead of at some deep generic instantiation.
  static:
    var sample: T
    sample.pushNodeBegin("name", "")
    sample.pushNodeEnd()
    sample.pushChildrenBegin()
    sample.pushChildrenEnd()
    sample.pushSlashdashBegin()
    sample.pushSlashdashEnd()
