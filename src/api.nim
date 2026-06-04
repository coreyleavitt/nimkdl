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

proc encode*[T](v: T): string =
  # TODO(H1): fold under {.raises:[].} once emitter chain is triaged
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
  while c.peek.kind != ceEof:
    let ck = c.pos
    var elem: Elem
    let r = kdlDecode(elem, c)
    if r.isErr:
      # Public boundary: enrich with line/col + sourcePath (rfc §4.4).
      errors.add(r.getErr.enriched(src, sourcePath))
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

proc embed*[T](src: static[string]): T {.raises: [].} =
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

proc reEmitDecodeNode*[T](node: KdlNode):
    Result[T, ParseError] =
  # TODO(H1): fold under {.raises:[].} once the emitter chain is triaged.
  # `encode(node)` transitively infers `raises:[Exception]` (the H1 boundary
  # flagged in rfc-consumer-api §4.5 / §7) — `func` gives noSideEffect, NOT
  # raises:[]. Left honestly unconstrained (no CatchableError/Exception escape
  # hatch) exactly as `encode[T]` is, until H1 brings the emit surface under
  # the invariant. The slice path of `decodeNode` (the §4.2 centerpiece) does
  # NOT touch this and is itself raises-clean; only this re-emit fallback (and
  # the decodeNode that may delegate to it) inherits the deferral.
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
    Result[T, ParseError] =
  # NOTE(H1): the slice path below is fully raises-clean (decodeInternal +
  # rebased + enriched are all {.raises:[].}). The `span.length == 0` branch
  # delegates to `reEmitDecodeNode`, whose `encode(node)` infers
  # raises:[Exception] — the H1 boundary (rfc §4.5). So this proc inherits the
  # deferral and stays honestly unconstrained until H1 folds the emit chain
  # under {.raises:[].}. No escape hatch — matching `encode[T]`.
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
  if span.length == 0:
    return reEmitDecodeNode[T](node)
  let slice = doc.sourceText[span.offset ..< span.offset + span.length]
  let r = decodeInternal[T](slice)
  if r.isErr:
    # Rebase FIRST (slice-local offset → absolute offset in doc.sourceText),
    # THEN enrich (compute line/col from the absolute offset). This order is
    # mandatory (§4.4): enriching before rebasing yields slice-local line/col.
    let absErr = r.getErr.rebased(span.offset)
    return err[T, ParseError](absErr.enriched(doc.sourceText, doc.sourcePath))
  r

proc decodeNode*[T](node: KdlNode):
    Result[T, ParseError] =
  # TODO(H1): same deferral as `reEmitDecodeNode` / `decodeNode(doc, node)`.
  # This overload is a thin call into `reEmitDecodeNode[T]`, whose `encode(node)`
  # transitively infers `raises:[Exception]` (the H1 boundary, rfc §4.5). Left
  # honestly unconstrained — no CatchableError/Exception escape hatch — until H1
  # folds the emit chain under {.raises:[].}.
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
    Result[T, ParseError] =
  # NOTE(H1): inherits the same raises deferral as `decodeNode(doc, node)` —
  # the found child may have `span.length == 0` (a hand-built parent's child),
  # in which case `decodeNode` delegates to the re-emit fallback whose
  # `encode(node)` infers raises:[Exception] (the H1 boundary, rfc §4.5). Left
  # honestly unconstrained — no escape hatch — until H1 folds the emit chain.
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
    return err[T, ParseError](initError(
      peTypeMissingRequired, parent.span,
      "no child named '" & childName & "' in node '" & parent.name & "'"))
  decodeNode[T](doc, kid)

proc decodeOr*[T](doc: KdlDoc, node: KdlNode, fallback: T): T =
  # NOTE(H1): inherits the `decodeNode(doc, node)` raises deferral (re-emit
  # fallback when node.span.length == 0). No escape hatch; folded under
  # {.raises:[].} at H1 with the rest of the decode surface.
  ## Decode `node` into `T`, returning `fallback` on ANY decode error
  ## (rfc-consumer-api §4.2, N3). Never surfaces a `ParseError` to the caller —
  ## the total-by-construction "value or default" leg of the bridge. Routes
  ## through `decodeNode[T](doc, node)` (true source spans for parsed nodes;
  ## re-emit fallback for hand-built ones), discarding the error on `isErr`.
  let r = decodeNode[T](doc, node)
  if r.isErr: fallback else: r.get
