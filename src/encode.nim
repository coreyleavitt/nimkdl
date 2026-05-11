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

type
  EncodeMode* = enum
    emPretty   ## indented multi-line; default
    emCompact  ## single line, `;` between sibling nodes

const
  PrettyIndent = "    "
  ReservedBarewords = [
    "true", "false", "null", "inf", "nan"
  ]

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

proc emitNode(n: KdlNode, interner: Interner,
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
    of emPretty:
      result.add(" {\n")
      for c in n.children:
        result.add(emitNode(c, interner, mode, indent + 1))
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

proc encode*(doc: KdlDoc, mode = emPretty): string =
  ## Render `doc` to canonical KDL v2 text.
  case mode
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
