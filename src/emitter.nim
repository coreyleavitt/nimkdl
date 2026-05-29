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
