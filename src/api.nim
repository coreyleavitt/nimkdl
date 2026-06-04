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

import std/macros  # `error` — compile-time {.error.} emission for embed/embedFile (D1)
import std/options  # Option access for the node prop/arg lookup (decodeProp/decodeArg, review #10)

import ./cursor
import ./derive_decode  # for kdlDecode mixin resolution + Result/ParseError
import ./emitter
import ./lexer
import ./node          # KdlNode / KdlDoc (decodeNode source-slice + rebase, N2)
import ./node_emit     # encode(node) — the re-emit fallback (N1)
import ./spans

# Intentionally NOT importing derive_encode here. `encode[T]`'s
# `mixin kdlEncode` resolves at the user's instantiation site, where
# the user has invoked `deriveEncode(T)` (typically via `kdl:` or
# directly). Importing it here would only add to the warning surface
# without changing resolution semantics.

export spans  # Result, ParseError visible without extra imports

proc decodeInternal*[T](src: string):
    Result[T, ParseError] {.noSideEffect, raises: [].} =
  ## Core decode — the un-enriched variant (rfc-consumer-api §4.4 enrichment
  ## contract). Returns errors with **slice-local, source-less** offsets:
  ## `line`/`col`/`sourcePath` are left as `initError` produced them (`0`/`""`).
  ##
  ## `decode[T]` wraps this and enriches once at its boundary; `decodeNode[T]`
  ## wraps it to `rebased` the offset into the owning doc FIRST, then enrich —
  ## the only order that yields correct absolute line/col for a sliced node
  ## (§9 item 3). Enriching here would compute slice-local coordinates and
  ## defeat the rebase. Not a public entry point in spirit, but `*`-exported so
  ## the node-decode path (a different module boundary) can reach it.
  mixin kdlDecode
  var stream = lex(src)
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

proc decode*[T](src: string, sourcePath = "<input>"):
    Result[T, ParseError] {.noSideEffect, raises: [].} =
  ## Parse `src` and decode into a value of type `T`.
  ##
  ## For object types with `{.kdlNode.}`, expects a single top-level
  ## node and returns the decoded value.
  ##
  ## Returns the first error encountered (single-shot). `sourcePath` is the
  ## attribution that renders in `$err` (e.g. `"config.kdl"`); defaults to
  ## `"<input>"` for in-memory sources.
  ##
  ## Public boundary: enriches errors with line/col + sourcePath once, here,
  ## where `src` is in hand (rfc-consumer-api §4.4). The actual decode is
  ## `decodeInternal[T]`, which produces source-less errors.
  let r = decodeInternal[T](src)
  if r.isErr: return err[T, ParseError](r.getErr.enriched(src, sourcePath))
  r

proc decodeFile*[T](path: string):
    Result[T, ParseError] {.raises: [].} =
  ## Read the file at `path` and decode its contents into `T`, attributing
  ## errors to `path` (rfc-consumer-api §4.3, C2).
  ##
  ## ## The one effectful entry — I/O boundary conversion (§4.5)
  ##
  ## `readFile` can raise `IOError`/`OSError` (missing path, permission
  ## denied, a read fault mid-stream). `decodeFile` catches these at the
  ## boundary and converts them into a `peIOError` `ParseError` — a real
  ## exceptional condition lifted into the library's `Result` currency, NOT
  ## an escape hatch. This catch-and-convert is exactly what lets the whole
  ## public decode surface stay `{.raises:[].}`: the one place I/O can fail
  ## is sealed here, so `IOError` never propagates to callers.
  ##
  ## A successful read threads `path` as the `sourcePath`, so any parse/type
  ## error renders as `path:line:col:` against the real file.
  let content =
    try:
      readFile(path)
    except IOError, OSError:
      let e = getCurrentException()
      return err[T, ParseError](initError(
        peIOError, Span(),
        "could not read '" & path & "': " & e.msg))
  decode[T](content, path)

proc encode*[T](v: T): string {.raises: [].} =
  ## Encode `v` to KDL wire bytes.
  ##
  ## For object types with `{.kdlNode.}`, emits a single top-level node.
  ## For `seq[U]` where U is `{.kdlNode.}`-tagged, emits one node per
  ## element.
  ##
  ## ## Why a bare string
  ##
  ## Encode is structurally total — the emitter just appends bytes from an
  ## in-memory typed value, so no error can occur. The earlier
  ## `Result[string, ParseError]` (kept "for symmetry with decode" / future
  ## validation) was unjustified: it forced every call site through `.get`
  ## for an error that cannot happen. Aligns with `encode(node)` /
  ## `encode(doc)`, which are also bare strings.
  mixin kdlEncode
  var e = newBufferEmitter()
  when T is seq:
    for elem in v: kdlEncode(elem, e)
  else:
    kdlEncode(v, e)
  e.finish()

proc decodeAll*[T](src: string, sourcePath = "<input>"):
    Parsed[T] {.noSideEffect, raises: [].} =
  ## Multi-error variant of `decode[T]`. T must be `seq[U]` — single-
  ## node decodeAll would be the same as `decode`. On a decoder error
  ## for one top-level node, the cursor advances past the offending
  ## node and decoding continues. Returns a `Parsed[T]` carrying the
  ## populated partial value alongside every error encountered.
  ## `sourcePath` attributes each collected error (default `"<input>"`).
  static:
    when not (T is seq):
      {.error: "decodeAll[T] requires T to be a seq[U]. For single-node "
              & "decode use decode[T] which already returns Result.".}
  mixin kdlDecode
  type Elem = typeof(default(T)[0])
  var stream = lex(src)
  var c = initStringCursor(addr stream, src, cmAccumulating)
  var values: T = @[]
  var errors: seq[ParseError] = @[]
  # Build the LineMap ONCE over `src`, not per erroring node (review #3-residual):
  # the per-error `enriched(src, ...)` overload rescans the whole source on each
  # call, so an error-dense source paid O(N·n). Enrich each error through the
  # prebuilt-map overload instead — O(n + N·log n). Coordinates are identical
  # (both compute `lineColOf` over the same absolute offset). This mirrors the
  # per-doc cached LineMap the node-by-node path already uses (review #3).
  let lm = buildLineMap(src)
  while c.peek.kind != ceEof:
    let ck = c.pos
    var elem: Elem
    let r = kdlDecode(elem, c)
    if r.isErr:
      # Public boundary: enrich with line/col + sourcePath (rfc §4.4).
      errors.add(r.getErr.enriched(lm, sourcePath))
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
  Parsed[T](value: values, errors: errors)

proc embed*[T](src: static[string], sourcePath: static[string] = "<embed>"): T {.raises: [].} =
  ## Compile-time decode of a static KDL source string into `T`. Thin
  ## delegating wrapper over `decode[T]` — single canonical compile-
  ## time decode path. `const cfg = embed[Service](kdlSrc)` materializes
  ## a constant value baked into the binary with zero runtime parse
  ## cost.
  ##
  ## `src` is **KDL source content** (not a path). For the path form use
  ## `embedFile[T](path)`, which staticReads the file and threads the real
  ## filename as `sourcePath` for attribution.
  ##
  ## On a parse/type error the build FAILS at compile time with a caret
  ## diagnostic (`formatError`) pointing at the offending span — a bad
  ## embedded literal is a build error, never a runtime defect.
  let r = decode[T](src, sourcePath)
  if r.isErr:
    error("embed[" & $T & "] failed to decode static KDL:\n" &
          formatError(r.getErr, src, sourcePath))
  r.get

macro embedFileImpl(T: typedesc, path: static[string]): untyped =
  ## Implementation core of `embedFile` (see the `template` below). Built
  ## as a macro so the generated `staticRead(path)` node inherits the
  ## **call site's** line info: `staticRead` resolves its path relative to
  ## the file where the call node lexically lives, and a hand-built node
  ## carries the expansion (call) site, not `api.nim`. A `quote do` here
  ## would re-stamp nodes with `api.nim`'s line info and resolve the path
  ## relative to `src/` (wrong). Emits `embed[T](staticRead(path), path)`.
  let read = newCall(ident"staticRead", newLit(path))
  result = newTree(nnkCall,
    newTree(nnkBracketExpr, ident"embed", T),
    read,
    newLit(path))

template embedFile*[T](path: static[string]): T =
  ## Compile-time read + decode of the KDL file at `path` into `T`.
  ## `const cfg = embedFile[Config]("config.kdl")` bakes the parsed value
  ## into the binary with zero runtime cost. Expands (via `embedFileImpl`)
  ## to `embed[T](staticRead(path), path)`.
  ##
  ## `path` resolves **relative to the file invoking `embedFile`** (Nim's
  ## `staticRead` semantics, preserved through the macro's call-site line
  ## info — verified D1). The real filename is threaded as `sourcePath`,
  ## so a decode failure's caret diagnostic names the source file.
  ##
  ## Distinct from `embed[T]` by NAME: `embed` = content, `embedFile` =
  ## path. No "is this string a path?" heuristic.
  embedFileImpl(T, path)

proc reEmitDecodeNode*[T](node: KdlNode):
    Result[T, ParseError] {.raises: [].} =
  ## Re-emit fallback for a node with **no source** (hand-built, `span.length
  ## == 0`): canonical-`encode` the node back to KDL text (N1's `encode(node)`),
  ## then `decode[T]` that text. Errors enrich against the re-emitted text,
  ## since no original source exists to attribute against.
  ##
  ## Shared helper: N2 calls it for the `length == 0` branch of
  ## `decodeNode[T](doc, node)`; the next slice (N2f) exposes the public doc-less
  ## `decodeNode[T](node)` overload on top of it. The round-trip hazards (scalar
  ## hooks, annotation requoting, Option/null materialization) are confined to
  ## this path and pinned by §8's N2f property tests.
  decode[T](encode(node))

proc decodeNode*[T](doc: KdlDoc, node: KdlNode):
    Result[T, ParseError] {.raises: [].} =
  ## Decode a single DOM `node` into `T`, reusing the one decoder over the
  ## node's **original source bytes** (rfc-consumer-api §4.2, the centerpiece).
  ##
  ## For a parsed node (`node.span.length > 0`) this slices the node's verbatim
  ## bytes out of `doc.sourceText`, decodes the slice un-enriched, then `rebased`
  ## the error offset into the full doc and `enriched`es it — so a type error
  ## reports the **true file line/col**, not a slice-local position (§4.4, §9
  ## item 3). Because the slice carries the node's real name, the derive
  ## decoder's `{.kdlNode.}` name check fires naturally: `decodeNode[Daemon](doc,
  ## n)` errors if `n.name != "daemon"`.
  ##
  ## For a hand-built node (`span.length == 0`, the no-source sentinel) it falls
  ## back to `reEmitDecodeNode[T]` (re-emit then decode).
  when T is seq:
    {.error: "decodeNode[T] expects a single node; decode the element type.".}
  let span = node.span
  # `span.offset`/`span.length` are int accessors widened from the span's uint32
  # fields, so the sum stays within int and cannot overflow. Guard the slice:
  # a hand-built node (`length == 0`) has no source, and a node whose span
  # overshoots `doc.sourceText` is FOREIGN/STALE — parsed against a different or
  # since-shortened source. Either way an unguarded slice is an IndexDefect (a
  # Defect bypassing {.raises:[].}). Re-emit is the correct fallback: the node
  # carries its real name/entries/children regardless of a bad span, so it
  # decodes correctly (rfc §9.3 hazards aside) rather than crashing.
  if span.length == 0 or span.offset + span.length > doc.sourceText.len:
    return reEmitDecodeNode[T](node)
  let slice = doc.sourceText[span.offset ..< span.offset + span.length]
  let r = decodeInternal[T](slice)
  if r.isErr:
    # Rebase FIRST (slice-local offset → absolute offset in doc.sourceText),
    # THEN enrich (compute line/col from the absolute offset). This order is
    # mandatory (§4.4): enriching before rebasing yields slice-local line/col.
    let absErr = r.getErr.rebased(span.offset)
    # Enrich against the doc's once-built LineMap (review #3): node-by-node
    # decode reuses `doc.lineMap` instead of rescanning `doc.sourceText` per
    # erroring node — O(n + N·log n), not O(N·n). Coordinates are identical to
    # the source-text overload (both `lineColOf` the same absolute offset).
    return err[T, ParseError](absErr.enriched(doc.lineMap, doc.sourcePath))
  r

proc decodeNode*[T](node: KdlNode):
    Result[T, ParseError] {.raises: [].} =
  ## Decode a hand-built (source-less) DOM `node` into `T` via re-emit.
  ##
  ## .. warning:: **Doc-less re-emit fallback — lossier than `decodeNode(doc, node)`.**
  ##   This overload exists for nodes built **programmatically** (no source span:
  ##   `node.span.length == 0`). It re-emits the node to canonical KDL text via
  ##   `encode(node)` and decodes *that text*, so the result may **differ** from
  ##   the source-slice `decodeNode(doc, node)` path (rfc-consumer-api §9.3) for:
  ##
  ##   - **`kdlScalar` hooks** — the value is re-encoded through `kdlEncodeValue`
  ##     and re-decoded through `kdlDecodeValue`, a full round-trip rather than a
  ##     verbatim byte read.
  ##   - **annotation requoting** — type annotations on values/nodes are
  ##     re-rendered canonically, not echoed from the original bytes.
  ##   - **Option / null materialization** — presence/absence is reconstructed
  ##     from the canonical re-emission, not the original token stream.
  ##
  ##   **Use the `(doc, node)` form whenever a parsed doc is in hand** — it reads
  ##   the node's verbatim original bytes and carries true source line/col on
  ##   errors. Reserve this bare form for hand-built nodes where no source exists.
  ##   The §8 N2f round-trip property tests pin these hazards so the path stays
  ##   honest even though the call site can't see the degradation.
  reEmitDecodeNode[T](node)

proc decodeChild*[T](doc: KdlDoc, parent: KdlNode, childName: string):
    Result[T, ParseError] {.raises: [].} =
  ## Decode the FIRST child of `parent` named `childName` into `T`
  ## (rfc-consumer-api §4.2, N3). **First-wins on duplicate children** — reuses
  ## the `node.child(name)` lookup, which returns the first match in source
  ## order. The found child is decoded via `decodeNode[T](doc, node)`, so a
  ## parsed child carries true source line/col on errors (and a hand-built
  ## child's `span.length == 0` routes through the re-emit fallback).
  ##
  ## If `parent` has no child named `childName`, returns a `peTypeMissingRequired`
  ## error whose `hint` names the missing child and its parent for context.
  let kid = parent.child(childName)
  if kid.isNil:
    # Enrich at this public entry point (rfc §4.4): without it the error renders
    # :0:0: while the type-mismatch leg (via decodeNode) renders true file
    # line/col. `doc` is in hand, so attribute against it.
    let e = initError(
      peTypeMissingRequired, parent.span,
      "no child named '" & childName & "' in node '" & parent.name & "'")
    return err[T, ParseError](e.enriched(doc.lineMap, doc.sourcePath))
  decodeNode[T](doc, kid)

func bigIntToFloat(v: KdlValue): float {.inline.} =
  ## Widen a `kvBigInt` magnitude to `float`. Mirrors the derive/reserved legs
  ## that treat any KDL integer as float-compatible (`validateF64` accepts
  ## kvBigInt): KDL is a textual format and a 128-bit integer is a legitimate
  ## (if lossy) float source. Magnitude is `(bigHi shl 64) or bigLo`; we build
  ## it as `bigHi * 2^64 + bigLo` in float space (exact for the high/low split,
  ## then rounded to nearest double as any int→float widening is).
  const twoPow64 = 18446744073709551616.0  # 2^64
  let mag = float(v.bigHi) * twoPow64 + float(v.bigLo)
  if v.bigNegative: -mag else: mag

func builtinScalarFromValue*[T](v: KdlValue): Result[T, ParseError]
    {.noSideEffect, raises: [].} =
  ## Single source of truth for the **value → built-in scalar** mapping
  ## (rfc-consumer-api §4.6; review #7). Maps an already-materialized `KdlValue`
  ## onto a built-in scalar `T` (`string`/`bool`/`int*`/`uint*`/`float*`/`enum`),
  ## producing the canonical kind-match errors. `coerce`'s built-in branch routes
  ## through here, so the kind-match predicate + message catalog have ONE home
  ## and cannot drift from the value leg.
  ##
  ## This is the **value-level** twin of `derive_decode`'s token-level dispatch.
  ## The two legs operate at different layers (tokens vs a materialized value) so
  ## they legitimately stay separate dispatchers; this helper is the value leg's
  ## sole authority and carries `kvBigInt` handling (review #5) so every
  ## value-consumer agrees.
  ##
  ## Custom `{.kdlScalar.}` types (those with a `kdlDecodeValue` hook) are NOT
  ## handled here — `coerce` routes those through the hook before reaching this
  ## helper. This is built-ins only.
  when T is enum:
    if v.kind != kvString:
      return err[T, ParseError](initError(peTypeMismatch, Span(),
        "expected string value for enum"))
    for e in low(T) .. high(T):
      if $e == v.strVal:
        return ok[T, ParseError](e)
    return err[T, ParseError](initError(peTypeEnumInvalid, Span(),
      msgEnumNoVariant))
  elif T is string:
    if v.kind != kvString:
      return err[T, ParseError](initError(peTypeMismatch, Span(),
        msgExpectedString))
    return ok[T, ParseError](v.strVal)
  elif T is bool:
    if v.kind != kvBool:
      return err[T, ParseError](initError(peTypeMismatch, Span(),
        msgExpectedBool))
    return ok[T, ParseError](v.boolVal)
  elif T is SomeFloat:
    case v.kind
    of kvFloat:  return ok[T, ParseError](T(v.floatVal))
    of kvInt:    return ok[T, ParseError](T(v.intVal))      # int→float widening
    of kvBigInt: return ok[T, ParseError](T(bigIntToFloat(v)))  # bigint→float (review #5)
    else:
      return err[T, ParseError](initError(peTypeMismatch, Span(),
        msgExpectedFloat))
  elif T is SomeSignedInt:
    case v.kind
    of kvInt:
      if v.intVal < low(T).int64 or v.intVal > high(T).int64:
        return err[T, ParseError](initError(peTypeIntegerOverflow, Span(),
          codeMessage(peTypeIntegerOverflow)))
      return ok[T, ParseError](T(v.intVal))
    of kvBigInt:
      # A kvBigInt is produced only when a literal overflows int64; its
      # magnitude is therefore outside the range of EVERY int64-bounded signed
      # target (int8..int64). Honest overflow, NOT a kind mismatch (review #5).
      return err[T, ParseError](initError(peTypeIntegerOverflow, Span(),
        codeMessage(peTypeIntegerOverflow)))
    else:
      return err[T, ParseError](initError(peTypeMismatch, Span(),
        msgExpectedInt))
  elif T is SomeUnsignedInt:
    case v.kind
    of kvInt:
      if v.intVal < 0:
        return err[T, ParseError](initError(peTypeMismatch, Span(),
          msgExpectedUintNonNeg))
      if uint64(v.intVal) > high(T).uint64:
        return err[T, ParseError](initError(peTypeIntegerOverflow, Span(),
          codeMessage(peTypeIntegerOverflow)))
      return ok[T, ParseError](T(v.intVal))
    of kvBigInt:
      if v.bigNegative:
        return err[T, ParseError](initError(peTypeMismatch, Span(),
          msgExpectedUintNonNeg))
      # Non-negative bigint: fits target iff magnitude <= high(T). bigHi != 0
      # means >= 2^64 > any uint64-bounded target; bigHi == 0 means magnitude
      # is bigLo, fits iff bigLo <= high(T).
      if v.bigHi == 0 and v.bigLo <= high(T).uint64:
        return ok[T, ParseError](T(v.bigLo))
      return err[T, ParseError](initError(peTypeIntegerOverflow, Span(),
        codeMessage(peTypeIntegerOverflow)))
    else:
      return err[T, ParseError](initError(peTypeMismatch, Span(),
        msgExpectedUint))
  else:
    {.error: "builtinScalarFromValue[T]: unsupported scalar type '" & $T & "'. " &
             "Supported: string/bool/int*/uint*/float*/enum.".}

proc coerce*[T](val: KdlValue): Result[T, ParseError] {.noSideEffect, raises: [].} =
  ## Coerce a single `KdlValue` into a scalar `T` — the **value leg** of the
  ## typed bridge (rfc-consumer-api §4.6, V1): source→T (`decode`), node→T
  ## (`decodeNode`), value→T (`coerce`). Named `coerce` (not a third `decode`
  ## overload) to keep a single dispatch axis per entry concept.
  ##
  ## `coerce` is for **scalars only**. It reads the already-parsed typed payload
  ## off the `KdlValue` (no re-parsing of bytes) and maps it to `T`:
  ##
  ## - a **custom scalar** with a `kdlDecodeValue(val, T): Result[T, string]` hook
  ##   in scope (the `{.kdlScalar.}` interchange contract) routes through that
  ##   hook — its `string` error is lifted into a `peTypeMismatch` `ParseError`;
  ## - a **built-in scalar** (`string`/`bool`/`int*`/`uint*`/`float*`/`enum`) maps
  ##   the matching `KdlValue` variant directly; a wrong value kind (a string
  ##   where an int is expected, etc.) is a clear `peTypeMismatch` error, and an
  ##   unknown enum wire form is `peTypeEnumInvalid`.
  ##
  ## **Scalar-only compile guard (rfc §4.6 / round-2):** instantiating `coerce`
  ## with an aggregate `T` (object / tuple / seq / array) that has **no**
  ## `kdlDecodeValue` hook is a hard `{.error.}` directing the caller to
  ## `decodeNode`/`decode`. Enums, distinct scalars, and custom `kdlScalar`
  ## object types (which carry a hook) are allowed.
  mixin kdlDecodeValue
  when compiles(kdlDecodeValue(val, T)):
    # Custom scalar — route through the user hook (object targets are fine here:
    # the hook IS the scalar contract). The hook owns kind-matching; we lift its
    # error string into a span-bearing ParseError, mirroring emitTypedDecode.
    let hookRes = kdlDecodeValue(val, T)
    if hookRes.isErr:
      return err[T, ParseError](initError(peTypeMismatch, Span(), hookRes.getErr))
    return ok[T, ParseError](hookRes.get)
  else:
    when T is (object | tuple | seq | array | ref | ptr):
      {.error: "coerce[T] is for scalars only; '" & $T & "' is an aggregate. " &
               "Use decodeNode[T](doc, node) for a DOM node, or decode[T](src) " &
               "for source text. (A custom scalar object needs a kdlDecodeValue " &
               "hook in scope.)".}
    elif T is (enum | string | bool | SomeFloat | SomeSignedInt | SomeUnsignedInt):
      # Built-in scalar — single source of truth in `builtinScalarFromValue`
      # (review #7): the kind-match predicate + message catalog + kvBigInt
      # handling (review #5) live there, shared with any future value-consumer.
      return builtinScalarFromValue[T](val)
    else:
      {.error: "coerce[T]: unsupported scalar type '" & $T & "'. Supported: " &
               "string/bool/int*/uint*/float*/enum, or a custom type with a " &
               "kdlDecodeValue hook.".}

proc decodeProp*[T](node: KdlNode, key: string):
    Result[T, ParseError] {.raises: [].} =
  ## Decode node's property `key` into a scalar `T` — the **node-value leg** of
  ## the typed bridge (rfc-consumer-api §4.6; review #10). Looks up the prop's
  ## `KdlValue` via `node.prop(key)` and routes it through `coerce[T]`, so this
  ## reaches `{.kdlScalar.}` custom types that the kind-fixed `propInt`/`propStr`
  ## family cannot. A missing prop is a `peTypeMissingRequired` error whose hint
  ## names the key and the node.
  let v = node.prop(key)
  if v.isNone:
    return err[T, ParseError](initError(
      peTypeMissingRequired, node.span,
      "no property '" & key & "' on node '" & node.name & "'"))
  coerce[T](v.get)

proc decodeArg*[T](node: KdlNode, i: int):
    Result[T, ParseError] {.raises: [].} =
  ## Decode node's `i`-th positional argument into a scalar `T` — the node-value
  ## leg's positional twin (rfc-consumer-api §4.6; review #10). Looks up the
  ## arg's `KdlValue` via `node.arg(i)` (properties interleaved among args are
  ## skipped) and routes it through `coerce[T]`, reaching `{.kdlScalar.}` types
  ## that the kind-fixed `argInt`/`argStr` family cannot. An out-of-range index
  ## is a `peTypeMissingRequired` error whose hint names the index and the node.
  let v = node.arg(i)
  if v.isNone:
    return err[T, ParseError](initError(
      peTypeMissingRequired, node.span,
      "no argument at index " & $i & " on node '" & node.name & "'"))
  coerce[T](v.get)
