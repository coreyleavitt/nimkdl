## encode — KdlDoc → text (canonical KDL v2 output).
##
## Two modes:
##
##   emPretty  (default) — multi-line, indented children blocks
##   emCompact           — single-line, `;` between sibling nodes
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

import std/strutils

import ./ast
import ./fnv
import ./intern
import ./lexer  # ReservedBarewords (centralized v2 keyword denylist)
import ./spans

type
  EncodeMode* = enum
    emPreserve ## byte-lossless: emit `doc.sourceText` verbatim when the
               ## doc was parsed and has not been mutated; falls back to
               ## canonical pretty otherwise. Default.
    emPretty   ## canonical: indented multi-line
    emCompact  ## canonical: single line, `;` between sibling nodes

const
  PrettyIndent = "    "

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
  if s in ReservedBarewords: return false
  for i, c in s:
    if not isBareIdentChar(c, first = (i == 0)):
      return false
  true

# ---------------------------------------------------------------------------
# String escaping
# ---------------------------------------------------------------------------

func escapeStringBody(s: string): string =
  ## Escape only what's necessary for a valid double-quoted KDL string.
  ## Round-trip stable: re-parsing the output yields back the same bytes.
  result = ""
  for c in s:
    case c
    of '"':  result.add("\\\"")
    of '\\': result.add("\\\\")
    of '\n': result.add("\\n")
    of '\t': result.add("\\t")
    of '\r': result.add("\\r")
    of '\b': result.add("\\b")
    of '\f': result.add("\\f")
    of '\0'..'\x07', '\x0B', '\x0E'..'\x1F', '\x7F':
      # Non-printable bytes get \u{XX}
      result.add("\\u{" & toHex(int(c), 2) & "}")
    else:
      result.add(c)

func quotedString(s: string): string {.inline.} =
  "\"" & escapeStringBody(s) & "\""

func emitIdent(s: string): string {.inline.} =
  if canEmitBare(s): s else: quotedString(s)

# ---------------------------------------------------------------------------
# Number emission
# ---------------------------------------------------------------------------

func emitFloat(f: float): string =
  ## Canonical float format. Specials go through v2 keywords; finite values
  ## use Nim's default repr (which rounds to short-but-stable text).
  if f == Inf: return "#inf"
  if f == NegInf: return "#-inf"
  if f != f: return "#nan"  # NaN
  # Force a fractional component so re-parsing classifies as float
  let s = $f
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
  let pad = (if mode == emPretty: PrettyIndent.repeat(indent) else: "")
  let annoPrefix =
    if n.typeAnnotation == InvalidInterned: ""
    else: "(" & emitIdent(interner.lookup(n.typeAnnotation)) & ")"
  var parts = @[annoPrefix & emitIdent(interner.lookup(n.name))]
  for e in n.entries:
    parts.add(emitEntry(e, interner))
  result = pad & parts.join(" ")
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

func hashEntry*(e: KdlEntry, interner: Interner): Hash128 =
  ## Canonical-content fingerprint of `e`. Parser stores this; encoder's
  ## surgical-splice path re-hashes at encode time to detect per-entry
  ## edits. The framing byte `0x1f` (US — unit separator) keeps adjacent
  ## entries' hashes from collision-aliasing when they're folded into
  ## a parent's hash.
  result = fnv128Init()
  fnv128Update(result, 0x1f'u8)
  fnv128Mix(result, emitEntry(e, interner))

func hashNodeContent*(n: KdlNode, interner: Interner): Hash128 =
  ## Canonical-content fingerprint of `n` (recursively over children).
  ## Same function called at parse time (to seed `n.parseHash`) and at
  ## encode time (to compare against `n.parseHash`). Equal hashes ⇒
  ## subtree unmodified ⇒ emit source bytes in `emPreserve`.
  result = fnv128Init()
  if n.typeAnnotation != InvalidInterned:
    fnv128Mix(result, "(" & interner.lookup(n.typeAnnotation) & ")")
  fnv128Mix(result, interner.lookup(n.name))
  for e in n.entries:
    # `\x1f` (US — unit separator) framing keeps adjacent entries from
    # collision-aliasing (e.g. `a=1 b` vs `a=1b` produce different bytes).
    fnv128Update(result, 0x1f'u8)
    fnv128Mix(result, emitEntry(e, interner))
  for c in n.children:
    fnv128Update(result, 0x1e'u8)  # RS — record separator
    fnv128Mix(result, hashNodeContent(c, interner))

func emitNamePart(n: KdlNode, interner: Interner): string =
  ## The "head" of a node — type annotation + name + entries — without
  ## the children block or trailing newline. Shared between canonical
  ## emit and the preserving emit's mismatched-subtree case.
  let annoPrefix =
    if n.typeAnnotation == InvalidInterned: ""
    else: "(" & emitIdent(interner.lookup(n.typeAnnotation)) & ")"
  var parts = @[annoPrefix & emitIdent(interner.lookup(n.name))]
  for e in n.entries:
    parts.add(emitEntry(e, interner))
  parts.join(" ")

func validSpanInto(span: Span, source: string): bool {.inline.} =
  source.len > 0 and span.start.offset >= 0 and
  span.finish.offset <= source.len and
  span.start.offset < span.finish.offset

func emitNodePreserve(n: KdlNode, doc: KdlDoc, indent: int): string =
  ## Preservation strategy:
  ##
  ## 1. If `n`'s hash matches its parse-time fingerprint, the whole
  ##    subtree is unmodified — emit source bytes verbatim.
  ##
  ## 2. If `n` is modified BUT the modification is in-place (entries
  ##    and children counts unchanged from parse), do **surgical
  ##    textual splicing**: start with `n`'s source bytes, replace
  ##    each dirty entry's span with its canonical re-emit, and
  ##    recurse for each dirty child subtree. Untouched bytes around
  ##    the edits — comments, alignment, trailing newlines, anything
  ##    — survive byte-for-byte.
  ##
  ## 3. If the entry / child count changed (insertion or removal),
  ##    fall back to canonical for THIS node only. Sibling top-level
  ##    nodes still preserve.
  ##
  ## 4. If `n` has no valid span (built from scratch via newNode),
  ##    canonical emit.
  let pad = PrettyIndent.repeat(indent)

  if not validSpanInto(n.span, doc.sourceText):
    result = pad & emitNamePart(n, doc.interner)
    if n.children.len > 0:
      result.add(" {\n")
      for c in n.children:
        result.add(emitNodePreserve(c, doc, indent + 1))
        result.add("\n")
      result.add(pad & "}")
    return result

  if hashNodeContent(n, doc.interner) == n.parseHash:
    return doc.sourceText[n.span.start.offset ..< n.span.finish.offset]

  # Subtree changed. Determine whether the change is in-place
  # (suitable for surgical splice) or structural (canonical fallback).
  let entriesShape = n.entries.len == int(n.parseEntryCount)
  let childrenShape = n.children.len == int(n.parseChildCount)

  if not (entriesShape and childrenShape):
    # Structural change — canonical for this node. (Other top-level
    # nodes still preserve via their own emitNodePreserve calls.)
    result = pad & emitNamePart(n, doc.interner)
    if n.children.len > 0:
      result.add(" {\n")
      for c in n.children:
        result.add(emitNodePreserve(c, doc, indent + 1))
        result.add("\n")
      result.add(pad & "}")
    return result

  # In-place edits only. Take source bytes, splice modified pieces.
  # Walk children + entries by DESCENDING source span so each splice
  # leaves earlier offsets unchanged. Children all live AFTER entries
  # in source order (entries are inline before `{`; children are
  # inside `{ ... }`), so children come first in the reverse walk.
  var output = doc.sourceText[n.span.start.offset ..< n.span.finish.offset]
  let base = n.span.start.offset
  var anySpliced = false

  for i in countdown(n.children.high, 0):
    let c = n.children[i]
    if not validSpanInto(c.span, doc.sourceText): continue
    let childOut = emitNodePreserve(c, doc, indent + 1)
    let childSource = doc.sourceText[c.span.start.offset ..< c.span.finish.offset]
    if childOut != childSource:
      let s = c.span.start.offset - base
      let e = c.span.finish.offset - base
      output = output[0 ..< s] & childOut & output[e ..< output.len]
      anySpliced = true

  for i in countdown(n.entries.high, 0):
    let entry = n.entries[i]
    if not validSpanInto(entry.span, doc.sourceText): continue
    if hashEntry(entry, doc.interner) == entry.parseHash: continue
    let s = entry.span.start.offset - base
    let e = entry.span.finish.offset - base
    output = output[0 ..< s] & emitEntry(entry, doc.interner) &
             output[e ..< output.len]
    anySpliced = true

  if not anySpliced:
    # Node-level hash mismatched but no per-element splice fired —
    # the change must be in the node's name or type annotation. We
    # don't store a separate localHash for that; fall back to
    # canonical for this node. (Siblings still preserve.)
    result = pad & emitNamePart(n, doc.interner)
    if n.children.len > 0:
      result.add(" {\n")
      for c in n.children:
        result.add(emitNodePreserve(c, doc, indent + 1))
        result.add("\n")
      result.add(pad & "}")
    return result

  output

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
    if doc.sourceText.len > 0 and not doc.mutated:
      return doc.sourceText
    # Doc-level splice: when sourceText is present and the top-level
    # node count hasn't changed, walk nodes in reverse and replace
    # each one's bytes with `emitNodePreserve` output. This preserves
    # inter-node trivia — header comments, blank lines between
    # siblings, the trailing newline of the file — for free.
    let topShape = int(doc.parseTopLevelCount) == doc.nodes.len
    if doc.sourceText.len > 0 and topShape:
      result = doc.sourceText
      for i in countdown(doc.nodes.high, 0):
        let n = doc.nodes[i]
        if not validSpanInto(n.span, doc.sourceText): continue
        let nodeOut = emitNodePreserve(n, doc, 0)
        let nodeSource = doc.sourceText[n.span.start.offset ..< n.span.finish.offset]
        if nodeOut != nodeSource:
          result = result[0 ..< n.span.start.offset] & nodeOut &
                   result[n.span.finish.offset ..< result.len]
      return result
    # Structural change at the top level OR no sourceText to splice
    # into. Fall back to per-node emit joined by newlines.
    var parts: seq[string] = @[]
    for n in doc.nodes:
      parts.add(emitNodePreserve(n, doc, 0))
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
