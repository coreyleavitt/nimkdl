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

# Decoders return `Result[void, ParseError]` and short-circuit on the
# first failure (review-round-1 un-hedge: an accumulator that the public
# API never surfaced was the wrong abstraction). If we ever want a
# collect-all-errors mode (LSP / batch lint), it lives as a separate
# `decodeAll[T]` proc that opts back into accumulation — keeps the
# default decode path applicative-style.

func mismatchErrAt*(msg: string, span: Span): ParseError {.inline.} =
  initError(peTypeMismatch, span, msg)

func missingErrAt*(msg: string, span: Span): ParseError {.inline.} =
  initError(peTypeMissingRequired, span, msg)

func enumMismatchErrAt*(msg: string, span: Span): ParseError {.inline.} =
  ## Routed by the codegen when the failing field has an enum type.
  ## Lets a caller distinguish "value didn't match any enum member"
  ## from "value had the wrong primitive type."
  initError(peTypeEnumInvalid, span, msg)

func discriminatorErrAt*(msg: string, span: Span): ParseError {.inline.} =
  ## Routed by the codegen when the failing field is a variant's
  ## discriminator. The structural shape of `target` is now wrong;
  ## callers may want to retry, fall back, or surface specifically
  ## "we couldn't tell which variant this was."
  initError(peTypeDiscriminatorBad, span, msg)

# Each primitive returns a (success, error) pair to keep call sites
# concise. Error message becomes the `hint` field on the eventual
# ParseError.

proc kdlDecodeValue*(target: var string, v: KdlValue, doc: var KdlDoc): bool =
  case v.kind
  of kvString:
    target = v.strVal; true
  else:
    false

proc kdlDecodeValue*[T: SomeSignedInt](target: var T, v: KdlValue,
                                       doc: var KdlDoc): bool =
  ## Covers int, int8, int16, int32, int64. Range-checks against the
  ## target type so a KDL value that fits int64 but overflows int8
  ## surfaces as a type mismatch.
  case v.kind
  of kvInt:
    if v.intVal < int64(T.low) or v.intVal > int64(T.high): return false
    target = T(v.intVal); true
  else:
    false

proc kdlDecodeValue*[T: SomeUnsignedInt](target: var T, v: KdlValue,
                                         doc: var KdlDoc): bool =
  ## Covers uint, uint8, uint16, uint32, uint64. Range-checks against
  ## the target's high bound; negative KDL ints fail decoding.
  ##
  ## **`uint64` quirk**: `KdlValue.intVal` is `int64`, so values in
  ## `int64.high + 1 .. uint64.high` cannot reach this proc — the lexer
  ## rejects them with `peLexInvalidNumber`. The `T.sizeof < uint64.sizeof`
  ## branch is therefore guarded only for sub-`int64` widths; full 64-bit
  ## unsigned support waits for the `kvBigInt` variant (ast.nim docs the
  ## same limitation).
  case v.kind
  of kvInt:
    if v.intVal < 0: return false
    when T.sizeof < uint64.sizeof:
      if uint64(v.intVal) > uint64(T.high): return false
    target = T(v.intVal); true
  else:
    false

proc kdlDecodeValue*[T: SomeFloat](target: var T, v: KdlValue,
                                   doc: var KdlDoc): bool =
  ## Covers float, float32, float64. KDL ints decode into floats too
  ## (lossy past 2^53 for float64 / 2^24 for float32 — caller's
  ## responsibility if precision matters).
  case v.kind
  of kvFloat:
    target = T(v.floatVal); true
  of kvInt:
    target = T(v.intVal); true
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
  ## name (via `$`). Used by the generic `kdlDecodeValue[T: enum]` overload
  ## below; respects Nim 2.x's stringified-value syntax
  ## (`akInject = "inject"` => `$akInject == "inject"`).
  for member in E.low .. E.high:
    if $member == s:
      target = member
      return true
  return false

proc kdlDecodeValue*[E: enum](target: var E, v: KdlValue, doc: var KdlDoc): bool =
  ## Enum fields decode from KDL string values. Variant discriminators
  ## use this same path — their `.kind` field has an enum type and KDL
  ## supplies the discriminator via a positional arg or property.
  case v.kind
  of kvString:
    decodeEnumFromString(target, v.strVal)
  else:
    false

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
    typeIsEnum: bool        ## true ⇒ route decode failures to
                            ## peTypeEnumInvalid rather than the
                            ## generic peTypeMismatch; lets callers
                            ## branch on the failure mode
    isDiscriminator: bool   ## true for the variant discriminator
                            ## field ⇒ peTypeDiscriminatorBad instead
                            ## of peTypeEnumInvalid (discriminator
                            ## failure is more severe — the variant
                            ## is fundamentally the wrong shape)

proc fieldKindFromPragmas(prag: NimNode): FieldKind =
  ## Walk a field's pragma list and return its FieldKind from explicit
  ## `{.kdlArg.}` / `{.kdlAttr.}` / `{.kdlChild.}` / `{.kdlSkip.}` pragmas.
  ## When no pragma is present, returns `fkAttr` as a placeholder; the
  ## caller (`reflectField`) then promotes that to `fkChild` for nested
  ## object / seq fields based on the field's type.
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

proc typeNodeIsSeq(t: NimNode): bool =
  ## True if `t` is `seq[T]` for some T. Detected at the syntactic level
  ## because `seq` is the only generic we special-case for fkChild default.
  t.kind == nnkBracketExpr and t.len >= 1 and (($t[0]) == "seq")

proc typeNodeIsEnum(t: NimNode): bool =
  ## True if `t` resolves to an `nnkEnumTy`. Routes decode failures
  ## to `peTypeEnumInvalid` (and discriminator failures to
  ## `peTypeDiscriminatorBad`) so callers can branch on the specific
  ## failure mode.
  if typeNodeIsSeq(t): return false
  let impl =
    try: t.getTypeImpl
    except CatchableError: return false
  case impl.kind
  of nnkEnumTy: true
  of nnkDistinctTy: impl[0].kind == nnkEnumTy
  else: false

proc typeNodeIsObject(t: NimNode): bool =
  ## Resolve the type and inspect its actual `nnkObjectTy` / primitive /
  ## generic shape — replacing the string-name allowlist that broke for
  ## Natural, uint16, type aliases, and any primitive Nim adds later.
  ##
  ## Anything that resolves to an object body is treated as a child node;
  ## anything that resolves to a primitive numeric / string / bool / char
  ## is treated as an inline value (fkAttr default).
  if typeNodeIsSeq(t): return false  # seq[T] gets fkChild via its own path
  # `getTypeImpl(t)` requires `t` to be a typed-context node. In the macro
  # we receive `t` from `nnkIdentDefs[len-2]` which IS typed.
  let impl =
    try: t.getTypeImpl
    except CatchableError: return false
  case impl.kind
  of nnkObjectTy:
    true
  of nnkRefTy, nnkPtrTy:
    # ref / ptr to an object — treat as a child for now (decoding refs
    # is not yet supported by deriveDecode; the user will get an
    # error from the generated code if they try).
    impl[0].kind == nnkObjectTy
  of nnkDistinctTy:
    # distinct T — peel one layer; if the base is an object treat as
    # object, otherwise treat as primitive.
    impl[0].kind == nnkObjectTy
  of nnkBracketExpr, nnkTupleTy, nnkTupleConstr, nnkEnumTy:
    false  # generics / tuples / enums decode as values, not children
  of nnkSym:
    # `nnkSym` means the implementation is itself another symbol — Nim
    # builtins like `string`, `int`, `bool` land here. Definitely
    # not an object.
    false
  else:
    false

proc parseIdentDefs(identDefs: NimNode, argCursor: var int):
    seq[FieldSpec] =
  ## Walk one `nnkIdentDefs` (a single declaration line like `a, b: int = 0`)
  ## and emit a FieldSpec per name. Mutates `argCursor` for each fkArg
  ## field encountered.
  expectKind(identDefs, nnkIdentDefs)
  let typeNode = identDefs[identDefs.len - 2]
  let defaultExpr = identDefs[identDefs.len - 1]
  for i in 0 ..< identDefs.len - 2:
    let nameNode = identDefs[i]
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
                         defaultExpr: defaultExpr,
                         typeIsEnum: typeNodeIsEnum(typeNode))
    if kind == fkArg:
      spec.argIndex = argCursor
      inc argCursor
    result.add(spec)

type
  VariantBranch* = object
    discValue*: NimNode        ## the enum-member identifier (e.g. `akInject`)
    fields*: seq[FieldSpec]    ## fields under this branch

  VariantSpec* = object
    disc*: FieldSpec           ## the discriminator field
    branches*: seq[VariantBranch]

  TypeShape* = object
    shared*: seq[FieldSpec]    ## fields appearing before any case block
    hasVariant*: bool
    variant*: VariantSpec

proc collectShape*(recList: NimNode): TypeShape =
  ## Walk the `nnkRecList` of a type's `nnkObjectTy` and split into
  ## (shared regular fields, optional variant spec). Detects `nnkRecCase`
  ## as the trigger for variant decoding.
  ##
  ## v0.1 supports a single case block per type, single-value `of K:`
  ## branches only. Multi-value `of K1, K2:` and `else:` branches
  ## produce a macro-expansion error so the user gets a clear message
  ## rather than wrong codegen.
  expectKind(recList, nnkRecList)
  var argCursor = 0
  for child in recList:
    case child.kind
    of nnkIdentDefs:
      if result.hasVariant:
        error("deriveDecode: fields after a case block aren't supported " &
              "(v0.1); put all non-variant fields before the case", child)
      result.shared.add(parseIdentDefs(child, argCursor))
    of nnkRecCase:
      if result.hasVariant:
        error("deriveDecode: multiple case blocks per type aren't supported " &
              "(v0.1); use one discriminator field", child)
      result.hasVariant = true
      # First child is the discriminator nnkIdentDefs.
      let discDefs = child[0]
      let discFields = parseIdentDefs(discDefs, argCursor)
      doAssert discFields.len == 1,
        "discriminator must be a single field"
      var discSpec = discFields[0]
      discSpec.isDiscriminator = true   # routes failures to peTypeDiscriminatorBad
      if discSpec.kind notin {fkArg, fkAttr}:
        error("deriveDecode: variant discriminator '" & discSpec.nimName &
              "' must declare its KDL position with an explicit " &
              "{.kdlArg.} or {.kdlAttr.} pragma. " &
              "(Discriminators are load-bearing; no implicit default.)",
              child)
      result.variant.disc = discSpec
      # Walk of-branches. Each branch has its own arg cursor starting
      # from the post-discriminator value — branches are mutually
      # exclusive so their kdlArg slots overlap.
      for i in 1 ..< child.len:
        let branchNode = child[i]
        case branchNode.kind
        of nnkOfBranch:
          if branchNode.len != 2:
            error("deriveDecode: multi-value `of K1, K2: ...` branches " &
                  "aren't supported (v0.1)", branchNode)
          let discValue = branchNode[0]
          let branchRecList = branchNode[1]
          var branchArgCursor = argCursor
          var branch = VariantBranch(discValue: discValue)
          if branchRecList.kind == nnkRecList:
            for bChild in branchRecList:
              if bChild.kind == nnkIdentDefs:
                branch.fields.add(parseIdentDefs(bChild, branchArgCursor))
              elif bChild.kind == nnkRecCase:
                error("deriveDecode: nested case blocks aren't supported " &
                      "(v0.1)", bChild)
          # Empty branch (`of K: discard`) is valid; branch.fields stays empty
          result.variant.branches.add(branch)
        of nnkElse:
          error("deriveDecode: `else` branch in case object isn't supported " &
                "(v0.1); enumerate every discriminator value explicitly",
                branchNode)
        else:
          discard
    else:
      discard

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

# ---------------------------------------------------------------------------
# Field-decode emit helpers — generate the per-field statements that the
# deriveDecode macro splices into kdlDecodeImpl's body.
#
# Each helper returns Nim AST that:
#   - on success, mutates `targetAccess` (or appends to it for seq[T])
#   - on failure, `return err[void, ParseError](...)` — short-circuits the
#     enclosing proc. No accumulator; per the un-hedged C3 design.
# ---------------------------------------------------------------------------

proc mismatchEmitter(f: FieldSpec): NimNode =
  ## Pick the right ParseError-construction helper based on field shape:
  ## - discriminator → peTypeDiscriminatorBad (variant shape is wrong)
  ## - enum field → peTypeEnumInvalid (string didn't match any member)
  ## - everything else → peTypeMismatch (wrong primitive type)
  if f.isDiscriminator: ident("discriminatorErrAt")
  elif f.typeIsEnum:    ident("enumMismatchErrAt")
  else:                 ident("mismatchErrAt")

proc emitArgDecode(f: FieldSpec, targetAccess, nodeIdent, docIdent: NimNode):
    NimNode =
  let idxLit = newLit(f.argIndex)
  let mismatchMsg = newLit(
    "type mismatch on positional arg " & $f.argIndex &
    " ('" & f.kdlName & "')")
  let missingMsg = newLit(
    "missing required positional arg " & $f.argIndex &
    " ('" & f.kdlName & "')")
  let span = quote do: `nodeIdent`.span
  let mEmit = mismatchEmitter(f)
  let absentBranch =
    if f.defaultExpr.kind == nnkEmpty:
      quote do:
        return err[void, ParseError](missingErrAt(`missingMsg`, `span`))
    else:
      newEmptyNode()  # absent + has default → already set; skip
  quote do:
    if `nodeIdent`.hasArg(`idxLit`):
      if not kdlDecodeValue(`targetAccess`,
                            `nodeIdent`.findArg(`idxLit`),
                            `docIdent`):
        return err[void, ParseError](`mEmit`(`mismatchMsg`, `span`))
    else:
      `absentBranch`

proc emitAttrDecode(f: FieldSpec, targetAccess, nodeIdent, docIdent: NimNode):
    NimNode =
  let kdlNameStr = newLit(f.kdlName)
  let keyIdent = genSym(nskLet, "kdlKey")
  let mismatchMsg = newLit("type mismatch on property '" & f.kdlName & "'")
  let missingMsg = newLit("missing required property '" & f.kdlName & "'")
  let span = quote do: `nodeIdent`.span
  let mEmit = mismatchEmitter(f)
  let absentBranch =
    if f.defaultExpr.kind == nnkEmpty:
      quote do:
        return err[void, ParseError](missingErrAt(`missingMsg`, `span`))
    else:
      newEmptyNode()
  quote do:
    let `keyIdent` = `docIdent`.interner.intern(`kdlNameStr`)
    if `nodeIdent`.hasProp(`keyIdent`):
      if not kdlDecodeValue(`targetAccess`,
                            `nodeIdent`.findProp(`keyIdent`),
                            `docIdent`):
        return err[void, ParseError](`mEmit`(`mismatchMsg`, `span`))
    else:
      `absentBranch`

proc emitChildDecode(f: FieldSpec, targetAccess, nodeIdent, docIdent: NimNode):
    NimNode =
  let kdlNameStr = newLit(f.kdlName)
  let nameIdent = genSym(nskLet, "kdlChildName")
  if typeNodeIsSeq(f.typeNode):
    let elemType = f.typeNode[1]
    let elemSym = genSym(nskVar, "elem")
    let childSym = genSym(nskForVar, "child")
    let recurseRes = genSym(nskLet, "recurseRes")
    quote do:
      let `nameIdent` = `docIdent`.interner.intern(`kdlNameStr`)
      for `childSym` in `nodeIdent`.childrenNamed(`nameIdent`):
        var `elemSym`: `elemType`
        let `recurseRes` = kdlDecodeImpl(`elemSym`, `childSym`, `docIdent`)
        if `recurseRes`.isErr:
          return err[void, ParseError](`recurseRes`.getErr)
        `targetAccess`.add(`elemSym`)
  else:
    # Scalar kdlChild. Required-vs-optional follows the same rule as
    # fkArg / fkAttr: a field with no default value (and no kdlSkip)
    # is required, so an absent child surfaces peTypeMissingRequired
    # rather than silently leaving the field at default(T).
    let recurseRes = genSym(nskLet, "recurseRes")
    let missingMsg = newLit(
      "missing required child node '" & f.kdlName & "'")
    let span = quote do: `nodeIdent`.span
    let absentBranch =
      if f.defaultExpr.kind == nnkEmpty:
        quote do:
          return err[void, ParseError](missingErrAt(`missingMsg`, `span`))
      else:
        newEmptyNode()
    let childSym = genSym(nskLet, "kdlChild")
    quote do:
      let `nameIdent` = `docIdent`.interner.intern(`kdlNameStr`)
      let `childSym` = `nodeIdent`.findChild(`nameIdent`)
      if not (`childSym`.name == InvalidInterned):
        let `recurseRes` = kdlDecodeImpl(`targetAccess`, `childSym`, `docIdent`)
        if `recurseRes`.isErr:
          return err[void, ParseError](`recurseRes`.getErr)
      else:
        `absentBranch`

proc emitFieldDecode(f: FieldSpec, targetAccess, nodeIdent, docIdent: NimNode):
    NimNode =
  ## Per-field statement that decodes into `targetAccess` (a field-access
  ## expression like `target.foo` or a local-var ident). Short-circuits on
  ## error via `return err(...)`.
  case f.kind
  of fkSkip: newStmtList()
  of fkArg:  emitArgDecode(f, targetAccess, nodeIdent, docIdent)
  of fkAttr: emitAttrDecode(f, targetAccess, nodeIdent, docIdent)
  of fkChild: emitChildDecode(f, targetAccess, nodeIdent, docIdent)

macro deriveDecode*(typ: typedesc): untyped =
  ## Emit a `kdlDecodeImpl` overload for `typ`. The procedure walks a
  ## KdlNode and populates `var typ` from its entries and children.
  ##
  ## Returns `Result[void, ParseError]`: `ok` on success, `err` on the
  ## first decode failure (short-circuit; no error accumulation — see
  ## review-round-1 un-hedge of C3 for rationale).
  ##
  ## Object variants (`case kind: K of K1: ...`) are supported with
  ## atomic construction semantics: the discriminator decodes first,
  ## then each branch's fields decode into locals, then `target` is
  ## assigned in one expression. Any failure short-circuits without
  ## touching `target`.
  ##
  ## Generated code is dumpable via `-d:dumpKdlGen`.

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
  let shape = collectShape(recList)

  let nodeIdent = ident("node")
  let docIdent  = ident("doc")
  let tgtIdent  = ident("target")
  var stmts = newStmtList()

  if not shape.hasVariant:
    # Non-variant path: decode directly into target's fields.
    # Apply defaults to target up front so absent-optional fields land
    # at the right value without per-field default code paths.
    for f in shape.shared:
      if f.defaultExpr.kind != nnkEmpty:
        let nimField = ident(f.nimName)
        let dExpr = f.defaultExpr
        stmts.add quote do:
          `tgtIdent`.`nimField` = `dExpr`
    for f in shape.shared:
      let targetAccess = newDotExpr(tgtIdent, ident(f.nimName))
      stmts.add(emitFieldDecode(f, targetAccess, nodeIdent, docIdent))
    stmts.add quote do:
      ok(void, ParseError)
  else:
    # Variant path: decode shared + discriminator into LOCALS, then
    # construct `target` atomically inside each case branch. Atomic
    # construction is required by Nim's case-object rules — partial
    # mutation of branch fields without a fully-set discriminator is
    # unsafe (Q3 (ii) — see review-round-1 H9 grilling).

    # Local declarations for shared fields, with defaults if present.
    var sharedLocals: seq[NimNode]   # parallel to shape.shared
    for f in shape.shared:
      let local = genSym(nskVar, "sharedLocal_" & f.nimName)
      sharedLocals.add(local)
      let typeNode = f.typeNode
      if f.defaultExpr.kind != nnkEmpty:
        let dExpr = f.defaultExpr
        stmts.add quote do:
          var `local`: `typeNode` = `dExpr`
      else:
        stmts.add quote do:
          var `local`: `typeNode`
    # Decode each shared field into its local.
    for i, f in shape.shared:
      stmts.add(emitFieldDecode(f, sharedLocals[i], nodeIdent, docIdent))

    # Discriminator local + decode.
    let disc = shape.variant.disc
    let discLocal = genSym(nskVar, "disc_" & disc.nimName)
    let discType = disc.typeNode
    stmts.add quote do:
      var `discLocal`: `discType`
    stmts.add(emitFieldDecode(disc, discLocal, nodeIdent, docIdent))

    # case discLocal: of each branch. Construct via `typSym` (the
    # unwrapped type symbol) rather than the raw `typ` typedesc node, so
    # `deriveDecode(typeof(expr))` and parametric aliases yield a
    # well-formed ObjConstr.
    let caseStmt = nnkCaseStmt.newTree(discLocal)
    for branch in shape.variant.branches:
      var branchBody = newStmtList()
      var branchLocals: seq[NimNode]
      for f in branch.fields:
        let local = genSym(nskVar, "branchLocal_" & f.nimName)
        branchLocals.add(local)
        let typeNode = f.typeNode
        if f.defaultExpr.kind != nnkEmpty:
          let dExpr = f.defaultExpr
          branchBody.add quote do:
            var `local`: `typeNode` = `dExpr`
        else:
          branchBody.add quote do:
            var `local`: `typeNode`
      for i, f in branch.fields:
        branchBody.add(emitFieldDecode(f, branchLocals[i],
                                       nodeIdent, docIdent))
      # Atomic construction: target = T(kind: branchValue,
      #   sharedField: sharedLocal, ..., branchField: branchLocal, ...)
      let construction = nnkObjConstr.newTree(typSym)
      construction.add(nnkExprColonExpr.newTree(
        ident(disc.nimName), branch.discValue))
      for i, f in shape.shared:
        construction.add(nnkExprColonExpr.newTree(
          ident(f.nimName), sharedLocals[i]))
      for i, f in branch.fields:
        construction.add(nnkExprColonExpr.newTree(
          ident(f.nimName), branchLocals[i]))
      branchBody.add quote do:
        `tgtIdent` = `construction`
      caseStmt.add(nnkOfBranch.newTree(branch.discValue, branchBody))
    stmts.add(caseStmt)
    stmts.add quote do:
      ok(void, ParseError)

  let nodeNameLit = newLit(extractNodeName(typSym))
  let nodeNameProc = quote do:
    proc kdlNodeNameImpl*(typ: typedesc[`typ`]): string {.inline.} =
      `nodeNameLit`

  let decodeProc = quote do:
    proc kdlDecodeImpl*(`tgtIdent`: var `typ`;
                       `nodeIdent`: KdlNode;
                       `docIdent`: var KdlDoc): Result[void, ParseError]
        {.noSideEffect.} =
      `stmts`

  result = newStmtList(nodeNameProc, decodeProc)
  when defined(dumpKdlGen):
    echo "=== kdlDecodeImpl + kdlNodeNameImpl for ", repr(typ), " ==="
    echo result.repr
    echo "==="

# ---------------------------------------------------------------------------
# parse[T]
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# embed[T] — compile-time staticRead + module-init parse
# ---------------------------------------------------------------------------
#
# Builtin default files (`src/builtins/rules/*.kdl` etc.) embed into the
# binary via `staticRead`. The macro validates that the file exists at
# compile time (via staticRead) and emits a runtime parse against T so
# malformed files surface immediately on the first access — and during
# tests, before any real consumer runs.
#
# Multi-file aggregation: users compose at the call site. e.g.
#
#   const builtinRules* = @[
#     embed[Rule]("src/builtins/rules/compaction.kdl").get,
#     embed[Rule]("src/builtins/rules/dates.kdl").get,
#   ]
#
# Compile-time *evaluation* of the parser chain is filed as v0.2 polish;
# the VM-friendliness audit (every proc in the call graph noSideEffect +
# {.compileTime.}-callable) is the gating work.

import std/os

macro embedAux*(T: typed; path, callerFile: static[string]): untyped =
  ## Implementation backing the `embed[T]` template. `staticRead` runs
  ## here at compile time; the resulting bytes are embedded as a literal.
  ## `callerFile` is the absolute path of the .nim file at the call site;
  ## the template fills it via `instantiationInfo`.
  ##
  ## Emits a `const`-evaluated decode call. The parse+decode chain runs
  ## in Nim's VM when invoked in a `const` context (which `embed[T]`'s
  ## `compileTimeDecoded` binding forces); a malformed file then surfaces
  ## as a compile-time error carrying the parse diagnostic. The decoded
  ## `Result` is still copied into a runtime location at module init —
  ## the win is moving parse work to build time, not eliminating module
  ## init entirely.
  let resolved =
    if isAbsolute(path): path
    else: callerFile.parentDir / path
  let body = staticRead(resolved)
  let bodyLit = newLit(body)
  let pathLit = newLit(resolved)
  result = quote do:
    const compileTimeDecoded = decode[`T`](`bodyLit`, `pathLit`)
    compileTimeDecoded

template embed*[T](path: static[string]): Result[T, ParseError] =
  ## Embed a KDL file's contents into the binary at compile time and
  ## parse them as type `T` at module initialization.
  ##
  ## Relative paths resolve against the .nim file that *invokes* the
  ## template (via `instantiationInfo`), matching the developer's
  ## expectation when colocating fixtures next to a test or rule loader.
  ## Absolute paths are used as-is.
  ##
  ## A missing or unreadable file fails the build at compile time.
  embedAux(T, path, instantiationInfo(fullPaths = true).filename)

proc kdlNodeNameImpl*(typ: typedesc): string =
  ## Placeholder — `deriveDecode(T)` emits a typedesc[T] overload that
  ## returns the actual node name (per `{.kdlNode.}` pragma or
  ## type-name-lowercased fallback). This base version exists only so
  ## generic `parse[T]` typechecks when called on a type without a
  ## decoder yet — it'll fail the runtime lookup with an empty name,
  ## but the static phase compiles cleanly.
  ""

proc decode*[T](source: string,
                sourcePath: string = "<input>"): Result[T, ParseError]
    {.noSideEffect.} =
  ## Parse `source` as a KDL document and decode into `T`.
  ## (Named `decode` rather than `parse` to disambiguate from
  ## `parser.parse`, which returns the untyped KdlDoc.)
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
    let nameKey = doc.interner.intern(wantName)
    var elems: T = @[]
    for i in 0 ..< doc.nodes.len:
      if doc.nodes[i].name == nameKey:
        var elem: Elem
        let r = kdlDecodeImpl(elem, doc.nodes[i], doc)
        if r.isErr:
          return err[T, ParseError](r.getErr)
        elems.add(elem)
    ok[T, ParseError](elems)
  else:
    let wantName = kdlNodeNameImpl(typeof(T))
    let nameKey = doc.interner.intern(wantName)
    var outValue: T
    var found = false
    for i in 0 ..< doc.nodes.len:
      if doc.nodes[i].name == nameKey:
        let r = kdlDecodeImpl(outValue, doc.nodes[i], doc)
        if r.isErr:
          return err[T, ParseError](r.getErr)
        found = true
        break
    if not found:
      err[T, ParseError](initError(peTypeMissingRequired,
        pointSpan(StartPosition),
        "expected node '" & wantName & "' at top level"))
    else:
      ok[T, ParseError](outValue)
