import std/[math, strutils]

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

func appendAnno(e: var BufferEmitter, anno: openArray[char]) {.inline.} =
  ## Emit `(anno)` when anno is non-empty. Empty `anno` is the "no
  ## annotation" sentinel; literal `()` is illegal KDL so the sentinel
  ## is unambiguous. Anno bytes go through as bareword — KDL reserved
  ## tags (`u8`, `i64`, `ipv4`, `url`, etc.) are bareword-safe by
  ## construction. Quoted-form annotation is a follow-on once a real
  ## use case surfaces; the spec permits it but no realistic anno
  ## requires it.
  if anno.len > 0:
    e.appendByte('(')
    e.appendBytes(anno)
    e.appendByte(')')

func consumeSlashdash(e: var BufferEmitter) {.inline.} =
  if e.slashdashPending:
    e.appendBytes("/-")
    e.slashdashPending = false

func pushNodeBegin*(e: var BufferEmitter, name: openArray[char],
                    anno: openArray[char] = "") =
  ## Begin a node with the given name. Subsequent pushArg* / pushProp*
  ## attach entries; pushChildrenBegin / pushChildrenEnd nest a child
  ## block; pushNodeEnd terminates. Caller is responsible for protocol
  ## balance. Empty `anno` means no annotation.
  e.appendIndent()
  e.consumeSlashdash()
  e.appendAnno(anno)
  e.appendBytes(name)

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
  ## Empty `anno` means no annotation.
  e.appendByte(' ')
  e.consumeSlashdash()
  e.appendAnno(anno)
  # Render via the stdlib int-to-string fast path. Switching to a
  ## numlit-based formatter is a Stage A follow-on if profiling shows
  ## the alloc here mattering.
  e.appendBytes($v)

# ---------------------------------------------------------------------------
# Typed value formatters (shared between Arg and Prop paths)
# ---------------------------------------------------------------------------

func appendString(e: var BufferEmitter, s: openArray[char]) =
  ## Emit a KDL v2 quoted string with the minimal-required escape set:
  ## backslash, double-quote, newline, carriage return, tab. Other
  ## control chars and surrogates are valid runes but if they appear
  ## raw the spec allows them through; we don't proactively escape
  ## them. A more conservative escape policy is a follow-on if the
  ## P12 round-trip property turns one up.
  e.appendByte('"')
  for c in s:
    case c
    of '\\': e.appendBytes("\\\\")
    of '"':  e.appendBytes("\\\"")
    of '\n': e.appendBytes("\\n")
    of '\r': e.appendBytes("\\r")
    of '\t': e.appendBytes("\\t")
    else:    e.appendByte(c)
  e.appendByte('"')

func appendFloat(e: var BufferEmitter, v: float64) =
  ## KDL v2 keyword path for non-finite floats; stdlib `$` for the
  ## finite case. The Nim default formatter inserts a fractional `.0`
  ## for whole-valued floats (so `2.0` not `2`), which is exactly the
  ## spec's typed-float disambiguation rule.
  if v.classify == fcNan:
    e.appendBytes("#nan")
  elif v.classify == fcInf:
    e.appendBytes("#inf")
  elif v.classify == fcNegInf:
    e.appendBytes("#-inf")
  else:
    e.appendBytes($v)

func appendBool(e: var BufferEmitter, v: bool) {.inline.} =
  if v: e.appendBytes("#true") else: e.appendBytes("#false")

func appendNull(e: var BufferEmitter) {.inline.} =
  e.appendBytes("#null")

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

# ---------------------------------------------------------------------------
# Typed-value property pushes (codegen zero-overhead path)
# ---------------------------------------------------------------------------

func appendPropPrefix(e: var BufferEmitter, key: openArray[char],
                      anno: openArray[char]) {.inline.} =
  ## Shared lead-in for all pushProp* methods: ` key=(anno)`.
  e.appendByte(' ')
  e.consumeSlashdash()
  e.appendBytes(key)
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
