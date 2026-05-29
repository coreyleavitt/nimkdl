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

type
  BufferEmitter* = object
    ## Prod impl: writes wire bytes into an internal string buffer.
    ## `finish()` returns the accumulated string and (logically) ends
    ## the emitter's life.
    buf: string

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

func pushNodeBegin*(e: var BufferEmitter, name: openArray[char]) =
  ## Begin a node with the given name. Subsequent pushArg* / pushProp*
  ## attach entries; pushChildrenBegin / pushChildrenEnd nest a child
  ## block; pushNodeEnd terminates. Caller is responsible for protocol
  ## balance.
  e.appendBytes(name)

func pushNodeEnd*(e: var BufferEmitter) =
  ## Terminate the current node. Canonical mode emits a single newline
  ## as the node terminator.
  e.appendByte('\n')

# ---------------------------------------------------------------------------
# Typed-value argument pushes (codegen zero-overhead path)
# ---------------------------------------------------------------------------
#
# deriveEncode emits direct calls to these — no KdlValue construction,
# no kind-discriminant dispatch on the hot path. Each method is
# responsible for the leading separator (space before the value when an
# entry is being added to an open node).

func pushArgInt*(e: var BufferEmitter, v: int64) =
  ## Append a positional integer argument to the currently-open node.
  e.appendByte(' ')
  # Render via the stdlib int-to-string fast path. Switching to a
  ## numlit-based formatter is a Stage A follow-on if profiling shows
  ## the alloc here mattering.
  e.appendBytes($v)
