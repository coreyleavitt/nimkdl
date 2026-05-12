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
import ./intern
import ./lexer  # ReservedBarewords (centralized v2 keyword denylist)

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

func encode*(doc: KdlDoc, mode = emPreserve): string =
  ## Render `doc` to KDL v2 text.
  ##
  ## `emPreserve` (default): byte-lossless for parsed docs that haven't
  ## been mutated. Returns `doc.sourceText` verbatim. Falls back to
  ## `emPretty` when the doc was built from scratch or has been edited.
  ##
  ## `emPretty` / `emCompact`: canonical output. `emPretty` is multi-
  ## line + indented; `emCompact` is single-line with `;` separators.
  case mode
  of emPreserve:
    if doc.sourceText.len > 0 and not doc.mutated:
      return doc.sourceText
    # Fallback: canonical pretty form.
    var parts: seq[string] = @[]
    for n in doc.nodes:
      parts.add(emitNode(n, doc.interner, emPretty, 0))
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
