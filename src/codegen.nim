## codegen — type-driven KDL decoder macros.
##
## ## The headline move
##
## In every other config-language library, the schema lives in a separate
## file and a code generator produces types from it. In Nim, **the type IS
## the schema**. `parse[T]` reflects on `T` at compile time via `getImpl`
## and generates the KDL-node-to-field parser directly.
##
## ## Usage
##
## ```nim
## import kdl
##
## type
##   ActionKind* = enum
##     akInject = "inject"
##     akDeny   = "deny"
##
##   Action* {.kdlNode: "action".} = object
##     kind*:     ActionKind  {.kdlArg.}
##     template*: string      {.kdlAttr.}
##
##   Rule* {.kdlNode: "rule".} = object
##     id*:      string                {.kdlArg.}
##     enabled* {.kdlAttr, default: true.}: bool
##     action*:  Action                {.kdlChild.}
##
## deriveDecode(Action)
## deriveDecode(Rule)
##
## let rule = parse[Rule]("rule \"compaction\" {\n  action \"inject\"\n}")
## ```
##
## ## Pragmas
##
## Type-level:
##   - `{.kdlNode: "name".}`  — overrides the node name (default = type name lowercased)
##
## Field-level:
##   - `{.kdlArg.}`           — positional argument
##   - `{.kdlAttr.}`          — property (`key=value`)
##   - `{.kdlChild.}`         — child node (default for nested objects + seq[T])
##   - `{.kdlSkip.}`          — never decoded; uses Nim default value
##   - `{.kdlRename: "x".}`   — override the KDL name for this field
##   - `{.default: expr.}`    — fallback when the KDL document omits the field
##
## ## Why a separate `deriveDecode` call
##
## A pure `parse[T]` macro can't generate procs *in scope for the call site*
## without macro pragmas, which are hard to compose. `deriveDecode(T)` is
## the explicit hand-off: it emits a `kdlDecodeImpl` overload bound to T.
## `parse[T]` then dispatches by overload resolution. Cost: one extra line
## per type. Benefit: composable, no order-of-definition surprises, and
## the generated code is dumpable via `-d:dumpKdlGen`.

import std/[macros, strutils, tables]

import ./ast
import ./intern
import ./parser
import ./spans

# ---------------------------------------------------------------------------
# Pragmas (just marker templates — no behavior)
# ---------------------------------------------------------------------------

template kdlNode*(name: string) {.pragma.}
  ## Type-level: explicit KDL node name. Defaults to type-name lowercased.
template kdlArg*() {.pragma.}
  ## Field-level: serialize/parse as a positional argument.
template kdlAttr*() {.pragma.}
  ## Field-level: serialize/parse as a property (key=value).
template kdlChild*() {.pragma.}
  ## Field-level: serialize/parse as a child node (default for objects + seq).
template kdlSkip*() {.pragma.}
  ## Field-level: do not parse — keep Nim's default.
template kdlRename*(name: string) {.pragma.}
  ## Field-level: KDL name differs from Nim field name.

# Note: the `default` pragma is `std/macros.default` for object defaults
# in Nim 2.x — we read field defaults via getTypeImpl rather than a custom
# pragma.

# ---------------------------------------------------------------------------
# Primitive decoders
# ---------------------------------------------------------------------------
#
# `kdlDecodeValue` overloads for primitives. The macro-generated decoders
# delegate to these so we have a single source of truth on KDL-value →
# Nim-value mapping.

type
  DecodeErr* = object
    ## Lightweight error type returned by decoders. Promoted to a
    ## `Result` at the public `parse[T]` boundary.
    msg*: string
    span*: Span

func decodeErrAt*(msg: string, span: Span): DecodeErr {.inline.} =
  DecodeErr(msg: msg, span: span)

# Each primitive returns a (success, error) pair to keep call sites
# concise. Error message becomes the `hint` field on the eventual
# ParseError.

proc kdlDecodeValue*(target: var string, v: KdlValue, doc: var KdlDoc): bool =
  case v.kind
  of kvString:
    target = v.strVal; true
  else:
    false

proc kdlDecodeValue*(target: var int, v: KdlValue, doc: var KdlDoc): bool =
  case v.kind
  of kvInt:
    target = int(v.intVal); true
  else:
    false

when int.sizeof < int64.sizeof:
  # On 32-bit targets, int and int64 are distinct types — provide both.
  # On 64-bit (our default), int IS int64 so an extra overload is a
  # redefinition error.
  proc kdlDecodeValue*(target: var int64, v: KdlValue, doc: var KdlDoc): bool =
    case v.kind
    of kvInt: target = v.intVal; true
    else: false

proc kdlDecodeValue*(target: var float, v: KdlValue, doc: var KdlDoc): bool =
  ## `float` is aliased to `float64` in Nim, so this overload covers both.
  case v.kind
  of kvFloat:
    target = v.floatVal; true
  of kvInt:
    target = float(v.intVal); true  # ints decode into floats too
  else:
    false

proc kdlDecodeValue*(target: var bool, v: KdlValue, doc: var KdlDoc): bool =
  case v.kind
  of kvBool:
    target = v.boolVal; true
  else:
    false

proc decodeEnumFromString*[E: enum](target: var E, s: string): bool =
  ## Generic enum decoder: matches `s` against each enum member's stringified
  ## name (via `$`). Used by the generated decoders for `kdlArg` / `kdlAttr`
  ## fields of enum type.
  for member in E.low .. E.high:
    if $member == s:
      target = member
      return true
  return false

# ---------------------------------------------------------------------------
# Helpers used by generated decoders
# ---------------------------------------------------------------------------

proc findArg*(n: KdlNode, idx: int): KdlValue =
  ## The `idx`-th positional argument on `n`, or null if absent.
  var seen = 0
  for v in n.arguments:
    if seen == idx: return v
    inc seen
  return newNullValue()

proc hasArg*(n: KdlNode, idx: int): bool =
  var seen = 0
  for _ in n.arguments:
    if seen == idx: return true
    inc seen
  return false

proc findProp*(n: KdlNode, key: InternedStr): KdlValue =
  for (k, v) in n.properties:
    if k == key: return v
  return newNullValue()

proc hasProp*(n: KdlNode, key: InternedStr): bool =
  for (k, _) in n.properties:
    if k == key: return true
  return false

proc findChild*(n: KdlNode, name: InternedStr): KdlNode =
  for c in n.children:
    if c.name == name: return c
  return KdlNode(name: InvalidInterned)

proc hasChild*(n: KdlNode, name: InternedStr): bool =
  for c in n.children:
    if c.name == name: return true
  return false

proc childrenNamed*(n: KdlNode, name: InternedStr): seq[KdlNode] =
  for c in n.children:
    if c.name == name: result.add(c)

# ---------------------------------------------------------------------------
# Type introspection at compile time
# ---------------------------------------------------------------------------

type
  FieldKind = enum
    fkArg, fkAttr, fkChild, fkSkip

  FieldSpec = object
    nimName: string         ## Nim identifier
    kdlName: string         ## KDL name (kdlRename or lowercased nimName)
    kind: FieldKind
    typeNode: NimNode       ## the field's type AST
    defaultExpr: NimNode    ## `nil` if none
    argIndex: int           ## position among `fkArg` fields

proc kdlNodeName*(typ: typedesc): string =
  ## Runtime helper to read the type-level `kdlNode` pragma. Returns the
  ## type name lowercased if absent. Implemented at compile time via the
  ## sibling macro; see `kdlNodeNameOf` below.
  ##
  ## This stub exists so untyped contexts can refer to the symbol; the
  ## real value comes from compile-time resolution in `parse[T]`.
  ""  # never called; macros resolve at compile time

proc fieldKindFromPragmas(prag: NimNode): FieldKind =
  ## Walk a field's pragma list and return its FieldKind. Default is
  ## fkAttr for primitives, fkChild for nested objects; callers override
  ## this when no explicit pragma is present.
  for p in prag:
    let name =
      case p.kind
      of nnkIdent, nnkSym: $p
      of nnkExprColonExpr, nnkCall: $p[0]
      else: ""
    case name
    of "kdlArg":    return fkArg
    of "kdlAttr":   return fkAttr
    of "kdlChild":  return fkChild
    of "kdlSkip":   return fkSkip
    else: discard
  return fkAttr

proc kdlNameFromPragmas(prag: NimNode, fallback: string): string =
  ## Returns the `kdlRename` override, or `fallback` if absent.
  for p in prag:
    if p.kind in {nnkExprColonExpr, nnkCall} and p.len >= 2:
      if $p[0] == "kdlRename":
        let lit = p[1]
        if lit.kind == nnkStrLit: return lit.strVal
  fallback

proc typeNodeIsObject(t: NimNode): bool =
  ## Best-effort check: is this type a user object (rather than a
  ## primitive / seq / option / etc.)?
  if t.kind == nnkBracketExpr: return false  # seq[T], Option[T], …
  let s =
    if t.kind in {nnkIdent, nnkSym}: $t else: ""
  case s
  of "string", "int", "int64", "int32", "int8", "uint", "uint64",
     "uint32", "uint8", "float", "float64", "float32", "bool", "byte":
    false
  else:
    true

proc typeNodeIsSeq(t: NimNode): bool =
  t.kind == nnkBracketExpr and t.len >= 1 and
  (($t[0]) == "seq")

proc collectFields(typedef: NimNode): seq[FieldSpec] =
  ## Walk the `nnkObjectTy` of a type definition and produce a FieldSpec
  ## per field. Caller is responsible for passing the actual `nnkRecList`
  ## node (i.e. `typeImpl[2][2]` for a typical typedef).
  expectKind(typedef, nnkRecList)
  var argCursor = 0
  for ident in typedef:
    if ident.kind != nnkIdentDefs: continue
    # Identifier + type + optional default value. Field list may bundle
    # several fields with the same type — handle each separately.
    let typeNode = ident[ident.len - 2]
    let defaultExpr = ident[ident.len - 1]
    for i in 0 ..< ident.len - 2:
      let nameNode = ident[i]
      var prag: NimNode = newNimNode(nnkPragma)
      var nimName: string
      case nameNode.kind
      of nnkIdent, nnkSym:
        nimName = $nameNode
      of nnkPostfix:
        nimName = $nameNode[1]
      of nnkPragmaExpr:
        let inner = nameNode[0]
        nimName =
          case inner.kind
          of nnkIdent, nnkSym: $inner
          of nnkPostfix: $inner[1]
          else: ""
        prag = nameNode[1]
      else:
        nimName = ""
      let kind =
        if prag.len == 0:
          (if typeNodeIsObject(typeNode) or typeNodeIsSeq(typeNode):
             fkChild
           else: fkAttr)
        else: fieldKindFromPragmas(prag)
      let kdlName = kdlNameFromPragmas(prag, nimName.toLowerAscii)
      var spec = FieldSpec(nimName: nimName, kdlName: kdlName,
                           kind: kind, typeNode: typeNode,
                           defaultExpr: defaultExpr)
      if kind == fkArg:
        spec.argIndex = argCursor
        inc argCursor
      result.add(spec)

proc extractNodeName(typeSym: NimNode): string =
  ## Read the `{.kdlNode: "name".}` pragma from `typeSym`'s typedef, or
  ## fall back to the type name lowercased.
  let impl = typeSym.getImpl
  if impl.kind != nnkTypeDef:
    return ($typeSym).toLowerAscii
  let nameNode = impl[0]
  case nameNode.kind
  of nnkPragmaExpr:
    let prag = nameNode[1]
    for p in prag:
      if p.kind in {nnkExprColonExpr, nnkCall} and p.len >= 2:
        if $p[0] == "kdlNode":
          let lit = p[1]
          if lit.kind == nnkStrLit: return lit.strVal
    return ($nameNode[0]).toLowerAscii
  of nnkIdent, nnkSym:
    return ($nameNode).toLowerAscii
  of nnkPostfix:
    return ($nameNode[1]).toLowerAscii
  else:
    return ($typeSym).toLowerAscii

# ---------------------------------------------------------------------------
# deriveDecode: the macro that emits `kdlDecodeImpl(target: var T, node, doc)`
# ---------------------------------------------------------------------------

macro deriveDecode*(typ: typedesc): untyped =
  ## Emit a `kdlDecodeImpl` overload for `typ`. The procedure walks a
  ## KdlNode and populates a `var typ` from its entries and children.
  ##
  ## Generated shape (illustrative):
  ##
  ## ```nim
  ## proc kdlDecodeImpl(target: var Rule, node: KdlNode, doc: KdlDoc): seq[DecodeErr] =
  ##   # arg fields by position
  ##   if hasArg(node, 0):
  ##     if not kdlDecodeValue(target.id, findArg(node, 0), doc):
  ##       result.add(decodeErrAt("type mismatch on arg 0 of 'rule'", ...))
  ##   # attr fields by key
  ##   let _enabledKey = doc.interner.lookup… etc.
  ##   # … children …
  ## ```
  ##
  ## The generated code is dumpable via `-d:dumpKdlGen` (prints AST after
  ## construction).

  let typSym =
    if typ.kind == nnkBracketExpr: typ[1]
    else: typ
  let typeImpl = typSym.getImpl
  if typeImpl.kind != nnkTypeDef:
    error("deriveDecode: argument is not a type definition", typ)
  let body = typeImpl[2]
  if body.kind != nnkObjectTy:
    error("deriveDecode: only object types are supported (v0); got " &
          $body.kind, typ)
  let recList = body[2]
  let fields = collectFields(recList)

  # Build the proc body
  let nodeIdent = ident("node")
  let docIdent  = ident("doc")
  let tgtIdent  = ident("target")
  let resIdent  = ident("result")
  var stmts = newStmtList()

  for f in fields:
    let nimField = ident(f.nimName)
    let fieldAccess = newDotExpr(tgtIdent, nimField)
    let kdlNameStr = newLit(f.kdlName)

    case f.kind
    of fkSkip:
      discard
    of fkArg:
      let idxLit = newLit(f.argIndex)
      let hasArgCheck = quote do:
        `nodeIdent`.hasArg(`idxLit`)
      let decodeCall = quote do:
        kdlDecodeValue(`fieldAccess`,
                       `nodeIdent`.findArg(`idxLit`),
                       `docIdent`)
      let mismatchMsg = newLit(
        "type mismatch on positional arg " & $f.argIndex)
      let span = quote do: `nodeIdent`.span
      stmts.add quote do:
        if `hasArgCheck`:
          if not (`decodeCall`):
            `resIdent`.add(decodeErrAt(`mismatchMsg`, `span`))
        else:
          # missing required arg — fall back to default if any
          discard
    of fkAttr:
      let keyIdent = genSym(nskLet, "kdlKey")
      let decodeCall = quote do:
        kdlDecodeValue(`fieldAccess`,
                       `nodeIdent`.findProp(`keyIdent`),
                       `docIdent`)
      let mismatchMsg = newLit("type mismatch on property '" & f.kdlName & "'")
      let span = quote do: `nodeIdent`.span
      stmts.add quote do:
        let `keyIdent` = `docIdent`.interner.lookup(`kdlNameStr`)
      # We can't `intern` against a `KdlDoc` we got by `let`. Adapt:
      stmts[^1] = quote do:
        let `keyIdent` = `docIdent`.interner.lookupOrIntern(`kdlNameStr`)
      stmts.add quote do:
        if `nodeIdent`.hasProp(`keyIdent`):
          if not (`decodeCall`):
            `resIdent`.add(decodeErrAt(`mismatchMsg`, `span`))
    of fkChild:
      if typeNodeIsSeq(f.typeNode):
        let elemType = f.typeNode[1]
        let nameIdent = genSym(nskLet, "kdlChildName")
        stmts.add quote do:
          let `nameIdent` = `docIdent`.interner.lookupOrIntern(`kdlNameStr`)
        let elemSym = genSym(nskVar, "elem")
        let childSym = genSym(nskForVar, "child")
        let recurseErrs = quote do:
          kdlDecodeImpl(`elemSym`, `childSym`, `docIdent`)
        stmts.add quote do:
          for `childSym` in `nodeIdent`.childrenNamed(`nameIdent`):
            var `elemSym`: `elemType`
            let errs = `recurseErrs`
            for e in errs: `resIdent`.add(e)
            `fieldAccess`.add(`elemSym`)
      else:
        let nameIdent = genSym(nskLet, "kdlChildName")
        let recurseErrs = quote do:
          kdlDecodeImpl(`fieldAccess`,
                        `nodeIdent`.findChild(`nameIdent`),
                        `docIdent`)
        stmts.add quote do:
          let `nameIdent` = `docIdent`.interner.lookupOrIntern(`kdlNameStr`)
        stmts.add quote do:
          if `nodeIdent`.hasChild(`nameIdent`):
            let errs = `recurseErrs`
            for e in errs: `resIdent`.add(e)

  # Initialise defaults for fields that have explicit defaults declared
  for f in fields:
    if f.defaultExpr.kind != nnkEmpty:
      let nimField = ident(f.nimName)
      let dExpr = f.defaultExpr
      stmts.insert(0, quote do:
        `tgtIdent`.`nimField` = `dExpr`)

  let nodeNameLit = newLit(extractNodeName(typSym))
  let typDescSym = ident("T_kdlDecoded")  # uniquely-named typedesc helper
  let nodeNameProc = quote do:
    proc kdlNodeNameImpl*(typ: typedesc[`typ`]): string {.inline.} =
      `nodeNameLit`

  let decodeProc = quote do:
    proc kdlDecodeImpl*(`tgtIdent`: var `typ`;
                       `nodeIdent`: KdlNode;
                       `docIdent`: var KdlDoc): seq[DecodeErr] =
      `stmts`

  result = newStmtList(nodeNameProc, decodeProc)
  when defined(dumpKdlGen):
    echo "=== kdlDecodeImpl + kdlNodeNameImpl for ", repr(typ), " ==="
    echo result.repr
    echo "==="

# ---------------------------------------------------------------------------
# Convenience: lookupOrIntern (Interner doesn't have it)
# ---------------------------------------------------------------------------

proc lookupOrIntern*(interner: var Interner, s: string): InternedStr {.inline.} =
  ## Find or insert. Different name from `intern` to avoid widening the
  ## intern API; the conformance harness + decoders just want a handle.
  interner.intern(s)

# ---------------------------------------------------------------------------
# parse[T]
# ---------------------------------------------------------------------------

proc kdlNodeNameImpl*(typ: typedesc): string =
  ## Placeholder — `deriveDecode(T)` emits a typedesc[T] overload that
  ## returns the actual node name (per `{.kdlNode.}` pragma or
  ## type-name-lowercased fallback). This base version exists only so
  ## generic `parse[T]` typechecks when called on a type without a
  ## decoder yet — it'll fail the runtime lookup with an empty name,
  ## but the static phase compiles cleanly.
  ""

proc parse*[T](source: string,
               sourcePath: string = "<input>"): Result[T, ParseError] =
  ## Parse `source` as a KDL document and decode into `T`.
  ##
  ## - If `T = seq[U]`, decodes every top-level node named per U's
  ##   `kdlNode` pragma.
  ## - Otherwise, finds the single top-level node named per T's
  ##   `kdlNode` pragma and decodes it.
  ##
  ## Requires `deriveDecode(T)` (or `deriveDecode(U)` if T=seq[U]) to have
  ## been instantiated previously to provide the `kdlDecodeImpl` and
  ## `kdlNodeNameImpl` overloads.
  # `mixin` so the per-type overloads emitted by `deriveDecode` in the
  # caller's scope are resolved at instantiation time, not at the point
  # this generic proc is defined.
  mixin kdlDecodeImpl, kdlNodeNameImpl
  var parsed = parser.parse(source, sourcePath)
  if parsed.isErr:
    return err[T, ParseError](parsed.getErr)
  var doc = parsed.get
  when T is seq:
    type Elem = typeof(default(T)[0])
    let wantName = kdlNodeNameImpl(typeof(Elem))
    let nameKey = doc.interner.lookupOrIntern(wantName)
    var elems: T = @[]
    var errs: seq[DecodeErr] = @[]
    for i in 0 ..< doc.nodes.len:
      if doc.nodes[i].name == nameKey:
        var elem: Elem
        let perErrs = kdlDecodeImpl(elem, doc.nodes[i], doc)
        for e in perErrs: errs.add(e)
        elems.add(elem)
    if errs.len > 0:
      err[T, ParseError](initError(peTypeMismatch, errs[0].span, errs[0].msg))
    else:
      ok[T, ParseError](elems)
  else:
    let wantName = kdlNodeNameImpl(typeof(T))
    let nameKey = doc.interner.lookupOrIntern(wantName)
    var outValue: T
    var found = false
    var errs: seq[DecodeErr] = @[]
    for i in 0 ..< doc.nodes.len:
      if doc.nodes[i].name == nameKey:
        let perErrs = kdlDecodeImpl(outValue, doc.nodes[i], doc)
        for e in perErrs: errs.add(e)
        found = true
        break
    if not found:
      err[T, ParseError](initError(peTypeMissingRequired,
        pointSpan(StartPosition),
        "expected node '" & wantName & "' at top level"))
    elif errs.len > 0:
      err[T, ParseError](initError(peTypeMismatch, errs[0].span, errs[0].msg))
    else:
      ok[T, ParseError](outValue)
