## encode — KdlDoc → text (canonical KDL v2 output).
##
## Three modes:
##
##   emPreserve (default) — byte-lossless for parsed, unmodified docs;
##                          surgical splice for mutated docs (preserves
##                          comments and exact whitespace where it can)
##   emPretty             — multi-line, indented children blocks
##   emCompact            — single-line, `;` between sibling nodes
##
## ## Canonical normalization
##
## - **Identifiers** are emitted bare when they match a safe ASCII subset
##   (`[A-Za-z_][A-Za-z0-9_-]*`) and aren't a v2 reserved-bareword; otherwise
##   they go through the regular string quoter.
## - **Strings** are double-quoted; only the bytes that *must* be escaped
##   are escaped (`"`, `\`, control chars). Tab/newline use `\t` / `\n`.
##   Non-printable chars use `\u{XXXX}`.
## - **Numbers** normalize to decimal (KDL canonical form is base-10 with
##   no underscores). Special floats (Inf, -Inf, NaN) use the v2 keyword
##   form (`#inf`, `#-inf`, `#nan`).
## - **Type annotations** are preserved from the AST. They emit as
##   `(name)value` for values and `(name)nodename` for nodes.
## - **Slashdash and comments are NOT emitted** — the canonical form has
##   no commentary. Builtin defaults that ship via `embed[T]` get their
##   docs from surrounding Nim comments, not from KDL comments.
##
## ## Round-trip stability
##
## `parse(encode(parse(x)))` is structurally equivalent (via `docEqual`)
## to `parse(x)` for any well-formed input. Byte-identical round-trip
## is *not* guaranteed — the encoder normalizes whitespace, number bases,
## and equivalent identifier forms.
##
## ## Implementation note: forward-walk preserve emit
##
## `emPreserve` uses a **forward-walk with monotonic cursor** at both
## the document and node levels (`encode` doc-block, `emitPreserveNode`).
## Reads come from immutable `doc.sourceText`; writes append to a fresh
## output buffer. There is no in-place splicing into a buffer whose
## offsets are simultaneously being mutated — that pattern (rounds 2-5
## of the historical code review) silently corrupts output because
## Nim's string slicing returns empty / full strings rather than
## crashing on out-of-range bounds. Each iteration of the walk
## bounds-checks the next item's span against the current cursor; any
## overlap / out-of-order span falls the whole walk back to canonical
## emit. Do not reintroduce `output = output[0..<s] & x & output[e..<output.len]`
## style splices anywhere in this file.

import std/[algorithm, strutils]

import ./ast
import ./fnv
import ./intern
import ./lexer  # ReservedBarewords (centralized v2 keyword denylist)
import ./spans

when defined(kdlHashStats):
  # Test-only instrumentation. Counts how many full node-content
  # fingerprints are computed across the lifetime of the process. Used
  # by `tests/test_preserve.nim` to assert the preserving encoder is
  # linear (one hash per node) rather than quadratic (one full subtree
  # hash per ancestor it sits under). Behind a `define` so production
  # builds carry no overhead.
  var kdlHashCallCount* {.threadvar.}: int

type
  EncodeMode* = enum
    emPreserve ## byte-lossless: emit `doc.sourceText` verbatim when the
               ## doc was parsed and has not been mutated; falls back to
               ## canonical pretty otherwise. Default.
    emPretty   ## canonical: indented multi-line
    emCompact  ## canonical: single line, `;` between sibling nodes

const
  PrettyIndent = "    "

  PrecomputedIndentLevels = 64
    ## Cover any indent depth the parser admits (`MaxParserDepth` is 256,
    ## but real KDL configs rarely nest past 8). 64 levels is comfortably
    ## above any practical doc while keeping the table at ~16 KB of
    ## `.rodata`. Beyond this the emitter falls back to `repeat`.

  MaxEncodeDepth* = 256
    ## Mirror of `MaxParserDepth`. Parsed docs are bounded by the
    ## parser's cap; programmatically-constructed ASTs can exceed it
    ## and stack-overflow the recursive emitters. Guarding at the same
    ## threshold means encode rejects exactly what decode would have.
    ## Overflow semantics live with the affected emitters (`emitNode`,
    ## `emitPreserveNode`, `kdlEncodeIntoImpl`).

  Indents = (proc(): array[PrecomputedIndentLevels, string] =
    for i in 0 ..< PrecomputedIndentLevels:
      result[i] = PrettyIndent.repeat(i))()
    ## Pre-computed indent strings for `emitNode` / `emitPreserveNode` so
    ## the hot path looks up `Indents[indent]` instead of allocating
    ## `PrettyIndent.repeat(indent)` per node.

func indentStr(depth: int): string {.inline.} =
  if depth >= 0 and depth < PrecomputedIndentLevels:
    Indents[depth]
  else:
    PrettyIndent.repeat(depth)

# ---------------------------------------------------------------------------
# Identifier emission
# ---------------------------------------------------------------------------

func isBareIdentChar(c: char, first: bool): bool {.inline.} =
  case c
  of 'a'..'z', 'A'..'Z', '_':
    true
  of '0'..'9', '-':
    not first
  else:
    false

func canEmitBare(s: string): bool =
  ## Conservative: alphanumeric + underscore + hyphen, starting with a
  ## non-digit, and not one of the v2 reserved barewords. Spec allows a
  ## broader set but this subset is always safe and matches what humans
  ## actually write.
  if s.len == 0: return false
  if isReservedBareword(s): return false
  for i, c in s:
    if not isBareIdentChar(c, first = (i == 0)):
      return false
  true

# ---------------------------------------------------------------------------
# String escaping
# ---------------------------------------------------------------------------

# Forward-declare appendEscapedBody so escapeStringBody can delegate to
# it — single source of truth for the escape rules. The actual
# implementation lives in the "Direct-buffer emit primitives" section
# below because it belongs with the other no-allocation appendX procs;
# this forward decl just hoists the symbol into scope here.
#
# Note: pragmas (`{.noSideEffect, inline.}`) must match between the
# forward decl and the definition — Nim enforces this.
func appendEscapedBody*(buf: var string, s: string) {.noSideEffect, inline.}

func escapeStringBody(s: string): string =
  ## Escape only what's necessary for a valid double-quoted KDL string.
  ## Round-trip stable: re-parsing the output yields back the same bytes.
  ## Allocating wrapper around `appendEscapedBody` for the AST-emit
  ## path; the direct-buffer path uses appendEscapedBody directly.
  result = ""
  appendEscapedBody(result, s)

func quotedString(s: string): string {.inline.} =
  "\"" & escapeStringBody(s) & "\""

func emitIdent(s: string): string {.inline.} =
  if canEmitBare(s): s else: quotedString(s)

# ---------------------------------------------------------------------------
# Direct-buffer emit primitives (cycle E — encode[T] fast path).
#
# These write KDL bytes straight into a caller-provided `var string` buffer.
# Mirrors the per-allocation `emitX` family above but skips the intermediate
# strings — the macro-emitted `kdlEncodeIntoImpl` per type chains these into
# a single pass per value.
# ---------------------------------------------------------------------------

func appendEscapedBody*(buf: var string, s: string) {.noSideEffect, inline.} =
  ## Single source of truth for KDL string escaping. The allocating
  ## `escapeStringBody` (above) delegates here, so both the AST emit
  ## path and the direct-buffer emit path go through the same rules.
  for ch in s:
    case ch
    of '\\':   buf.add('\\'); buf.add('\\')
    of '"':    buf.add('\\'); buf.add('"')
    of '\n':   buf.add('\\'); buf.add('n')
    of '\r':   buf.add('\\'); buf.add('r')
    of '\t':   buf.add('\\'); buf.add('t')
    of '\b':   buf.add('\\'); buf.add('b')
    of '\f':   buf.add('\\'); buf.add('f')
    of '\x00'..'\x07', '\x0B', '\x0E'..'\x1F', '\x7F':
      const Hex = "0123456789abcdef"
      buf.add('\\'); buf.add('u'); buf.add('{')
      # Always two hex digits — matches legacy emit's `escapeStringBody`
      # output. Single-digit form is also valid KDL but byte-equivalence
      # tests pin the two-digit shape.
      let v = uint8(ch)
      buf.add(Hex[int(v shr 4)])
      buf.add(Hex[int(v and 0xF)])
      buf.add('}')
    else:      buf.add(ch)

func appendIdent*(buf: var string, s: string) {.noSideEffect, inline.} =
  ## Bare if possible, otherwise quoted.
  if canEmitBare(s):
    buf.add(s)
  else:
    buf.add('"'); appendEscapedBody(buf, s); buf.add('"')

func appendStringValue*(buf: var string, s: string) {.noSideEffect, inline.} =
  ## Canonical form prefers a bare-ident form for string values.
  ## Same body as `appendIdent` above — kept separate because the names
  ## document intent at call sites (identifier vs string value). Any
  ## future escape-rule or bareword change must update both.
  if canEmitBare(s):
    buf.add(s)
  else:
    buf.add('"'); appendEscapedBody(buf, s); buf.add('"')

func appendInt*(buf: var string, i: int64) {.noSideEffect, inline.} =
  buf.add($i)

func appendFloat*(buf: var string, f: float) {.noSideEffect.} =
  ## Direct-buffer counterpart to `emitFloat`. Same special-value mapping
  ## (`Inf`/`NegInf`/`NaN` → `#inf`/`#-inf`/`#nan`).
  ## **Keep in sync with `emitFloat` further down.**
  ##
  ## Precision: 17 significant digits — the IEEE 754 minimum to
  ## guarantee `float ↔ string ↔ float` round-trip for ALL doubles.
  ## Nim's default `$float` uses a shorter form that loses a digit
  ## near `float.high` / `float.low` (proptest counterexample
  ## 2026-05-28). Don't shrink without verifying round-trip on the
  ## full corpus of float bit patterns.
  if f == Inf: buf.add("#inf"); return
  if f == NegInf: buf.add("#-inf"); return
  if f != f: buf.add("#nan"); return
  let s = formatBiggestFloat(f, ffDefault, 17)
  buf.add(s)
  if '.' notin s and 'e' notin s and 'E' notin s:
    buf.add(".0")

func appendBool*(buf: var string, b: bool) {.noSideEffect, inline.} =
  buf.add(if b: "#true" else: "#false")

func appendNull*(buf: var string) {.noSideEffect, inline.} =
  buf.add("#null")

func appendIndent*(buf: var string, depth: int) {.noSideEffect, inline.} =
  ## Pretty-mode indent. Reuses the precomputed `Indents` table.
  if depth >= 0 and depth < PrecomputedIndentLevels:
    buf.add(Indents[depth])
  else:
    buf.add(PrettyIndent.repeat(depth))

# Overload set used by the macro-emitted kdlEncodeIntoImpl. Lets the
# generated code dispatch on the Nim field type without a per-type
# `when` ladder.
func appendFieldValue*(buf: var string, s: string) {.noSideEffect, inline.} =
  appendStringValue(buf, s)
func appendFieldValue*(buf: var string, i: int) {.noSideEffect, inline.} =
  appendInt(buf, int64(i))
func appendFieldValue*(buf: var string, i: int64) {.noSideEffect, inline.} =
  appendInt(buf, i)
func appendFieldValue*[T: int8|int16|int32](buf: var string, i: T)
    {.noSideEffect, inline.} =
  appendInt(buf, int64(i))
func appendFieldValue*[T: uint8|uint16|uint32](buf: var string, i: T)
    {.noSideEffect, inline.} =
  ## Sub-int unsigned widths fit losslessly into int64. The kdl:
  ## block macro emits encode for any primitive field, so the
  ## overload set must cover what decode[T] does (which already
  ## accepts SomeUnsignedInt via kdlDecodeValue).
  appendInt(buf, int64(i))
# uint64 / uint overloads are defined after emitBigInt below — they need
# its definition for the bigint-promotion branch.
func appendFieldValue*(buf: var string, f: float) {.noSideEffect, inline.} =
  appendFloat(buf, f)
func appendFieldValue*(buf: var string, f: float32) {.noSideEffect, inline.} =
  appendFloat(buf, float(f))
func appendFieldValue*(buf: var string, b: bool) {.noSideEffect, inline.} =
  appendBool(buf, b)
func appendFieldValue*[T: enum](buf: var string, e: T) {.noSideEffect, inline.} =
  ## Enum fields encode as their string representation, matching the
  ## legacy KdlDoc path which interns the enum's `$` form.
  appendStringValue(buf, $e)

# ---------------------------------------------------------------------------
# Number emission
# ---------------------------------------------------------------------------

func emitFloat(f: float): string =
  ## Canonical float format. Specials go through v2 keywords; finite
  ## values use 17 significant digits (IEEE 754 round-trip minimum;
  ## see `appendFloat`'s precision note).
  ## **Keep in sync with `appendFloat` above** — the two are paired
  ## (AST-path vs direct-buffer-path); any new special-value or
  ## fraction-shape rule must land in both.
  if f == Inf: return "#inf"
  if f == NegInf: return "#-inf"
  if f != f: return "#nan"  # NaN
  let s = formatBiggestFloat(f, ffDefault, 17)
  # Force a fractional component so re-parsing classifies as float
  if '.' in s or 'e' in s or 'E' in s:
    s
  else:
    s & ".0"

func emitInt(i: int64): string =
  $i

func divMod128by10(hi, lo: var uint64): uint64 =
  ## In-place `(hi:lo) := (hi:lo) div 10`; returns the remainder 0..9.
  ## Schoolbook long division split into 32-bit chunks to keep each
  ## intermediate within uint64.
  let qHi = hi div 10
  let rHi = hi mod 10  # 0..9
  let loHi32 = lo shr 32
  let loLo32 = lo and 0xFFFFFFFF'u64
  let part1 = (rHi shl 32) or loHi32        # 36-bit number
  let qLoHi = part1 div 10
  let r1 = part1 mod 10
  let part2 = (r1 shl 32) or loLo32         # 36-bit number
  let qLoLo = part2 div 10
  let r2 = part2 mod 10
  hi = qHi
  lo = (qLoHi shl 32) or qLoLo
  r2

func emitBigInt(hi, lo: uint64, negative: bool): string =
  ## Render a 128-bit unsigned magnitude (plus sign) as decimal.
  if hi == 0 and lo == 0: return "0"
  var h = hi
  var l = lo
  var digits: seq[char] = @[]
  while not (h == 0 and l == 0):
    let r = divMod128by10(h, l)
    digits.add(char(ord('0') + int(r)))
  var output = ""
  if negative: output.add('-')
  for i in countdown(digits.high, 0):
    output.add(digits[i])
  output

# uint64 / uint appendFieldValue overloads live here (rather than next
# to the other sub-int unsigned overloads above) so they can call
# emitBigInt directly without a forward decl. They route to bigint
# promotion when value > int64.high — matches the AST path's
# `kdlEncodeValue[SomeUnsignedInt]` which produces kvBigInt.
func appendFieldValue*(buf: var string, i: uint64) {.noSideEffect, inline.} =
  ## uint64 above int64.high needs bigint promotion. Without this,
  ## large uint64 values silently emit as negative int64 decimals
  ## after the cast, corrupting output.
  if i <= uint64(int64.high):
    appendInt(buf, int64(i))
  else:
    buf.add(emitBigInt(0'u64, i, negative = false))
func appendFieldValue*(buf: var string, i: uint) {.noSideEffect, inline.} =
  ## `uint` is 64-bit on common targets — route through the uint64
  ## overload so the same bigint promotion fires.
  appendFieldValue(buf, uint64(i))

# ---------------------------------------------------------------------------
# Value emission
# ---------------------------------------------------------------------------

func emitStringValue(s: string): string {.inline.} =
  ## Canonical form prefers a bare-ident form for string values when
  ## possible — matches the kdl-org reference's canonical output and
  ## round-trips through the parser's bare-ident-as-value handling.
  if canEmitBare(s): s else: quotedString(s)

func emitValue(v: KdlValue, interner: Interner): string =
  let prefix =
    if v.typeAnnotation == InvalidInterned: ""
    else: "(" & emitIdent(interner.lookup(v.typeAnnotation)) & ")"
  case v.kind
  of kvString: prefix & emitStringValue(v.strVal)
  of kvInt:    prefix & emitInt(v.intVal)
  of kvBigInt: prefix & emitBigInt(v.bigHi, v.bigLo, v.bigNegative)
  of kvFloat:  prefix & emitFloat(v.floatVal)
  of kvBool:   prefix & (if v.boolVal: "#true" else: "#false")
  of kvNull:   prefix & "#null"

func emitEntry(e: KdlEntry, interner: Interner): string =
  case e.kind
  of keArgument:
    emitValue(e.argValue, interner)
  of keProperty:
    emitIdent(interner.lookup(e.propName)) & "=" & emitValue(e.propValue, interner)

# ---------------------------------------------------------------------------
# Node emission
# ---------------------------------------------------------------------------

func emitNode(n: KdlNode, interner: Interner,
              mode: EncodeMode, indent: int): string =
  ## **Raises `ValueError` when `indent > MaxEncodeDepth`.** The AST emit
  ## path returns `string`, not `Result`, so deep-AST overflow has no
  ## Err channel. Raising a `CatchableError` subtype (rather than an
  ## `AssertionDefect`) lets library consumers that build ASTs from
  ## untrusted sources wrap `encode(doc, …)` in `try/except ValueError`
  ## and recover; the typed direct path returns
  ## `Err(peParseDepthExceeded)` for the same condition.
  if indent > MaxEncodeDepth:
    raise newException(ValueError,
      "encode: node nesting exceeded MaxEncodeDepth (" & $MaxEncodeDepth &
      "). Parsed docs are bounded by the parser; this almost certainly " &
      "means a programmatically-constructed AST has a recursive child " &
      "structure beyond what KDL allows.")
  let pad = (if mode == emPretty: indentStr(indent) else: "")
  result.add(pad)
  if n.typeAnnotation != InvalidInterned:
    result.add('(')
    result.add(emitIdent(interner.lookup(n.typeAnnotation)))
    result.add(')')
  result.add(emitIdent(interner.lookup(n.name)))
  for e in n.entries:
    result.add(' ')
    result.add(emitEntry(e, interner))
  if n.children.len > 0:
    case mode
    of emPreserve, emPretty:
      result.add(" {\n")
      for c in n.children:
        result.add(emitNode(c, interner, emPretty, indent + 1))
        result.add("\n")
      result.add(pad & "}")
    of emCompact:
      result.add(" {")
      var first = true
      for c in n.children:
        if not first: result.add("; ")
        result.add(emitNode(c, interner, mode, 0))
        first = false
      result.add("}")

# ---------------------------------------------------------------------------
# Document emission
# ---------------------------------------------------------------------------

func feedValue(h: var Hash128, v: KdlValue, interner: Interner) =
  ## Zero-alloc fingerprint of a KdlValue. Hashes AST structure directly
  ## (kind discriminant + raw payload bytes) rather than rendering to a
  ## canonical string and hashing that. Two consequences:
  ##  • No heap allocation in the hot path.
  ##  • `emitEntry`'s output format can evolve (e.g. number-base or
  ##    escape-style tweaks) without invalidating cached parseHashes.
  ## Stability is intrinsic: both parse-time and encode-time hashing
  ## go through this proc.
  fnv128Update(h, 0x10'u8 + uint8(ord(v.kind)))  # kind discriminant
  if v.typeAnnotation != InvalidInterned:
    fnv128Update(h, 0x02'u8)                     # marker: typed
    interner.feedHash(v.typeAnnotation, h)
    fnv128Update(h, 0x03'u8)                     # marker: end-of-tag
  case v.kind
  of kvString:
    # Length-prefix so adjacent strings can't alias ("ab"+"c" vs "a"+"bc").
    let n = uint64(v.strVal.len)
    for i in 0 ..< 8:
      fnv128Update(h, uint8((n shr (i * 8)) and 0xff'u64))
    for c in v.strVal: fnv128Update(h, uint8(c))
  of kvInt:
    let u = cast[uint64](v.intVal)
    for i in 0 ..< 8: fnv128Update(h, uint8((u shr (i * 8)) and 0xff'u64))
  of kvBigInt:
    for i in 0 ..< 8: fnv128Update(h, uint8((v.bigHi shr (i * 8)) and 0xff'u64))
    for i in 0 ..< 8: fnv128Update(h, uint8((v.bigLo shr (i * 8)) and 0xff'u64))
    fnv128Update(h, if v.bigNegative: 1'u8 else: 0'u8)
  of kvFloat:
    # Hash the IEEE 754 bit pattern so distinct NaN payloads / ±0
    # produce distinct hashes (both correctly reflect the AST).
    let u = cast[uint64](v.floatVal)
    for i in 0 ..< 8: fnv128Update(h, uint8((u shr (i * 8)) and 0xff'u64))
  of kvBool:
    fnv128Update(h, if v.boolVal: 1'u8 else: 0'u8)
  of kvNull:
    discard

func hashEntry*(e: KdlEntry, interner: Interner): Hash128 =
  ## Canonical-content fingerprint of `e`. Parser stores this; encoder's
  ## surgical-splice path re-hashes at encode time to detect per-entry
  ## edits. Hashes structure directly — see `feedValue`.
  result = fnv128Init()
  fnv128Update(result, 0x1f'u8)               # US — entry framing
  case e.kind
  of keArgument:
    fnv128Update(result, 0x00'u8)             # marker: positional
    feedValue(result, e.argValue, interner)
  of keProperty:
    fnv128Update(result, 0x01'u8)             # marker: property
    interner.feedHash(e.propName, result)
    fnv128Update(result, 0x3d'u8)             # '=' — name/value separator
    feedValue(result, e.propValue, interner)

func hashNodeFromChildHashes*(n: KdlNode, interner: Interner,
                              childHashes: openArray[Hash128]): Hash128

func hashNodeContent*(n: KdlNode, interner: Interner): Hash128 =
  ## **Ground-truth** fingerprint of `n` — recursively recomputes every
  ## descendant's hash from current AST state, IGNORING any stored
  ## `parseHash`. Cost is O(N·d) over the subtree.
  ##
  ## Distinct contract from `hashNodeFromChildHashes`, which TRUSTS
  ## children's stored `parseHash` and is O(1) per node (the bottom-up
  ## form used by the parser and by the preserving encoder).
  ##
  ## Only intended caller is the `emPreserve` debug guard at
  ## `encode.nim:522` — that's where we explicitly cannot trust stored
  ## hashes because the whole point is to detect raw-field mutations
  ## that bypassed `markMutated`.
  ##
  ## On unmutated trees the two forms produce identical hashes by
  ## construction (this func IS `hashNodeFromChildHashes` recursively
  ## fed with ground-truth child hashes). Conformance byte-equivalence
  ## (243/338 fixtures) pins that invariant end-to-end.
  var childHashes = newSeq[Hash128](n.children.len)
  for i, c in n.children: childHashes[i] = hashNodeContent(c, interner)
  hashNodeFromChildHashes(n, interner, childHashes)

func emitNameHead(n: KdlNode, interner: Interner): string =
  ## Just `(tag)name` — the framing bytes whose source-side end is
  ## located by `KdlNode.headLen` (relative to `span.start`). Used by
  ## the preserving emit's framing-only-edit path: emit the new
  ## framing, then preserve `sourceText[span.start + headLen ..<
  ## span.finish]` verbatim.
  if n.typeAnnotation != InvalidInterned:
    result.add('(')
    result.add(emitIdent(interner.lookup(n.typeAnnotation)))
    result.add(')')
  result.add(emitIdent(interner.lookup(n.name)))

func emitNamePart(n: KdlNode, interner: Interner): string =
  ## `(tag)name` plus entries inline, joined by single spaces — the
  ## full node head without the children block or trailing newline.
  ## Shared between canonical emit and the preserving emit's
  ## shape-changed / span-malformed fallback paths.
  result = emitNameHead(n, interner)
  for e in n.entries:
    result.add(' ')
    result.add(emitEntry(e, interner))

func validSpanInto(span: Span, source: string): bool {.inline.} =
  source.len > 0 and span.start.offset >= 0 and
  span.finish.offset <= source.len and
  span.start.offset < span.finish.offset

func feedEntryInto(h: var Hash128, e: KdlEntry, interner: Interner) =
  ## Fold an entry's content into a running hash. Extracted so
  ## `hashNodeContent` and `emitPreserveNode` share one
  ## implementation; refactor of the inline block previously duplicated
  ## across both.
  fnv128Update(h, 0x1f'u8)                       # US — entry framing
  case e.kind
  of keArgument:
    fnv128Update(h, 0x00'u8)
    feedValue(h, e.argValue, interner)
  of keProperty:
    fnv128Update(h, 0x01'u8)
    interner.feedHash(e.propName, h)
    fnv128Update(h, 0x3d'u8)
    feedValue(h, e.propValue, interner)

func hashNodeFromChildHashes*(n: KdlNode, interner: Interner,
                              childHashes: openArray[Hash128]): Hash128 =
  ## Bottom-up sibling of `hashNodeContent`. Computes `n`'s fingerprint
  ## using already-computed `childHashes` instead of recursing into the
  ## children subtree. Lets the preserving encoder hash each node
  ## exactly once across an entire encode pass (linear, not quadratic).
  when defined(kdlHashStats):
    {.cast(noSideEffect).}:
      kdlHashCallCount.inc
  result = fnv128Init()
  if n.typeAnnotation != InvalidInterned:
    fnv128Update(result, 0x02'u8)
    interner.feedHash(n.typeAnnotation, result)
    fnv128Update(result, 0x03'u8)
  interner.feedHash(n.name, result)
  for e in n.entries:
    feedEntryInto(result, e, interner)
  for ch in childHashes:
    fnv128Update(result, 0x1e'u8)
    fnv128Mix(result, ch)

func emitPreserveNode(n: KdlNode, doc: KdlDoc, indent: int):
                      tuple[text: string, subtreeDirty: bool] =
  ## Preservation strategy — dirty-flag-based cleanness + forward-walk
  ## emit.
  ##
  ## Cleanness is propagated bottom-up via the `dirty` flag set by
  ## mutators: `subtreeDirty = n.dirty or any(child.subtreeDirty)`.
  ## O(1) per node — replaces the previous O(content-size) per-node
  ## hash computation. Tradeoff: raw field mutation (bypassing the
  ## builder API) is no longer detected per-node in release builds;
  ## the doc-level debug check in `encode()` remains the safety net.
  ##
  ## Emit is a forward walk: when the subtree is dirty but the node's
  ## entry/child *shape* is unchanged, build the output by walking
  ## `doc.sourceText[n.span.start ..< n.span.finish]` left-to-right with
  ## a monotonically-advancing `cursor`. For each entry/child in source
  ## order, append the trivia between `cursor` and the item's start,
  ## append the item's text (source bytes if clean, canonical if dirty),
  ## then advance `cursor`. Finish with the trailing bytes from the last
  ## item to the node's end.
  ##
  ## Reads come from immutable `doc.sourceText`; writes append to a
  ## fresh `output` buffer. No offset arithmetic against a mutating
  ## buffer — the splice anti-pattern that drove the round 2-5 bug
  ## spiral cannot be expressed in this code.
  ##
  ## Per-entry "dirty" detection: `not isParsedEntry(e)` — replaced
  ## entries (setProp/setArg construct a fresh KdlEntry; parseHash
  ## resets to zero) AND brand-new entries (added via builder API)
  ## both signal as dirty. Original parsed entries pass.
  ##
  ## Branches:
  ## 1. No valid span (built-from-scratch) → canonical.
  ## 2. `not subtreeDirty` → emit source bytes verbatim.
  ## 3. Shape change (entry/child count diverged) → tombstone walk
  ##    (delegated higher up in this function).
  ## 4. Framing-only edit (no item dirty, `headLen` populated) →
  ##    canonical head + preserved interior.
  ## 5. Dirty but shape preserved → forward-walk emit.
  ## 6. Forward walk hit out-of-range / out-of-order spans → canonical.
  if indent > MaxEncodeDepth:
    raise newException(ValueError,
      "encode(emPreserve): node nesting exceeded MaxEncodeDepth (" &
      $MaxEncodeDepth & ")")
  let pad = indentStr(indent)

  var childResults: seq[tuple[text: string, subtreeDirty: bool]]
  childResults.setLen(n.children.len)
  var anyChildDirty = false
  for i in 0 ..< n.children.len:
    childResults[i] = emitPreserveNode(n.children[i], doc, indent + 1)
    if childResults[i].subtreeDirty: anyChildDirty = true

  result.subtreeDirty = n.dirty or anyChildDirty

  template canonicalEmit() =
    result.text = pad & emitNamePart(n, doc.interner)
    if n.children.len > 0:
      result.text.add(" {\n")
      for cr in childResults:
        result.text.add(cr.text)
        result.text.add("\n")
      result.text.add(pad & "}")

  if not validSpanInto(n.span, doc.sourceText):
    canonicalEmit(); return

  if not result.subtreeDirty:
    result.text = doc.sourceText[n.span.start.offset ..< n.span.finish.offset]
    return

  let nodeStart = n.span.start.offset
  let nodeEnd = n.span.finish.offset
  let entriesShape = n.entries.len == int(n.parseEntryCount)
  let childrenShape = n.children.len == int(n.parseChildCount)

  if not (entriesShape and childrenShape):
    # Shape-change path. Walk originals (live + tombstoned) in source
    # order: live → emit (source bytes or canonical based on per-item
    # hash); tombstoned → advance cursor without emitting. New entries
    # canonical-append after the entries section; new children either
    # canonical-append inside the existing children block, or wrap a
    # fresh ` {…}` block if the source had no children. Same forward-
    # walk invariants as the shape-preserved path — out-of-order /
    # malformed spans fall back to canonicalEmit.
    type OrigItem = object
      span: Span
      liveIdx: int         ## index into n.entries / n.children; -1 if tombstoned
    var origEntries: seq[OrigItem]
    for i, e in n.entries:
      if isParsedEntry(e): origEntries.add(OrigItem(span: e.span, liveIdx: i))
    if n.mutState != nil:
      for e in n.mutState.removedEntries:
        if isParsedEntry(e): origEntries.add(OrigItem(span: e.span, liveIdx: -1))
    var origChildren: seq[OrigItem]
    for i, c in n.children:
      if isParsedNode(c): origChildren.add(OrigItem(span: c.span, liveIdx: i))
    if n.mutState != nil:
      for c in n.mutState.removedChildren:
        if isParsedNode(c): origChildren.add(OrigItem(span: c.span, liveIdx: -1))
    # Source-order sort (parsed seqs are typically already ordered, but
    # tombstones may be appended out of order).
    proc cmpByStart(a, b: OrigItem): int =
      cmp(a.span.start.offset, b.span.start.offset)
    origEntries.sort(cmpByStart)
    origChildren.sort(cmpByStart)
    # Collect new (builder-API-constructed) items.
    var newEntries: seq[KdlEntry]
    for e in n.entries:
      if not isParsedEntry(e): newEntries.add(e)
    var newChildIdxs: seq[int]
    for i, c in n.children:
      if not isParsedNode(c): newChildIdxs.add(i)
    # `headEnd = span.start + headLen` is the anchor — interior starts
    # right after the (tag)name framing. Zero `headLen` means the
    # parser didn't populate it (built-from-scratch node).
    let headEnd = nodeStart + int(n.headLen)
    if n.headLen == 0 or headEnd > nodeEnd:
      canonicalEmit(); return
    var sOut = pad & emitNameHead(n, doc.interner)
    var cursor = headEnd
    var shapeFellBack = false
    block shapeWalk:
      # ---- entries section ----
      for it in origEntries:
        if not validSpanInto(it.span, doc.sourceText):
          shapeFellBack = true; break shapeWalk
        let s = it.span.start.offset
        let e = it.span.finish.offset
        if s < cursor or e > nodeEnd or e < s:
          shapeFellBack = true; break shapeWalk
        if it.liveIdx >= 0:
          let live = n.entries[it.liveIdx]
          sOut.add(doc.sourceText[cursor ..< s])
          if isParsedEntry(live) and hashEntry(live, doc.interner) == live.parseHash:
            sOut.add(doc.sourceText[s ..< e])
          else:
            sOut.add(emitEntry(live, doc.interner))
        # Tombstoned → skip; cursor advance absorbs the deleted span,
        # including its leading trivia (the space before it).
        cursor = e
      for ne in newEntries:
        sOut.add(' ')
        sOut.add(emitEntry(ne, doc.interner))
      # ---- children section ----
      let hadOriginalChildren = origChildren.len > 0
      let addingChildren = newChildIdxs.len > 0
      if hadOriginalChildren:
        # Preserve original ` {\n` opener via trivia from cursor.
        for it in origChildren:
          if not validSpanInto(it.span, doc.sourceText):
            shapeFellBack = true; break shapeWalk
          let s = it.span.start.offset
          let e = it.span.finish.offset
          if s < cursor or e > nodeEnd or e < s:
            shapeFellBack = true; break shapeWalk
          if it.liveIdx >= 0:
            sOut.add(doc.sourceText[cursor ..< s])
            sOut.add(childResults[it.liveIdx].text)
          cursor = e
        # New children: inject after the last original child, BEFORE the
        # closing brace. Trailing source bytes after `cursor` include
        # ` }` (and any trailing newline).
        for idx in newChildIdxs:
          sOut.add('\n')
          sOut.add(emitNode(n.children[idx], doc.interner, emPretty,
                            indent + 1))
        sOut.add(doc.sourceText[cursor ..< nodeEnd])
      elif addingChildren:
        # No source ` {…}` block exists. Emit trailing entry-section
        # bytes (whitespace), then synthesize a fresh canonical block.
        # Caveat: original trailing trivia is replaced by ` {…}` plus a
        # synthetic newline at the end.
        sOut.add(" {\n")
        for idx in newChildIdxs:
          sOut.add(emitNode(n.children[idx], doc.interner, emPretty,
                            indent + 1))
          sOut.add('\n')
        sOut.add(pad & "}")
      else:
        # No original children + no new children: emit trailing bytes
        # from the entries section (typically a newline / end of node).
        sOut.add(doc.sourceText[cursor ..< nodeEnd])

    if shapeFellBack:
      canonicalEmit()
    else:
      result.text = sOut
    return

  # Forward-walk emit. Entries always precede children in KDL source
  # order (entries inline; children inside `{...}`), and within each
  # list the parser preserves source order — so two sequential loops
  # sharing one cursor cover the whole node span.
  var output = ""
  var cursor = nodeStart
  var fellBack = false
  # Track whether any entry/child diverges from its parseHash. If
  # nothing in the walk is dirty but the node-level hash still
  # mismatches, the divergence must be in `name` or `typeAnnotation`
  # (the framing bytes before the first entry / between sections that
  # the walk preserves verbatim from source). Those edits can't be
  # expressed by replacing an entry or child — fall back to canonical.
  var anyItemDirty = false

  block walk:
    for entry in n.entries:
      if not validSpanInto(entry.span, doc.sourceText):
        fellBack = true; break walk
      let s = entry.span.start.offset
      let e = entry.span.finish.offset
      if s < cursor or e > nodeEnd or e < s:
        fellBack = true; break walk
      output.add(doc.sourceText[cursor ..< s])
      # Per-entry cleanness uses the hash compare (cheap: just one
      # entry's content) so we catch raw field mutation through
      # `entries[i].argValue.strVal = ...`. The expensive bottom-up
      # *node* hashing is what dirty-flag caching skipped.
      if isParsedEntry(entry) and hashEntry(entry, doc.interner) == entry.parseHash:
        output.add(doc.sourceText[s ..< e])
      else:
        output.add(emitEntry(entry, doc.interner))
        anyItemDirty = true
      cursor = e
    for i in 0 ..< n.children.len:
      let c = n.children[i]
      if not validSpanInto(c.span, doc.sourceText):
        fellBack = true; break walk
      let s = c.span.start.offset
      let e = c.span.finish.offset
      if s < cursor or e > nodeEnd or e < s:
        fellBack = true; break walk
      output.add(doc.sourceText[cursor ..< s])
      output.add(childResults[i].text)
      if childResults[i].subtreeDirty:
        anyItemDirty = true
      cursor = e
    output.add(doc.sourceText[cursor ..< nodeEnd])

  if fellBack:
    canonicalEmit()
  elif not anyItemDirty:
    # subtreeDirty was true (n.dirty or some descendant dirty) but the
    # forward walk found every entry + child clean. The divergence
    # must be in this node's own `name` or `typeAnnotation` (set by
    # `setName` / `setTypeAnnotation`, which flip `n.dirty` directly).
    # Emit the new `(tag)name` canonically, then preserve
    # `sourceText[span.start + headLen ..< span.finish]` verbatim —
    # that's the original head-to-interior whitespace, entries with
    # original inter-entry spacing, children block layout, and
    # trailing bytes. Requires `headLen` populated by the parser
    # (zero for built-from-scratch nodes).
    let headEnd = nodeStart + int(n.headLen)
    if n.headLen > 0'u32 and headEnd <= nodeEnd:
      var out2 = pad & emitNameHead(n, doc.interner)
      out2.add(doc.sourceText[headEnd ..< nodeEnd])
      result.text = out2
    else:
      canonicalEmit()
  else:
    result.text = output

func encode*(doc: KdlDoc, mode = emPreserve): string =
  ## Render `doc` to KDL v2 text.
  ##
  ## `emPreserve` (default): byte-lossless for parsed docs that haven't
  ## been mutated. Returns `doc.sourceText` verbatim for fast-path
  ## unmodified docs; falls back to per-node freshness checking when
  ## `doc.mutated` is set. The freshness check uses an FNV-1a 128-bit
  ## hash recorded by the parser; subtree-level mismatches emit
  ## canonical, matches emit source bytes — so editing one deep entry
  ## still preserves sibling subtrees verbatim.
  ##
  ## `emPretty` / `emCompact`: canonical output. `emPretty` is multi-
  ## line + indented; `emCompact` is single-line with `;` separators.
  case mode
  of emPreserve:
    # emPreserve requires parseHash fields populated at parse time.
    # The default `parse(src)` skips that work (~18% perf win) so
    # consumers opting into preservation must parse with the flag.
    # Fail loud rather than silently emitting reformatted output.
    if doc.sourceText.len > 0 and not doc.preserveFormat:
      raise newException(AssertionDefect,
        "encode(doc, emPreserve) requires parse(src, preserveFormat = true). " &
        "The default parse() skips parseHash computation for ~18% perf — " &
        "opt in if you need byte-lossless round-trip.")
    if doc.sourceText.len > 0 and not doc.mutated:
      when not defined(release):
        # Catch raw-field mutation that bypassed the builder API (which
        # would otherwise call markMutated). Without this check, the
        # fast path would return stale source bytes silently. Every
        # node's current hash must still match its parse-time
        # fingerprint when `doc.mutated == false` — otherwise the
        # caller mutated through a path that didn't flip the flag.
        for n in doc.nodes:
          if hashNodeContent(n, doc.interner) != n.parseHash:
            raise newException(AssertionDefect,
              "encode(doc, emPreserve): doc.mutated is false but a " &
              "node's content has changed since parse. Did you assign " &
              "to a raw AST field (e.g. doc.nodes[i].entries[j] = ...)? " &
              "Call doc.markMutated() after raw edits, or use the " &
              "builder API (setProp / addArg / setArg / etc.) which " &
              "flips the flag for you.")
      return doc.sourceText
    # Doc-level tombstone-aware forward walk. Reads doc.sourceText
    # left-to-right with a monotonically-advancing cursor. Original
    # nodes — live (preserved + their own forward-walk-emit handles
    # interior) and tombstoned (skipped) — interleave in source order;
    # inter-node trivia (header comments, blank lines, the trailing
    # newline) emits verbatim from sourceText. New (builder-API)
    # top-level nodes canonical-append after the last original. Falls
    # back to scratch emit (parts.join) on malformed spans / overlap /
    # out-of-order.
    if doc.sourceText.len > 0:
      var nodeResults: seq[tuple[text: string, subtreeDirty: bool]]
      nodeResults.setLen(doc.nodes.len)
      for i in 0 ..< doc.nodes.len:
        nodeResults[i] = emitPreserveNode(doc.nodes[i], doc, 0)
      type OrigDocItem = object
        span: Span
        liveIdx: int     ## index into doc.nodes; -1 if tombstoned
      var origNodes: seq[OrigDocItem]
      for i, n in doc.nodes:
        if isParsedNode(n):
          origNodes.add(OrigDocItem(span: n.span, liveIdx: i))
      for n in doc.removedNodes:
        if isParsedNode(n):
          origNodes.add(OrigDocItem(span: n.span, liveIdx: -1))
      proc cmpStart(a, b: OrigDocItem): int =
        cmp(a.span.start.offset, b.span.start.offset)
      origNodes.sort(cmpStart)
      var newNodeIdxs: seq[int]
      for i, n in doc.nodes:
        if not isParsedNode(n): newNodeIdxs.add(i)
      let srcLen = doc.sourceText.len
      var output = ""
      var cursor = 0
      var fellBack = false
      block walkDoc:
        for it in origNodes:
          if not validSpanInto(it.span, doc.sourceText):
            fellBack = true; break walkDoc
          let s = it.span.start.offset
          let e = it.span.finish.offset
          if s < cursor or e > srcLen or e < s:
            fellBack = true; break walkDoc
          if it.liveIdx >= 0:
            output.add(doc.sourceText[cursor ..< s])
            output.add(nodeResults[it.liveIdx].text)
          # Tombstoned → advance cursor past the deleted node's bytes
          # without emit (including its leading inter-node trivia,
          # which belonged to the removed node's neighborhood).
          cursor = e
        # Append new top-level nodes canonical, separated by newline.
        for idx in newNodeIdxs:
          if output.len > 0 and not output.endsWith("\n"):
            output.add("\n")
          output.add(nodeResults[idx].text)
        # Trailing source bytes (file-final newline, trailing comments).
        output.add(doc.sourceText[cursor ..< srcLen])
      if not fellBack:
        return output
      # Malformed spans → fall through to scratch emit.
    # Scratch emit: no sourceText / malformed spans. Loses inter-node
    # trivia but produces a correct doc.
    var parts: seq[string] = @[]
    for n in doc.nodes:
      parts.add(emitPreserveNode(n, doc, 0).text)
    result = parts.join("\n")
    if result.len > 0:
      result.add("\n")
  of emPretty:
    var parts: seq[string] = @[]
    for n in doc.nodes:
      parts.add(emitNode(n, doc.interner, mode, 0))
    result = parts.join("\n")
    if result.len > 0:
      result.add("\n")
  of emCompact:
    var parts: seq[string] = @[]
    for n in doc.nodes:
      parts.add(emitNode(n, doc.interner, mode, 0))
    result = parts.join("; ")
