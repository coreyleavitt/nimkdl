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
## import nkdl
##
## kdl:
##   type ActionKind = enum
##     akInject = "inject"
##     akDeny   = "deny"
##
##   type Action {.kdlNode: "action".} = object
##     kind {.kdlArg.}: ActionKind
##     tmpl {.kdlProp, kdlRename: "template".}: string
##
##   type Rule {.kdlNode: "rule".} = object
##     id {.kdlArg.}: string
##     enabled {.kdlProp.}: bool = true
##     action {.kdlChild.}: Action
##
## let r = decode[Rule]("rule \"compaction\" {\n  action \"inject\"\n}")
## ```
##
## One `kdl:` block per file is usually enough — it walks every typedef
## inside and emits decode/encode/typed-direct codegen for any
## `{.kdlNode.}`-marked type. Helper types (no `{.kdlNode.}`) pass
## through unchanged.
##
## ## Pragmas
##
## Type-level:
##   - `{.kdlNode: "name".}`  — overrides the node name (default = type name lowercased)
##
## Field-level:
##   - `{.kdlArg.}`           — positional argument
##   - `{.kdlProp.}`          — property (`key=value`)
##   - `{.kdlChild.}`         — child node (default for nested objects + seq[T])
##   - `{.kdlSkip.}`          — never decoded; uses Nim default value
##   - `{.kdlRename: "x".}`   — override the KDL name for this field
##   - `{.kdlReserved: "tag".}` — value must carry the reserved KDL type tag
##   - Native Nim defaults (`field: T = expr`) double as fallback values

import std/[macros, strutils, tables]

import ./ast
import ./encode as kdlEncode  # AST-level encoder; aliased to avoid clash
import ./intern
import ./parser
import ./reserved
import ./spans

# Re-export the ast/parser/reserved helpers that the `kdl:` block
# macro's emitted decode/encode code calls by bare-identifier (e.g.
# `node.children(doc, "x")`, `peTypeMismatch`, `validateReserved`,
# `decode[T]`). Without these re-exports, every consumer of `kdl:`
# would have to chase the transitive imports themselves. The block
# macro is the sole public surface; the imports it implies are part
# of that surface.
export ast, parser, reserved, spans, intern

# ---------------------------------------------------------------------------
# Pragmas (just marker templates — no behavior)
# ---------------------------------------------------------------------------

template kdlNode*(name: string) {.pragma.}
  ## Type-level: explicit KDL node name. Defaults to type-name lowercased.
  ## See ``kdl`` for the all-in-one pragma that also emits the derives.
template kdlArg*() {.pragma.}
  ## Field-level: serialize/parse as a positional argument.
template kdlProp*() {.pragma.}
  ## Field-level: serialize/parse as a property (key=value).
template kdlChild*() {.pragma.}
  ## Field-level: serialize/parse as a child node (default for objects + seq).
template kdlSkip*() {.pragma.}
  ## Field-level: do not parse — keep Nim's default.
template kdlRename*(name: string) {.pragma.}
  ## Field-level: KDL name differs from Nim field name.
template kdlReserved*(tag: string) {.pragma.}
  ## Field-level: assert the source KDL value carries this reserved-type
  ## annotation (e.g. `{.kdlReserved: "ipv4".}`). At decode time, a
  ## value lacking the declared tag — or carrying a different one —
  ## produces `peTypeReservedMismatch`. Layer-1 parse-time validation
  ## (see src/reserved.nim) still applies to the tag's content.

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
  ## the target's high bound; negative KDL ints (and negative bigints)
  ## fail decoding. For uint64 targets, KDL values in
  ## `(int64.high, uint64.high]` arrive as kvBigInt and are accepted.
  case v.kind
  of kvInt:
    if v.intVal < 0: return false
    when T.sizeof < uint64.sizeof:
      if uint64(v.intVal) > uint64(T.high): return false
    target = T(v.intVal); true
  of kvBigInt:
    if v.bigNegative: return false
    when T.sizeof < uint64.sizeof:
      return false  # any bigint magnitude exceeds sub-64-bit targets
    else:
      if v.bigHi != 0: return false  # exceeds uint64
      target = T(v.bigLo); true
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

macro buildEnumCaseImpl(target, s: typed; T: typedesc): untyped =
  ## Emit a per-enum `case s of "memberStr": target = E.member` block.
  ## Replaces the previous `for member in E.low..E.high: if $member == s`
  ## loop which allocated a fresh string per member every call. Nim's
  ## `case` on `string` lowers to an efficient dispatch internally; the
  ## emitted code is per-enum-specialised at macro-expansion time.
  ##
  ## Honors Nim 2.x's stringified-value syntax:
  ##   `akInject = "inject"`  →  matches the literal "inject".
  ## Bare members (no `= "..."`) match their symbol name.
  # T may arrive as:
  #   - `typedesc[E]` BracketExpr (literal typedesc passed at call site)
  #   - a symbol pointing at the typedesc parameter of an enclosing
  #     generic proc — `getType` then unwraps to typedesc[E]
  #   - the concrete enum symbol directly
  # Normalise to the concrete enum symbol whose `getImpl` gives the
  # TypeDef.
  var typSym = T
  if typSym.kind == nnkBracketExpr and typSym.len >= 2:
    typSym = typSym[1]
  else:
    let ti = typSym.getTypeInst
    if ti.kind == nnkBracketExpr and ti.len >= 2:
      typSym = ti[1]
  let typeDef = typSym.getImpl
  if typeDef.kind != nnkTypeDef:
    error("buildEnumCase: expected an enum typedesc; getImpl produced " &
          $typeDef.kind & " from " & typSym.repr, T)
  let body = typeDef[2]
  if body.kind != nnkEnumTy:
    error("buildEnumCase: expected enum body, got " & $body.kind, T)
  var caseStmt = nnkCaseStmt.newTree(s)
  for i in 1 ..< body.len:  # body[0] is the empty pragma slot
    let m = body[i]
    var matchLit: string
    var memberRef: NimNode
    case m.kind
    of nnkEnumFieldDef:
      memberRef = m[0]
      # m[1] is either an int literal (ord override only) or a string
      # literal (stringified form). For string form, that's the canonical
      # `$member` representation per Nim 2.x; for int form, fall back to
      # the symbol name.
      if m[1].kind == nnkStrLit:
        matchLit = m[1].strVal
      else:
        matchLit = $m[0]
    of nnkSym, nnkIdent:
      memberRef = m
      matchLit = $m
    else:
      error("buildEnumCase: unexpected enum member shape: " & $m.kind, m)
    caseStmt.add(nnkOfBranch.newTree(newLit(matchLit),
                                      quote do:
                                        `target` = `memberRef`
                                        return true))
  caseStmt.add(nnkElse.newTree(quote do: return false))
  result = caseStmt

proc decodeEnumFromString*[E: enum](target: var E, s: string): bool =
  ## Per-enum case-on-string dispatch (specialised at instantiation
  ## via the `buildEnumCaseImpl` macro). Honors Nim 2.x's
  ## stringified-value syntax (`akInject = "inject"` matches "inject"
  ## rather than "akInject"). Previously walked every member via
  ## `for member in E.low..E.high: if $member == s` — one string
  ## allocation per member per call.
  buildEnumCaseImpl(target, s, E)

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
# Primitive encoders
# ---------------------------------------------------------------------------
#
# `kdlEncodeValue` overloads convert a typed Nim value into a `KdlValue`.
# Symmetric counterpart to `kdlDecodeValue`. Used by `deriveEncode`'s
# generated `kdlEncodeImpl` procs.

func kdlEncodeValue*(s: string): KdlValue =
  newStringValue(s)

func kdlEncodeValue*[T: SomeSignedInt](i: T): KdlValue =
  newIntValue(int64(i))

func kdlEncodeValue*[T: SomeUnsignedInt](i: T): KdlValue =
  # uint64 magnitudes that exceed int64.high promote to kvBigInt.
  when T.sizeof == uint64.sizeof:
    if uint64(i) > uint64(int64.high):
      return newBigIntValue(0, uint64(i), false)
  newIntValue(int64(i))

func kdlEncodeValue*[T: SomeFloat](f: T): KdlValue =
  newFloatValue(float(f))

func kdlEncodeValue*(b: bool): KdlValue =
  newBoolValue(b)

func kdlEncodeValue*[E: enum](e: E): KdlValue =
  newStringValue($e)

# ---------------------------------------------------------------------------
# Helpers used by generated decoders
# ---------------------------------------------------------------------------

## Codegen-internal accessors over the AST. All take **InternedStr**
## handles and so are independent of the doc's interner — used inside
## generated decoders where the field-name handle is interned once and
## reused for every iteration. The string-keyed counterparts live in
## `ast.nim` (`prop` / `child` / `node` / `arg` / etc.) and are the
## right thing for user code.
##
## The `Interned` suffix is load-bearing: without it, codegen's
## InternedStr-keyed `hasProp` would collide with `ast.nim`'s
## string-keyed `hasProp` on the same symbol name — same arity,
## different key type — and Nim's overload resolution would silently
## pick the wrong one in code that imports both modules.

proc findPropInterned*(n: KdlNode, key: InternedStr): KdlValue =
  for (k, v) in n.properties:
    if k == key: return v
  return newNullValue()

proc hasPropInterned*(n: KdlNode, key: InternedStr): bool =
  for (k, _) in n.properties:
    if k == key: return true
  return false

proc findChildInterned*(n: KdlNode, nameHandle: InternedStr): KdlNode =
  for c in n.children:
    if c.name == nameHandle: return c
  return KdlNode(name: InvalidInterned)

proc hasChildInterned*(n: KdlNode, nameHandle: InternedStr): bool =
  for c in n.children:
    if c.name == nameHandle: return true
  return false

proc childrenNamedInterned*(n: KdlNode, nameHandle: InternedStr): seq[KdlNode] =
  for c in n.children:
    if c.name == nameHandle: result.add(c)

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
    expectedReserved: string  ## non-empty ⇒ source value must carry
                              ## this reserved-type annotation (set
                              ## by the `{.kdlReserved: "tag".}` pragma)
    isOption: bool            ## true ⇒ field type is `Option[T]`;
                              ## absent input maps to `none(T)`,
                              ## present input wraps in `some(T)`,
                              ## and encode emits only when `some`
    innerType: NimNode        ## valid when isOption: the `T` of
                              ## `Option[T]`. Otherwise nil.

proc fieldKindFromPragmas(prag: NimNode): FieldKind =
  ## Walk a field's pragma list and return its FieldKind from explicit
  ## `{.kdlArg.}` / `{.kdlProp.}` / `{.kdlChild.}` / `{.kdlSkip.}` pragmas.
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
    of "kdlProp":   return fkAttr
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

proc reservedFromPragmas(prag: NimNode): string =
  ## Returns the `kdlReserved` declared tag for the field, or "" if
  ## absent. Empty means "no constraint on the source value's tag".
  for p in prag:
    if p.kind in {nnkExprColonExpr, nnkCall} and p.len >= 2:
      if $p[0] == "kdlReserved":
        let lit = p[1]
        if lit.kind == nnkStrLit: return lit.strVal
  ""

proc typeNodeIsSeq(t: NimNode): bool =
  ## True if `t` is `seq[T]` for some T. Detected at the syntactic level
  ## because `seq` is the only generic we special-case for fkChild default.
  t.kind == nnkBracketExpr and t.len >= 1 and (($t[0]) == "seq")

proc typeNodeIsOption(t: NimNode): bool =
  ## True if `t` is `Option[T]` for some T. Detected at the syntactic
  ## level — the macro doesn't need (or want) to resolve through Nim's
  ## type system since `Option` is a stable stdlib name.
  t.kind == nnkBracketExpr and t.len >= 1 and (($t[0]) == "Option")

proc optionInnerType(t: NimNode): NimNode =
  ## Unwrap `Option[T]` → `T`. Caller verifies `typeNodeIsOption(t)`.
  t[1]

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

proc extractNodeName(typeSym: NimNode): string  # forward decl

proc parseIdentDefs(identDefs: NimNode, argCursor: var int):
    seq[FieldSpec] =
  ## Walk one `nnkIdentDefs` (a single declaration line like `a, b: int = 0`)
  ## and emit a FieldSpec per name. Mutates `argCursor` for each fkArg
  ## field encountered.
  ##
  ## (forward-decl shim: `extractNodeName` is defined later in this file
  ## but reflectField needs it for kdlChild kdlName resolution.)
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
    # Detect `Option[T]`. We "unwrap" for the purposes of computing
    # type-driven defaults (fkChild for objects, fkAttr for primitives)
    # but keep the original Option-ness on the FieldSpec so the emit
    # path can wrap the decoded value in `some(...)` / handle `none`.
    let optWrap = typeNodeIsOption(typeNode)
    let unwrappedType =
      if optWrap: optionInnerType(typeNode)
      else: typeNode
    if optWrap and typeNodeIsSeq(unwrappedType):
      error("kdl: Option[seq[T]] is not supported — `seq[T]` " &
            "already represents the optional-list semantic. Use seq[T] " &
            "directly.", typeNode)
    let kind =
      if prag.len == 0:
        (if typeNodeIsObject(unwrappedType) or typeNodeIsSeq(unwrappedType):
           fkChild
         else: fkAttr)
      else: fieldKindFromPragmas(prag)
    # For kdlChild fields, the KDL node name comes from the CHILD
    # TYPE's `{.kdlNode.}` pragma (not the Nim field name). Explicit
    # `{.kdlRename.}` wins over both. For seq[T] / Option[T] children,
    # unwrap to the element type before looking up.
    let renamePragma = kdlNameFromPragmas(prag, "")
    let kdlName =
      if renamePragma.len > 0:
        renamePragma
      elif kind == fkChild:
        let childTypeForName =
          if typeNodeIsSeq(typeNode): typeNode[1]
          else: unwrappedType
        extractNodeName(childTypeForName)
      else:
        nimName.toLowerAscii
    var spec = FieldSpec(nimName: nimName, kdlName: kdlName,
                         kind: kind, typeNode: typeNode,
                         defaultExpr: defaultExpr,
                         typeIsEnum: typeNodeIsEnum(unwrappedType),
                         expectedReserved: reservedFromPragmas(prag),
                         isOption: optWrap,
                         innerType: (if optWrap: unwrappedType else: nil))
    if kind == fkArg:
      spec.argIndex = argCursor
      inc argCursor
    result.add(spec)

type
  VariantBranch = object
    discValue*: NimNode        ## the enum-member identifier (e.g. `akInject`)
    fields*: seq[FieldSpec]    ## fields under this branch

  VariantSpec = object
    disc*: FieldSpec           ## the discriminator field
    branches*: seq[VariantBranch]

  TypeShape = object
    shared*: seq[FieldSpec]    ## fields appearing before any case block
    hasVariant*: bool
    variant*: VariantSpec

proc collectShape(recList: NimNode): TypeShape =
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
        error("kdl: fields after a case block aren't supported " &
              "(v0.1); put all non-variant fields before the case", child)
      result.shared.add(parseIdentDefs(child, argCursor))
    of nnkRecCase:
      if result.hasVariant:
        error("kdl: multiple case blocks per type aren't supported " &
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
        error("kdl: variant discriminator '" & discSpec.nimName &
              "' must declare its KDL position with an explicit " &
              "{.kdlArg.} or {.kdlProp.} pragma. " &
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
            error("kdl: multi-value `of K1, K2: ...` branches " &
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
                error("kdl: nested case blocks aren't supported " &
                      "(v0.1)", bChild)
          # Empty branch (`of K: discard`) is valid; branch.fields stays empty
          result.variant.branches.add(branch)
        of nnkElse:
          error("kdl: `else` branch in case object isn't supported " &
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

proc extractTypeReserved(typeSym: NimNode): string =
  ## Read the `{.kdlReserved: "tag".}` pragma from `typeSym`'s typedef,
  ## or "" if absent. When set, the generated decoder asserts the
  ## top-level node carries this tag, and the encoder emits it.
  let impl = typeSym.getImpl
  if impl.kind != nnkTypeDef: return ""
  let nameNode = impl[0]
  if nameNode.kind != nnkPragmaExpr: return ""
  let prag = nameNode[1]
  for p in prag:
    if p.kind in {nnkExprColonExpr, nnkCall} and p.len >= 2:
      if $p[0] == "kdlReserved":
        let lit = p[1]
        if lit.kind == nnkStrLit: return lit.strVal
  ""

# ---------------------------------------------------------------------------
# deriveEncode — symmetric counterpart to deriveDecode
# ---------------------------------------------------------------------------

proc prefixEncodeHint*(err: var ParseError, path: string) {.inline.} =
  ## Mutate `err` in place so its `hint` begins with `path: ...`.
  ## Used by macro-emitted encode validators to surface
  ## `TypeName.fieldName` context, since the encode side has no real
  ## source-file span (the value came from Nim, not from a parse).
  if err.hint.len > 0:
    err.hint = path & ": " & err.hint
  else:
    err.hint = path

proc emitReservedTagValidate(f: FieldSpec, valIdent: NimNode,
                             pathLit: NimNode): NimNode =
  ## Emit a runtime check that `valIdent`'s tagged content matches the
  ## tag's spec interpretation. Symmetric Layer 1: parse-time validates
  ## inputs; encode-time validates outputs so we never silently produce
  ## malformed KDL. Empty when no `kdlReserved` is declared.
  ##
  ## `pathLit` is a string literal of the form `TypeName.fieldName` that
  ## gets prefixed onto the error's `hint` on failure — see L1 in
  ## BACKLOG.md. The encode span stays synthetic; the hint carries the
  ## useful diagnostic.
  if f.expectedReserved.len == 0:
    return newEmptyNode()
  let tagLit = newLit(f.expectedReserved)
  quote do:
    let vcheck = validateReserved(`tagLit`, `valIdent`)
    if vcheck.isErr:
      var e = vcheck.getErr
      prefixEncodeHint(e, `pathLit`)
      return err[KdlNode, ParseError](e)

proc encodeValueCore(f: FieldSpec, sourceAccess, valSym, docIdent,
                     pathLit: NimNode): NimNode =
  ## Shared body: build a KdlValue from `sourceAccess`, optionally tag
  ## with kdlReserved, validate, into `valSym`. Used by both arg and
  ## attr emitters; the Option case calls this on `sourceAccess.get`.
  ## `pathLit` is the string literal for `TypeName.fieldName` used by
  ## the reserved-tag validator on failure.
  let inner =
    if f.isOption: newDotExpr(sourceAccess, ident("get"))
    else: sourceAccess
  result = newStmtList()
  result.add quote do:
    var `valSym` = kdlEncodeValue(`inner`)
  if f.expectedReserved.len > 0:
    let tagLit = newLit(f.expectedReserved)
    result.add quote do:
      `valSym`.typeAnnotation = `docIdent`.interner.intern(`tagLit`)
  result.add(emitReservedTagValidate(f, valSym, pathLit))

proc emitArgEncode(f: FieldSpec, sourceAccess, docIdent, nodeIdent,
                   pathLit: NimNode): NimNode =
  ## Emit code that appends `v.fieldName` as a positional argument on
  ## the generated node. For Option fields, `none` skips the entry
  ## entirely; `some(v)` emits `v` normally (with kdlReserved checks).
  let valSym = genSym(nskVar, "argVal_" & f.nimName)
  let core = encodeValueCore(f, sourceAccess, valSym, docIdent, pathLit)
  let appendStmt = quote do:
    `nodeIdent`.entries.add(KdlEntry(
      kind: keArgument,
      argValue: `valSym`,
      span: `nodeIdent`.span))
  if f.isOption:
    quote do:
      if `sourceAccess`.isSome:
        `core`
        `appendStmt`
  else:
    newStmtList(core, appendStmt)

proc emitAttrEncode(f: FieldSpec, sourceAccess, docIdent, nodeIdent,
                    pathLit: NimNode): NimNode =
  ## Emit code that appends `v.fieldName` as a `name=value` property.
  ## For Option fields, `none` skips the entry entirely.
  let valSym = genSym(nskVar, "attrVal_" & f.nimName)
  let kdlNameLit = newLit(f.kdlName)
  let core = encodeValueCore(f, sourceAccess, valSym, docIdent, pathLit)
  let appendStmt = quote do:
    `nodeIdent`.entries.add(KdlEntry(
      kind: keProperty,
      propName: `docIdent`.interner.intern(`kdlNameLit`),
      propValue: `valSym`,
      span: `nodeIdent`.span))
  if f.isOption:
    quote do:
      if `sourceAccess`.isSome:
        `core`
        `appendStmt`
  else:
    newStmtList(core, appendStmt)

proc emitChildEncode(f: FieldSpec, sourceAccess, docIdent, nodeIdent: NimNode):
    NimNode =
  ## Emit code that recursively encodes a child object (or seq, or
  ## Option[Object]) and appends as a nested node. The recursive call
  ## returns `Result[KdlNode, ParseError]`; propagate Err.
  ##
  ## When the field has `kdlReserved`, the produced child node's
  ## typeAnnotation is set to the declared tag before appending —
  ## symmetric with the decode-side child-tag assertion.
  let childNodeSym = genSym(nskVar, "childNode_" & f.nimName)
  let setTagStmts =
    if f.expectedReserved.len > 0:
      let tagLit = newLit(f.expectedReserved)
      quote do:
        `childNodeSym`.typeAnnotation = `docIdent`.interner.intern(`tagLit`)
    else:
      newEmptyNode()

  if typeNodeIsSeq(f.typeNode):
    let elemSym = genSym(nskForVar, "childElem_" & f.nimName)
    let recSym  = genSym(nskLet, "childRes_" & f.nimName)
    quote do:
      for `elemSym` in `sourceAccess`:
        let `recSym` = kdlEncodeImpl(`elemSym`, `docIdent`)
        if `recSym`.isErr:
          return err[KdlNode, ParseError](`recSym`.getErr)
        var `childNodeSym` = `recSym`.get
        `setTagStmts`
        `nodeIdent`.children.add(`childNodeSym`)
  elif f.isOption:
    let recSym = genSym(nskLet, "childRes_" & f.nimName)
    let innerAccess = newDotExpr(sourceAccess, ident("get"))
    quote do:
      if `sourceAccess`.isSome:
        let `recSym` = kdlEncodeImpl(`innerAccess`, `docIdent`)
        if `recSym`.isErr:
          return err[KdlNode, ParseError](`recSym`.getErr)
        var `childNodeSym` = `recSym`.get
        `setTagStmts`
        `nodeIdent`.children.add(`childNodeSym`)
  else:
    let recSym = genSym(nskLet, "childRes_" & f.nimName)
    quote do:
      let `recSym` = kdlEncodeImpl(`sourceAccess`, `docIdent`)
      if `recSym`.isErr:
        return err[KdlNode, ParseError](`recSym`.getErr)
      var `childNodeSym` = `recSym`.get
      `setTagStmts`
      `nodeIdent`.children.add(`childNodeSym`)

proc emitFieldEncode(f: FieldSpec, sourceAccess, docIdent, nodeIdent: NimNode,
                     typeName: string): NimNode =
  let pathLit = newLit(typeName & "." & f.nimName)
  case f.kind
  of fkSkip:  newStmtList()
  of fkArg:   emitArgEncode(f, sourceAccess, docIdent, nodeIdent, pathLit)
  of fkAttr:  emitAttrEncode(f, sourceAccess, docIdent, nodeIdent, pathLit)
  of fkChild: emitChildEncode(f, sourceAccess, docIdent, nodeIdent)

macro deriveEncode(typ: typedesc): untyped =
  ## Emit a `kdlEncodeImpl` overload for `typ` (the symmetric
  ## counterpart to `deriveDecode`). Generated procedure walks a typed
  ## value and produces the equivalent `KdlNode`, with the configured
  ## `kdlReserved` tags carried over to value-level type annotations.
  ##
  ## Combined with the top-level `encode[T](v: T): string`, this closes
  ## round-trip for typed configs: `decode[T](encode(v))` produces a
  ## value equal to `v` for every type that round-trips losslessly
  ## through the underlying KDL grammar.
  ##
  ## Generated code is dumpable via `-d:dumpKdlGen`.
  let typSym =
    if typ.kind == nnkBracketExpr: typ[1]
    else: typ
  let typeImpl = typSym.getImpl
  if typeImpl.kind != nnkTypeDef:
    error("deriveEncode: argument is not a type definition", typ)
  let body = typeImpl[2]
  if body.kind != nnkObjectTy:
    error("deriveEncode: only object types are supported (v0); got " &
          $body.kind, typ)
  let recList = body[2]
  let shape = collectShape(recList)

  let vIdent = ident("v")
  let docIdent = ident("doc")
  let typeNameStr = $typSym       # Nim type name for error hint paths
  let nodeNameLit = newLit(extractNodeName(typSym))
  let typeReserved = extractTypeReserved(typSym)

  var procBody = newStmtList()
  let nodeSym = genSym(nskVar, "encNode")
  procBody.add quote do:
    var `nodeSym` = KdlNode(
      name: `docIdent`.interner.intern(`nodeNameLit`),
      typeAnnotation: InvalidInterned,
      entries: @[],
      children: @[],
      span: pointSpan(StartPosition))
  if typeReserved.len > 0:
    let tagLit = newLit(typeReserved)
    procBody.add quote do:
      `nodeSym`.typeAnnotation = `docIdent`.interner.intern(`tagLit`)

  let nodeIdent = nodeSym
  if not shape.hasVariant:
    for f in shape.shared:
      let sourceAccess = newDotExpr(vIdent, ident(f.nimName))
      procBody.add(emitFieldEncode(f, sourceAccess, docIdent, nodeIdent,
                                   typeNameStr))
  else:
    # Variant types: shared fields always encode; branch fields only
    # encode for the active discriminator.
    for f in shape.shared:
      let sourceAccess = newDotExpr(vIdent, ident(f.nimName))
      procBody.add(emitFieldEncode(f, sourceAccess, docIdent, nodeIdent,
                                   typeNameStr))
    let disc = shape.variant.disc
    let discAccess = newDotExpr(vIdent, ident(disc.nimName))
    procBody.add(emitFieldEncode(disc, discAccess, docIdent, nodeIdent,
                                 typeNameStr))
    let caseStmt = nnkCaseStmt.newTree(discAccess)
    for branch in shape.variant.branches:
      var bb = newStmtList()
      for f in branch.fields:
        let sourceAccess = newDotExpr(vIdent, ident(f.nimName))
        bb.add(emitFieldEncode(f, sourceAccess, docIdent, nodeIdent,
                               typeNameStr))
      if bb.len == 0:
        bb.add(newNimNode(nnkDiscardStmt).add(newEmptyNode()))
      caseStmt.add(nnkOfBranch.newTree(branch.discValue, bb))
    procBody.add(caseStmt)

  procBody.add quote do:
    ok[KdlNode, ParseError](`nodeSym`)

  let encodeProc = quote do:
    proc kdlEncodeImpl*(`vIdent`: `typ`,
                       `docIdent`: var KdlDoc):
        Result[KdlNode, ParseError] {.noSideEffect.} =
      `procBody`

  # --- Direct-buffer emit (cycle E.1+) -------------------------------
  # Walks the same `shape` and emits buf.add / appendFieldValue calls
  # directly into a caller-provided `var string`. Skips KdlNode + KdlDoc
  # construction entirely.
  #
  # Features supported in E.1 scope: kdlArg + kdlProp with primitive
  # types (string/int/float/bool/enum). Anything else (kdlChild,
  # variant, kdlReserved, Option[T]) falls back to the legacy KdlNode
  # path — body just delegates so the public encodeFrom[T] surface is
  # uniform across types; later slices replace the fallback per feature.
  let bufIdent = ident("buf")
  let indentIdent = ident("indent")
  var hasUnsupported = shape.hasVariant
  for f in shape.shared:
    # Option[T] supported only on kdlProp fields in E.4 scope. On kdlArg
    # (positional optional) the semantics get fuzzier; defer.
    if f.isOption and f.kind != fkAttr:
      hasUnsupported = true
    # Non-seq kdlChild (single-object nested) — needs a per-field child
    # call that doesn't iterate. Defer to a later slice; fall back today.
    if f.kind == fkChild and
       (f.typeNode.kind != nnkBracketExpr or
        f.typeNode.len < 1 or
        $f.typeNode[0] != "seq"):
      hasUnsupported = true
  var directBody = newStmtList()
  if hasUnsupported:
    # Delegate to legacy path for now (E.4 / E.6 add direct emit for
    # Option[T] and kdlReserved; until then, indent prefix happens here
    # too so nested children call sites stay correct).
    directBody.add quote do:
      var legacyDoc = newDoc()
      let nRes = kdlEncodeImpl(`vIdent`, legacyDoc)
      if nRes.isErr: return err[void, ParseError](nRes.getErr)
      legacyDoc.nodes.add(nRes.get)
      appendIndent(`bufIdent`, `indentIdent`)
      let s = kdlEncode.encode(legacyDoc, emPretty)
      # Legacy emit already includes trailing newline; strip-and-re-add
      # if our caller is nesting (indent > 0) — but for now just append.
      `bufIdent`.add(s)
      ok(void, ParseError)
  else:
    directBody.add quote do:
      appendIndent(`bufIdent`, `indentIdent`)
      `bufIdent`.add(`nodeNameLit`)
    # Args first (positional, in source order)
    for f in shape.shared:
      if f.kind != fkArg: continue
      let access = newDotExpr(vIdent, ident(f.nimName))
      directBody.add quote do:
        `bufIdent`.add(' ')
        appendFieldValue(`bufIdent`, `access`)
    # Props next (key=value). Option[T] props are conditional: only emit
    # when isSome. Non-Option props always emit. Fields with a
    # `kdlReserved: "tag"` pragma get a `(tag)` prefix on the value AND
    # run Layer-1 validation (validateReserved); failure short-circuits
    # the encode with peReservedTypeInvalid.
    for f in shape.shared:
      if f.kind != fkAttr: continue
      let access = newDotExpr(vIdent, ident(f.nimName))
      let keyLit = newLit(f.kdlName)
      let tagLit = newLit(f.expectedReserved)
      let hasTag = f.expectedReserved.len > 0
      # Build the (potentially validated, potentially tagged) emit body
      # for the value side of `key=value`.
      let getExpr = if f.isOption: newDotExpr(access, ident("get")) else: access
      var valueEmit = newStmtList()
      if hasTag:
        # Validate: construct a transient KdlValue to feed validateReserved.
        # Only fires for kdlReserved'd fields, which are rare on hot paths.
        valueEmit.add quote do:
          let tmpVal = newStringValue($(`getExpr`))
          let rcheck = validateReserved(`tagLit`, tmpVal)
          if rcheck.isErr: return err[void, ParseError](rcheck.getErr)
          `bufIdent`.add('('); `bufIdent`.add(`tagLit`); `bufIdent`.add(')')
      valueEmit.add quote do:
        appendFieldValue(`bufIdent`, `getExpr`)
      let emitProp = quote do:
        `bufIdent`.add(' ')
        appendIdent(`bufIdent`, `keyLit`)
        `bufIdent`.add('=')
        `valueEmit`
      if f.isOption:
        directBody.add quote do:
          if `access`.isSome:
            `emitProp`
      else:
        directBody.add(emitProp)
    # Children: emit `{` block with each child recursing at indent+1.
    # Skip the block entirely when ALL kdlChild fields are empty seqs
    # (matches legacy behavior of not emitting `{}` for absent children).
    var childFields: seq[FieldSpec] = @[]
    for f in shape.shared:
      if f.kind == fkChild: childFields.add(f)
    if childFields.len > 0:
      # Build a runtime "any non-empty?" predicate. For seq fields:
      # `v.f.len > 0`. For non-seq single-object kdlChild: always true
      # (the child is structurally present). v0 only supports seq.
      var anyNonEmpty: NimNode = newLit(false)
      for f in childFields:
        let access = newDotExpr(vIdent, ident(f.nimName))
        let lenExpr = quote do: `access`.len > 0
        anyNonEmpty = infix(anyNonEmpty, "or", lenExpr)
      directBody.add quote do:
        if `anyNonEmpty`:
          `bufIdent`.add(" {\n")
      for f in childFields:
        let access = newDotExpr(vIdent, ident(f.nimName))
        directBody.add quote do:
          for child in `access`:
            let cRes = kdlEncodeIntoImpl(child, `bufIdent`, `indentIdent` + 1)
            if cRes.isErr: return cRes
      directBody.add quote do:
        if `anyNonEmpty`:
          appendIndent(`bufIdent`, `indentIdent`)
          `bufIdent`.add("}\n")
        else:
          `bufIdent`.add('\n')
    else:
      directBody.add quote do:
        `bufIdent`.add('\n')
    directBody.add quote do:
      ok(void, ParseError)

  let encodeIntoProc = quote do:
    proc kdlEncodeIntoImpl*(`vIdent`: `typ`, `bufIdent`: var string,
                            `indentIdent`: int = 0):
        Result[void, ParseError] {.noSideEffect.} =
      `directBody`

  result = newStmtList(encodeProc, encodeIntoProc)
  when defined(dumpKdlGen):
    echo "=== kdlEncodeImpl for ", repr(typ), " ==="
    echo result.repr
    echo "==="

proc encodeNode*[T: object](v: T, doc: var KdlDoc):
                            Result[KdlNode, ParseError] =
  ## Render a typed value as a single `KdlNode`, ready to insert into
  ## `doc`'s top level (or as a child of an existing node). The
  ## low-level primitive: callers compose multi-node docs, mix typed
  ## values with manually-built nodes, or assemble fragments.
  ##
  ## `doc` is `var` because any string-typed entries (names, prop
  ## names, type annotations) need to be interned into it.
  ##
  ## Subject to Layer 1 `kdlReserved` validation: a typed value with a
  ## kdlReserved pragma whose content doesn't match its tag returns
  ## `Err(peReservedTypeInvalid, ...)`.
  ##
  ## `T` must be declared inside a `kdl:` block.
  mixin kdlEncodeImpl
  kdlEncodeImpl(v, doc)

proc encode*[T: object](v: T, mode = emPretty): Result[string, ParseError] =
  ## Render a typed value as KDL text. Default `mode` is `emPretty`
  ## (multi-line, indented) — the right default for the typical call
  ## site, which is constructing a value from scratch in Nim and
  ## emitting it. `emCompact` produces single-line, `;`-separated
  ## output. `emPreserve` falls through to canonical here because a
  ## freshly-constructed value has no sourceText to preserve.
  ##
  ## Subject to Layer 1 `kdlReserved` validation — see `encodeNode`.
  ##
  ## **Error diagnostics:** the returned ParseError's `span` is
  ## synthetic (`pointSpan(StartPosition)`) — there's no source file
  ## to anchor it to. The useful diagnostic lives in `hint`, which
  ## is prefixed with `TypeName.fieldName` so callers can point
  ## directly at the offending field.
  ##
  ## `T` must be declared inside a `kdl:` block.
  mixin kdlEncodeImpl
  var doc = newDoc()
  let nRes = encodeNode(v, doc)
  if nRes.isErr:
    return err[string, ParseError](nRes.getErr)
  doc.nodes.add(nRes.get)
  ok[string, ParseError](kdlEncode.encode(doc, mode))

proc encodeFrom*[T: object](v: T): Result[string, ParseError] =
  ## Typed-direct encode (cycle E). Skips KdlNode + KdlDoc construction;
  ## the macro-emitted `kdlEncodeIntoImpl` writes KDL bytes straight into
  ## a string buffer in one pass. Symmetric with `parseInto[T]` on the
  ## decode side.
  ##
  ## Output matches `encode(v, emPretty).get` byte-for-byte. Returns Err
  ## on kdlReserved validation failure (mirrors `encode[T]`).
  ##
  ## `T` must be declared inside a `kdl:` block.
  mixin kdlEncodeIntoImpl
  var buf = newStringOfCap(64)
  let r = kdlEncodeIntoImpl(v, buf)
  if r.isErr: return err[string, ParseError](r.getErr)
  ok[string, ParseError](buf)

proc encodeFrom*[T: object](vs: seq[T]): Result[string, ParseError] =
  ## seq[T] variant — each element becomes one top-level node, newline-
  ## separated. Symmetric with `parseInto[seq[T]]`. Stops at the first
  ## kdlReserved validation failure.
  ##
  ## `T` must be declared inside a `kdl:` block.
  mixin kdlEncodeIntoImpl
  var buf = newStringOfCap(64 * vs.len + 32)
  for v in vs:
    let r = kdlEncodeIntoImpl(v, buf)
    if r.isErr: return err[string, ParseError](r.getErr)
  ok[string, ParseError](buf)

proc encode*[T](vs: seq[T], mode = emPretty): Result[string, ParseError] =
  ## Render a sequence of typed values as KDL text: each element
  ## becomes one top-level node. Symmetric with `decode[seq[T]]`.
  ## Stops at the first `kdlReserved` validation failure.
  ##
  ## `T` must be declared inside a `kdl:` block.
  mixin kdlEncodeImpl
  var doc = newDoc()
  for v in vs:
    let nRes = encodeNode(v, doc)
    if nRes.isErr:
      return err[string, ParseError](nRes.getErr)
    doc.nodes.add(nRes.get)
  ok[string, ParseError](kdlEncode.encode(doc, mode))

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
  ## in Nim's VM when invoked in a `const` context (which the
  ## `compileTimeDecoded` binding forces). A `when isErr` gate then
  ## fires `{.error: ...}` so a malformed file fails the **build**, not
  ## just the runtime `.get()` call — the whole point of moving the
  ## work to compile time. The constructed error message names the
  ## file path so the diagnostic is actionable.
  let resolved =
    if isAbsolute(path): path
    else: callerFile.parentDir / path
  let body = staticRead(resolved)
  let bodyLit = newLit(body)
  let pathLit = newLit(resolved)
  let errPrefix = newLit("embed[T] parse failure in " & resolved & ": ")
  result = quote do:
    const compileTimeDecoded = decode[`T`](`bodyLit`, `pathLit`)
    when compileTimeDecoded.isErr:
      const compileTimeErrMsg = `errPrefix` & compileTimeDecoded.getErr.hint
      {.error: compileTimeErrMsg.}
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
  ## **Compile-time guarantees:**
  ##   - Missing or unreadable file → build fails (via `staticRead`).
  ##   - Malformed KDL or decode-type-mismatch → build fails with a
  ##     `{.error: ...}` carrying the file path and the parse hint.
  ##
  ## Consequence: the returned `Result[T, ParseError]` is *always*
  ## `Ok` at runtime in a successfully-built binary. The Result shape
  ## is preserved for compositional ergonomics (`embed[T](...).get`)
  ## and for the rare case where a future variant wants to surrender
  ## the compile-time guarantee. If you'd rather have `T` directly
  ## and panic on the impossible runtime-Err, append `.get` at the
  ## call site.
  embedAux(T, path, instantiationInfo(fullPaths = true).filename)

proc decode*[T](source: string,
                sourcePath: string = "<input>"): Result[T, ParseError]
    {.noSideEffect.} =
  ## Parse `source` as a KDL document and decode into `T`.
  ##
  ## - If `T = seq[U]`, decodes every top-level node named per U's
  ##   `kdlNode` pragma.
  ## - Otherwise, finds the single top-level node named per T's
  ##   `kdlNode` pragma and decodes it.
  ##
  ## `T` (or `U` if `T = seq[U]`) must be declared inside a `kdl:`
  ## block, which generates the visitor machinery this dispatches to.
  ##
  ## Single typed-decode entry point. Internally routes to the visitor
  ## emitted by the `kdl:` block — same fast path that `parseInto[T]`
  ## used during the transitional cycle.
  mixin kdlBuildVisitor, kdlBuildVisitorSeq
  when T is seq:
    type Elem = typeof(default(T)[0])
    kdlBuildVisitorSeq(Elem, source, sourcePath)
  else:
    kdlBuildVisitor(T, source, sourcePath)

proc decodeAll*[T](source: string,
                   sourcePath: string = "<input>"):
                   tuple[value: T, errors: seq[ParseError]] {.noSideEffect.} =
  ## Multi-error variant of `decode[T]`. Aggregates parse-time errors
  ## (via `parser.parseAll`) AND decode-time errors at the **node**
  ## boundary: each top-level node either decodes fully or contributes
  ## exactly one error; siblings keep going. Mirrors `parseAll`'s
  ## tuple-shaped contract at the typed layer.
  ##
  ## Caller contract:
  ##   - `errors.len == 0`              → `value` is fully valid.
  ##   - `errors.len > 0`, seq[T] case  → `value` holds the elements
  ##                                       whose nodes decoded; failed
  ##                                       nodes are skipped.
  ##   - `errors.len > 0`, single T     → `value` is left default-init
  ##                                       (caller should not rely on it).
  ##
  ## Granularity is deliberately at the node, not the field: rebuilding
  ## every primitive decoder to accumulate per-field errors is a much
  ## larger surface change for marginal user value (a mis-shaped node
  ## is typically re-edited then re-checked). If per-field becomes
  ## necessary, it'll arrive as an additive `granularity = gField`
  ## parameter — not a contract break.
  mixin kdlBuildVisitorAll, kdlBuildVisitorAllSeq
  when T is seq:
    type Elem = typeof(default(T)[0])
    kdlBuildVisitorAllSeq(Elem, source, sourcePath)
  else:
    kdlBuildVisitorAll(T, source, sourcePath)


# ---------------------------------------------------------------------------
# deriveVisitor — typed-direct path (issue #1)
# ---------------------------------------------------------------------------
#
# Generates a hidden builder type + the six visitor methods needed by
# typed_parser.parseWith. Emits a `kdlBuildVisitor` overload so the
# generic `parseInto[T]` proc resolves to this type's machinery via
# `mixin`.
#
# Cycle 2 scope: flat objects only, kdlArg + kdlProp fields with
# string/int/bool types and default values. Children blocks (kdlChild)
# come in cycle 7; variants come later if needed.

import ./typed_parser
import ./lexer
import ./numlit

# ---------------------------------------------------------------------------
# Variant visitor — atomic-construction streaming decoder for case objects.
# ---------------------------------------------------------------------------
#
# The flat-shape visitor can assign fields directly to `result.<field>`
# as they arrive. Variants can't: Nim's case-object discipline forbids
# mutating a branch field unless the discriminator already names that
# branch, and re-setting the discriminator wipes all branch fields. So
# the variant visitor decodes everything into LOCALS on the builder, then
# at visitEndNode time constructs the result with one `T(kind: ..., ...)`
# object constructor — atomic per Q3(ii) atomicity in the H9 grilling.
#
# Property dispatch is statically per-key: each KDL prop key maps to AT
# MOST one Nim field across the whole type (Nim enforces field-name
# uniqueness across branches), so visitProp writes to a specific local
# without needing the discriminator to be known yet. Wrong-branch props
# are still written to their local — they're ignored at construction
# time when the active branch's constructor doesn't reference them.
#
# Arg dispatch is by index: shared kdlArgs come first, then the
# discriminator (if disc is kdlArg), then branch kdlArgs. By KDL source
# ordering, args arrive in idx order, so when a branch arg arrives the
# disc is already set. We still defensively error if it isn't.
#
# Restrictions (raise clear runtime errors if hit):
#   - kdlChild on any shared or branch field: not implemented
#   - kdlProp discriminator: not implemented (the disc could arrive after
#     branch props, requiring buffering; punt until needed in practice)
proc emitVariantVisitor(typ, typSym: NimNode, shape: TypeShape): NimNode =
  let typName = $typSym
  let nodeName = extractNodeName(typSym)
  let builderName = ident(typName & "VBuilder")
  let seqBuilderName = ident(typName & "VBuilderSeq")
  let bIdent = ident("b")
  let tokIdent = ident("tok")
  let streamIdent = ident("stream")
  let keyStrIdent = ident("keyStr")
  let nameStrIdent = ident("nameStr")
  let idxIdent = ident("idx")
  let entrySpanIdent = ident("entrySpan")
  let nodeFullSpanIdent = ident("nodeFullSpan")
  let spanIdent = ident("nodeSpan")
  let annoStrIdent = ident("annoStr")
  let annoSpanIdent = ident("annoSpan")

  let typNameLit = newLit(typName)
  let disc = shape.variant.disc
  let discNimIdent = ident(disc.nimName)
  let discKdlNameLit = newLit(disc.kdlName)
  let discTypeNode = disc.typeNode
  let discLocalIdent = ident(disc.nimName & "_local")
  let discSetIdent = ident(disc.nimName & "_set")

  # Scope guards. Children + kdlProp disc unsupported in this cycle.
  for f in shape.shared:
    if f.kind == fkChild:
      return quote do:
        proc kdlBuildVisitor(_: typedesc[`typSym`], source: string,
                             sourcePath: string):
            Result[`typSym`, ParseError] =
          err[`typSym`, ParseError](initError(peTypeMismatch,
            pointSpan(StartPosition),
            "parseInto[" & `typNameLit` & "]: variant types with " &
            "kdlChild fields are not supported by the typed-direct " &
            "path yet; use decode[" & `typNameLit` & "]."))
        proc kdlBuildVisitorSeq(_: typedesc[`typSym`], source: string,
                                sourcePath: string):
            Result[seq[`typSym`], ParseError] =
          err[seq[`typSym`], ParseError](initError(peTypeMismatch,
            pointSpan(StartPosition),
            "parseInto[seq[" & `typNameLit` & "]]: variant types " &
            "with kdlChild fields are not supported by the typed-" &
            "direct path yet; use decode[seq[" & `typNameLit` & "]]."))
  for branch in shape.variant.branches:
    for f in branch.fields:
      if f.kind == fkChild:
        return quote do:
          proc kdlBuildVisitor(_: typedesc[`typSym`], source: string,
                               sourcePath: string):
              Result[`typSym`, ParseError] =
            err[`typSym`, ParseError](initError(peTypeMismatch,
              pointSpan(StartPosition),
              "parseInto[" & `typNameLit` & "]: variant branches " &
              "with kdlChild fields are not supported by the typed-" &
              "direct path yet; use decode[" & `typNameLit` & "]."))
          proc kdlBuildVisitorSeq(_: typedesc[`typSym`], source: string,
                                  sourcePath: string):
              Result[seq[`typSym`], ParseError] =
            err[seq[`typSym`], ParseError](initError(peTypeMismatch,
              pointSpan(StartPosition),
              "parseInto[seq[" & `typNameLit` & "]]: variant branches " &
              "with kdlChild fields are not supported by the typed-" &
              "direct path yet; use decode[seq[" & `typNameLit` & "]]."))
  if disc.kind == fkAttr:
    return quote do:
      proc kdlBuildVisitor(_: typedesc[`typSym`], source: string,
                           sourcePath: string):
          Result[`typSym`, ParseError] =
        err[`typSym`, ParseError](initError(peTypeMismatch,
          pointSpan(StartPosition),
          "parseInto[" & `typNameLit` & "]: kdlProp discriminator on " &
          "variants is not supported by the typed-direct path yet " &
          "(branch props could arrive before the discriminator). Use " &
          "decode[" & `typNameLit` & "] or switch the discriminator " &
          "to a kdlArg position."))
      proc kdlBuildVisitorSeq(_: typedesc[`typSym`], source: string,
                              sourcePath: string):
          Result[seq[`typSym`], ParseError] =
        err[seq[`typSym`], ParseError](initError(peTypeMismatch,
          pointSpan(StartPosition),
          "parseInto[seq[" & `typNameLit` & "]]: kdlProp discriminator " &
          "on variants not yet supported; use decode[seq[" &
          `typNameLit` & "]]."))

  # ---------- Builder type ----------
  # Shared field locals + seen flags. Discriminator local + set flag.
  # Per-branch field locals + seen flags, prefixed by branch discValue's
  # identifier so two branches with same-named fields stay separate.
  let builderFields = newNimNode(nnkRecList)
  builderFields.add newIdentDefs(ident("result"), typSym)
  builderFields.add newIdentDefs(ident("nodeSpan"), ident("Span"))
  builderFields.add newIdentDefs(ident("pendingValueAnno"), ident("string"))
  builderFields.add newIdentDefs(ident("pendingNodeAnno"), ident("string"))

  for f in shape.shared:
    builderFields.add newIdentDefs(ident(f.nimName & "_local"), f.typeNode)
    builderFields.add newIdentDefs(ident(f.nimName & "_seen"), ident("bool"))
  builderFields.add newIdentDefs(discLocalIdent, discTypeNode)
  builderFields.add newIdentDefs(discSetIdent, ident("bool"))
  for branch in shape.variant.branches:
    let branchPrefix = $branch.discValue
    for f in branch.fields:
      builderFields.add newIdentDefs(
        ident(branchPrefix & "_" & f.nimName & "_local"), f.typeNode)
      builderFields.add newIdentDefs(
        ident(branchPrefix & "_" & f.nimName & "_seen"), ident("bool"))

  let builderType = newNimNode(nnkTypeSection).add(
    newNimNode(nnkTypeDef).add(builderName, newEmptyNode(),
      newNimNode(nnkObjectTy).add(newEmptyNode(), newEmptyNode(),
        builderFields)))

  # ---------- visitBeginNode ----------
  # Verify node name matches, then apply field defaults to all shared
  # and branch field locals so absent-optional fields land at the right
  # value without per-field default code paths at end-time.
  var defaultsBody = newStmtList()
  for f in shape.shared:
    if f.defaultExpr.kind != nnkEmpty:
      let loc = ident(f.nimName & "_local")
      let dExpr = f.defaultExpr
      defaultsBody.add quote do:
        `bIdent`.`loc` = `dExpr`
  for branch in shape.variant.branches:
    let branchPrefix = $branch.discValue
    for f in branch.fields:
      if f.defaultExpr.kind != nnkEmpty:
        let loc = ident(branchPrefix & "_" & f.nimName & "_local")
        let dExpr = f.defaultExpr
        defaultsBody.add quote do:
          `bIdent`.`loc` = `dExpr`

  let nodeLit = newLit(nodeName)
  let typeReserved = extractTypeReserved(typSym)
  let typeReservedLit = newLit(typeReserved)
  let typeAnnoCheckBody =
    if typeReserved.len > 0:
      quote do:
        if `bIdent`.pendingNodeAnno.len == 0:
          return err[void, ParseError](initError(peTypeReservedMismatch,
            `spanIdent`,
            "type expects (" & `typeReservedLit` & ") tag on its node " &
            "but source has no annotation"))
        if `bIdent`.pendingNodeAnno != `typeReservedLit`:
          return err[void, ParseError](initError(peTypeReservedMismatch,
            `spanIdent`,
            "type expects (" & `typeReservedLit` & ") tag on its node " &
            "but source has (" & `bIdent`.pendingNodeAnno & ")"))
        `bIdent`.pendingNodeAnno = ""
    else:
      newStmtList()
  let beginNodeProc = quote do:
    proc visitBeginNode(`bIdent`: var `builderName`,
                   `nameStrIdent`: openArray[char],
                   `spanIdent`: Span):
        Result[void, ParseError] {.noSideEffect.} =
      `bIdent`.nodeSpan = `spanIdent`
      var match = `nameStrIdent`.len == `nodeLit`.len
      if match:
        for i in 0 ..< `nameStrIdent`.len:
          if `nameStrIdent`[i] != `nodeLit`[i]:
            match = false; break
      if not match:
        return err[void, ParseError](initError(peTypeMismatch,
          `spanIdent`, "expected node `" & `nodeLit` & "`"))
      `typeAnnoCheckBody`
      `defaultsBody`
      ok(void, ParseError)

  # ---------- Per-field primitive decode helper ----------
  # Returns code that decodes `tok` (current token) into a local of the
  # given primitive type, then assigns into `targetIdent`. Includes
  # reserved-tag validation that mirrors the flat-shape visitor.
  proc emitPrimitiveDecode(f: FieldSpec, targetIdent: NimNode,
                           seenFlagIdent: NimNode): NimNode =
    let primType = $f.typeNode
    let fieldLabel = newLit(typName & "." & f.nimName)
    let kdlNameLit = newLit(f.kdlName)
    let expectedReservedLit = newLit(f.expectedReserved)
    proc validateBlock(decodedExpr: NimNode, kvCtor: string): NimNode =
      let ctorIdent = ident(kvCtor)
      let valSym = genSym(nskLet, "vKv_" & f.nimName)
      let rcheckSym = genSym(nskLet, "vRc_" & f.nimName)
      quote do:
        if `bIdent`.pendingValueAnno.len == 0:
          if `expectedReservedLit`.len > 0:
            return err[void, ParseError](initError(peTypeReservedMismatch,
              `tokIdent`.span,
              "field `" & `kdlNameLit` & "` expects (" & `expectedReservedLit` &
              ") tag but source value has no annotation"))
        else:
          if `expectedReservedLit`.len > 0 and
             `bIdent`.pendingValueAnno != `expectedReservedLit`:
            return err[void, ParseError](initError(peTypeReservedMismatch,
              `tokIdent`.span,
              "field `" & `kdlNameLit` & "` expects (" & `expectedReservedLit` &
              ") tag but source has (" & `bIdent`.pendingValueAnno & ")"))
          let `valSym` = `ctorIdent`(`decodedExpr`, `tokIdent`.span)
          let `rcheckSym` = validateReserved(`bIdent`.pendingValueAnno, `valSym`)
          if `rcheckSym`.isErr:
            return err[void, ParseError](`rcheckSym`.getErr)
          `bIdent`.pendingValueAnno = ""

    if f.typeIsEnum:
      let innerT = f.typeNode
      let strSym = genSym(nskLet, "enumStr")
      let outSym = genSym(nskVar, "enumOut")
      let decodeBlock = quote do:
        var `outSym`: `innerT`
        if not decodeEnumFromString(`outSym`, `strSym`):
          return err[void, ParseError](initError(peTypeDiscriminatorBad,
            `tokIdent`.span, "invalid enum value for `" &
            `fieldLabel` & "`: '" & `strSym` & "'"))
      let v = validateBlock(strSym, "newStringValue")
      let body = newStmtList()
      body.add(decodeBlock)
      body.add(v)
      body.add quote do:
        `bIdent`.`targetIdent` = `outSym`
        `bIdent`.`seenFlagIdent` = true
      return quote do:
        case `tokIdent`.kind
        of tkString:
          let `strSym` = `streamIdent`.stringPayloads[`tokIdent`.strIdx]
          `body`
        of tkRawString:
          let `strSym` = `streamIdent`.rawStringPayloads[`tokIdent`.rawIdx]
          `body`
        of tkIdent:
          let s0 = `tokIdent`.span.start.offset
          let s1 = `tokIdent`.span.finish.offset - 1
          let `strSym` = `streamIdent`.source[s0 .. s1]
          `body`
        else:
          return err[void, ParseError](initError(peTypeDiscriminatorBad,
            `tokIdent`.span, "expected string or bareword for `" &
            `fieldLabel` & "`"))

    case primType
    of "string":
      let strSym = genSym(nskLet, "sv")
      let v = validateBlock(strSym, "newStringValue")
      quote do:
        case `tokIdent`.kind
        of tkString:
          let `strSym` = `streamIdent`.stringPayloads[`tokIdent`.strIdx]
          `v`
          `bIdent`.`targetIdent` = `strSym`
          `bIdent`.`seenFlagIdent` = true
        of tkRawString:
          let `strSym` = `streamIdent`.rawStringPayloads[`tokIdent`.rawIdx]
          `v`
          `bIdent`.`targetIdent` = `strSym`
          `bIdent`.`seenFlagIdent` = true
        of tkIdent:
          let s0 = `tokIdent`.span.start.offset
          let s1 = `tokIdent`.span.finish.offset - 1
          let `strSym` = `streamIdent`.source[s0 .. s1]
          `v`
          `bIdent`.`targetIdent` = `strSym`
          `bIdent`.`seenFlagIdent` = true
        else:
          return err[void, ParseError](initError(peTypeMismatch,
            `tokIdent`.span, "expected string for `" & `fieldLabel` & "`"))
    of "int":
      let intSym = genSym(nskLet, "iv")
      let v = validateBlock(intSym, "newIntValue")
      quote do:
        if `tokIdent`.kind != tkNumber:
          return err[void, ParseError](initError(peTypeMismatch,
            `tokIdent`.span, "expected int for `" & `fieldLabel` & "`"))
        let n = `streamIdent`.numberPayloads[`tokIdent`.numIdx]
        let d = decodeIntFromToken(n, `tokIdent`.span)
        if d.isErr: return err[void, ParseError](d.getErr)
        let `intSym` = int(d.get)
        `v`
        `bIdent`.`targetIdent` = `intSym`
        `bIdent`.`seenFlagIdent` = true
    of "bool":
      let boolSym = genSym(nskLet, "bv")
      let v = validateBlock(boolSym, "newBoolValue")
      quote do:
        if `tokIdent`.kind != tkKeyword:
          return err[void, ParseError](initError(peTypeMismatch,
            `tokIdent`.span, "expected bool for `" & `fieldLabel` & "`"))
        let `boolSym` = (`tokIdent`.keyword == kwTrue)
        `v`
        `bIdent`.`targetIdent` = `boolSym`
        `bIdent`.`seenFlagIdent` = true
    of "float", "float64":
      let fltSym = genSym(nskLet, "fv")
      let v = validateBlock(fltSym, "newFloatValue")
      quote do:
        if `tokIdent`.kind != tkNumber:
          return err[void, ParseError](initError(peTypeMismatch,
            `tokIdent`.span, "expected number for `" & `fieldLabel` & "`"))
        let n = `streamIdent`.numberPayloads[`tokIdent`.numIdx]
        let `fltSym` =
          if looksLikeFloat(n):
            let d = decodeFloatFromToken(n, `tokIdent`.span)
            if d.isErr: return err[void, ParseError](d.getErr)
            d.get
          else:
            let d = decodeIntFromToken(n, `tokIdent`.span)
            if d.isErr: return err[void, ParseError](d.getErr)
            float(d.get)
        `v`
        `bIdent`.`targetIdent` = `fltSym`
        `bIdent`.`seenFlagIdent` = true
    else:
      let primLit = newLit(primType)
      quote do:
        return err[void, ParseError](initError(peTypeMismatch,
          `tokIdent`.span, "unsupported field type `" & `primLit` &
          "` for `" & `fieldLabel` & "`"))

  # ---------- visitArg ----------
  # Case on positional index. Shared args dispatch directly. Disc arg
  # decodes into disc local + sets disc_set. Branch args check disc_set,
  # case on disc value, then per-branch decode.
  var argCase = newNimNode(nnkCaseStmt).add(idxIdent)
  var sharedArgIdx = 0
  for f in shape.shared:
    if f.kind == fkArg:
      let lit = newLit(sharedArgIdx)
      let body = emitPrimitiveDecode(
        f, ident(f.nimName & "_local"), ident(f.nimName & "_seen"))
      argCase.add(newNimNode(nnkOfBranch).add(lit).add(body))
      inc sharedArgIdx
  if disc.kind == fkArg:
    let lit = newLit(disc.argIndex)
    let body = emitPrimitiveDecode(disc, discLocalIdent, discSetIdent)
    argCase.add(newNimNode(nnkOfBranch).add(lit).add(body))
  # Branch args: group by argIndex across branches (different branches
  # may share the same idx with different types — case-on-disc inside).
  var branchArgByIdx: Table[int, seq[(NimNode, FieldSpec)]]
  for branch in shape.variant.branches:
    for f in branch.fields:
      if f.kind == fkArg:
        if not branchArgByIdx.hasKey(f.argIndex):
          branchArgByIdx[f.argIndex] = @[]
        branchArgByIdx[f.argIndex].add((branch.discValue, f))
  for idx, perBranch in branchArgByIdx.pairs:
    let lit = newLit(idx)
    var discCase = newNimNode(nnkCaseStmt).add(quote do: `bIdent`.`discLocalIdent`)
    for (discValue, f) in perBranch:
      let branchPrefix = $discValue
      let body = emitPrimitiveDecode(
        f,
        ident(branchPrefix & "_" & f.nimName & "_local"),
        ident(branchPrefix & "_" & f.nimName & "_seen"))
      discCase.add(newNimNode(nnkOfBranch).add(discValue).add(body))
    # Branches without an arg at this idx: silently drop (unknown arg).
    discCase.add(newNimNode(nnkElse).add quote do:
      discard)
    argCase.add(newNimNode(nnkOfBranch).add(lit).add quote do:
      if not `bIdent`.`discSetIdent`:
        return err[void, ParseError](initError(peTypeMissingRequired,
          `tokIdent`.span,
          "branch positional arg arrived before discriminator `" &
          `discKdlNameLit` & "` was set"))
      `discCase`)
  # Unknown arg indices fall through to a no-op so we mirror the
  # AST-walk's lenient handling of extra args.
  argCase.add(newNimNode(nnkElse).add quote do:
    discard)
  let argProc = quote do:
    proc visitArg(`bIdent`: var `builderName`, `idxIdent`: int,
             `tokIdent`: Token, `streamIdent`: TokenStream,
             `entrySpanIdent`: Span):
        Result[void, ParseError] {.noSideEffect.} =
      `argCase`
      ok(void, ParseError)

  # ---------- visitProp ----------
  # Case on key string. Each key resolves to AT MOST one Nim field across
  # the whole type (compiler-enforced). Branch props always write to
  # their local; wrong-branch writes are harmless because the active
  # branch's constructor ignores them.
  var propCase = newNimNode(nnkCaseStmt).add(quote do:
    openArrayToString(`keyStrIdent`))
  for f in shape.shared:
    if f.kind == fkAttr:
      let kdlLit = newLit(f.kdlName)
      let body = emitPrimitiveDecode(
        f, ident(f.nimName & "_local"), ident(f.nimName & "_seen"))
      propCase.add(newNimNode(nnkOfBranch).add(kdlLit).add(body))
  for branch in shape.variant.branches:
    let branchPrefix = $branch.discValue
    for f in branch.fields:
      if f.kind == fkAttr:
        let kdlLit = newLit(f.kdlName)
        let body = emitPrimitiveDecode(
          f,
          ident(branchPrefix & "_" & f.nimName & "_local"),
          ident(branchPrefix & "_" & f.nimName & "_seen"))
        propCase.add(newNimNode(nnkOfBranch).add(kdlLit).add(body))
  # Unknown prop keys: silently drop (matches AST-walk behavior and the
  # test_variant expectation that off-branch keys are ignored).
  propCase.add(newNimNode(nnkElse).add quote do:
    discard)
  let propProc = quote do:
    proc visitProp(`bIdent`: var `builderName`,
              `keyStrIdent`: openArray[char],
              `tokIdent`: Token, `streamIdent`: TokenStream,
              `entrySpanIdent`: Span):
        Result[void, ParseError] {.noSideEffect.} =
      `propCase`
      ok(void, ParseError)

  # ---------- visitValueTypeAnno + visitNodeTypeAnno ----------
  let valueAnnoProc = quote do:
    proc visitValueTypeAnno(`bIdent`: var `builderName`,
                            `annoStrIdent`: openArray[char],
                            `annoSpanIdent`: Span):
        Result[void, ParseError] {.noSideEffect.} =
      `bIdent`.pendingValueAnno = openArrayToString(`annoStrIdent`)
      ok(void, ParseError)
    proc visitNodeTypeAnno(`bIdent`: var `builderName`,
                           `annoStrIdent`: openArray[char],
                           `annoSpanIdent`: Span):
        Result[void, ParseError] {.noSideEffect.} =
      `bIdent`.pendingNodeAnno = openArrayToString(`annoStrIdent`)
      ok(void, ParseError)

  # ---------- visitEndNode ----------
  # Discriminator required-check → case-on-disc → per-branch required-
  # field check + atomic object construction.
  var endCase = newNimNode(nnkCaseStmt).add(quote do:
    `bIdent`.`discLocalIdent`)
  proc requiredMsg(f: FieldSpec): NimNode =
    case f.kind
    of fkArg:  newLit("missing required positional arg " & $f.argIndex &
                      " ('" & f.kdlName & "')")
    of fkAttr: newLit("missing required property '" & f.kdlName & "'")
    of fkChild: newLit("missing required child node '" & f.kdlName & "'")
    of fkSkip: newLit("")  # unreachable: skip fields aren't required
  for branch in shape.variant.branches:
    let branchPrefix = $branch.discValue
    var branchBody = newStmtList()
    # Required-field checks: shared first, then branch. Wording mirrors
    # the AST-walk path's emitArgDecode / emitAttrDecode emit so the
    # error hint is identical across both decode paths.
    for f in shape.shared:
      if f.defaultExpr.kind == nnkEmpty:
        let seenFlag = ident(f.nimName & "_seen")
        let msgLit = requiredMsg(f)
        branchBody.add quote do:
          if not `bIdent`.`seenFlag`:
            return err[void, ParseError](initError(peTypeMissingRequired,
              `bIdent`.nodeSpan, `msgLit`))
    for f in branch.fields:
      if f.defaultExpr.kind == nnkEmpty:
        let seenFlag = ident(branchPrefix & "_" & f.nimName & "_seen")
        let msgLit = requiredMsg(f)
        branchBody.add quote do:
          if not `bIdent`.`seenFlag`:
            return err[void, ParseError](initError(peTypeMissingRequired,
              `bIdent`.nodeSpan, `msgLit`))
    # Atomic construction.
    let construction = nnkObjConstr.newTree(typSym)
    construction.add(nnkExprColonExpr.newTree(discNimIdent, branch.discValue))
    for f in shape.shared:
      let loc = ident(f.nimName & "_local")
      construction.add(nnkExprColonExpr.newTree(
        ident(f.nimName), quote do: `bIdent`.`loc`))
    for f in branch.fields:
      let loc = ident(branchPrefix & "_" & f.nimName & "_local")
      construction.add(nnkExprColonExpr.newTree(
        ident(f.nimName), quote do: `bIdent`.`loc`))
    branchBody.add quote do:
      `bIdent`.result = `construction`
    endCase.add(newNimNode(nnkOfBranch).add(branch.discValue).add(branchBody))

  let endNodeProc = quote do:
    proc visitBeginChildren(`bIdent`: var `builderName`):
        Result[void, ParseError] {.noSideEffect.} =
      ok(void, ParseError)
    proc visitEndChildren(`bIdent`: var `builderName`):
        Result[void, ParseError] {.noSideEffect.} =
      ok(void, ParseError)
    proc visitEndNode(`bIdent`: var `builderName`, `nodeFullSpanIdent`: Span):
        Result[void, ParseError] {.noSideEffect.} =
      if not `bIdent`.`discSetIdent`:
        return err[void, ParseError](initError(peTypeMissingRequired,
          `bIdent`.nodeSpan,
          "required discriminator `" & `typNameLit` & "." &
          `discKdlNameLit` & "` was not set"))
      `endCase`
      ok(void, ParseError)

  let kvpProc = quote do:
    proc kdlBuildVisitor(_: typedesc[`typSym`], source: string,
                         sourcePath: string): Result[`typSym`, ParseError] =
      var `bIdent` = `builderName`()
      let r = parseWith(source, `bIdent`, sourcePath)
      if r.isErr: return err[`typSym`, ParseError](r.getErr)
      ok[`typSym`, ParseError](`bIdent`.result)

  # ---------- Seq wrapper ----------
  let seqBuilderType = quote do:
    type `seqBuilderName` = object
      results: seq[`typSym`]
      cur: `builderName`
      pendingNodeAnno: string
  let seqWrapProcs = quote do:
    proc visitBeginNode(`bIdent`: var `seqBuilderName`,
                   `nameStrIdent`: openArray[char],
                   `spanIdent`: Span):
        Result[void, ParseError] {.noSideEffect.} =
      `bIdent`.cur = `builderName`()
      `bIdent`.cur.pendingNodeAnno = `bIdent`.pendingNodeAnno
      `bIdent`.pendingNodeAnno = ""
      visitBeginNode(`bIdent`.cur, `nameStrIdent`, `spanIdent`)
    proc visitArg(`bIdent`: var `seqBuilderName`, `idxIdent`: int,
             `tokIdent`: Token, `streamIdent`: TokenStream,
             `entrySpanIdent`: Span):
        Result[void, ParseError] {.noSideEffect.} =
      visitArg(`bIdent`.cur, `idxIdent`, `tokIdent`, `streamIdent`,
               `entrySpanIdent`)
    proc visitProp(`bIdent`: var `seqBuilderName`,
              `keyStrIdent`: openArray[char],
              `tokIdent`: Token, `streamIdent`: TokenStream,
              `entrySpanIdent`: Span):
        Result[void, ParseError] {.noSideEffect.} =
      visitProp(`bIdent`.cur, `keyStrIdent`, `tokIdent`, `streamIdent`,
                `entrySpanIdent`)
    proc visitValueTypeAnno(`bIdent`: var `seqBuilderName`,
                            `annoStrIdent`: openArray[char],
                            `annoSpanIdent`: Span):
        Result[void, ParseError] {.noSideEffect.} =
      visitValueTypeAnno(`bIdent`.cur, `annoStrIdent`, `annoSpanIdent`)
    proc visitNodeTypeAnno(`bIdent`: var `seqBuilderName`,
                           `annoStrIdent`: openArray[char],
                           `annoSpanIdent`: Span):
        Result[void, ParseError] {.noSideEffect.} =
      `bIdent`.pendingNodeAnno = openArrayToString(`annoStrIdent`)
      ok(void, ParseError)
    proc visitBeginChildren(`bIdent`: var `seqBuilderName`):
        Result[void, ParseError] {.noSideEffect.} =
      visitBeginChildren(`bIdent`.cur)
    proc visitEndChildren(`bIdent`: var `seqBuilderName`):
        Result[void, ParseError] {.noSideEffect.} =
      visitEndChildren(`bIdent`.cur)
    proc visitEndNode(`bIdent`: var `seqBuilderName`, `nodeFullSpanIdent`: Span):
        Result[void, ParseError] {.noSideEffect.} =
      let r = visitEndNode(`bIdent`.cur, `nodeFullSpanIdent`)
      if r.isErr: return r
      `bIdent`.results.add(`bIdent`.cur.result)
      ok(void, ParseError)
  let kvpSeqProc = quote do:
    proc kdlBuildVisitorSeq(_: typedesc[`typSym`], source: string,
                            sourcePath: string):
        Result[seq[`typSym`], ParseError] =
      var sb = `seqBuilderName`()
      let r = parseDocumentWith(source, sb, sourcePath)
      if r.isErr: return err[seq[`typSym`], ParseError](r.getErr)
      ok[seq[`typSym`], ParseError](sb.results)
  let nodeNameLit = newLit(nodeName)
  let kvpAllSeqProc = quote do:
    proc kdlBuildVisitorAllSeq(_: typedesc[`typSym`], source: string,
                               sourcePath: string):
        tuple[value: seq[`typSym`], errors: seq[ParseError]] =
      var sb: `seqBuilderName`
      var parserErrs: seq[ParseError]
      discard parseDocumentWith(source, sb, sourcePath, addr parserErrs)
      (value: sb.results, errors: parserErrs)
  let kvpAllProc = quote do:
    proc kdlBuildVisitorAll(_: typedesc[`typSym`], source: string,
                            sourcePath: string):
        tuple[value: `typSym`, errors: seq[ParseError]] =
      var sb: `seqBuilderName`
      var parserErrs: seq[ParseError]
      discard parseDocumentWith(source, sb, sourcePath, addr parserErrs)
      if sb.results.len > 0:
        (value: sb.results[0], errors: parserErrs)
      else:
        var errs = parserErrs
        if errs.len == 0:
          errs.add(initError(peTypeMissingRequired,
            pointSpan(StartPosition),
            "expected node `" & `nodeNameLit` & "` at top level"))
        (value: default(`typSym`), errors: errs)

  let capsTemplate = quote do:
    template visitorCaps*(_: typedesc[`builderName`]): set[VisitorCap] =
      {vcArgs, vcProps, vcChildren, vcValueAnno, vcNodeAnno}
    template visitorCaps*(_: typedesc[`seqBuilderName`]): set[VisitorCap] =
      {vcArgs, vcProps, vcChildren, vcValueAnno, vcNodeAnno}

  result = newStmtList(
    builderType, beginNodeProc, argProc, propProc, valueAnnoProc, endNodeProc,
    kvpProc, seqBuilderType, seqWrapProcs, capsTemplate, kvpSeqProc,
    kvpAllProc, kvpAllSeqProc)
  when defined(dumpKdlGen):
    echo "=== emitVariantVisitor for ", repr(typ), " ==="
    echo result.repr

macro deriveVisitor(typ: typedesc): untyped =
  ## Emit the per-type visitor machinery for the typed-direct parse path.
  ## Generated code is dumpable via `-d:dumpKdlGen`.
  let typSym =
    if typ.kind == nnkBracketExpr: typ[1]
    else: typ
  let typeImpl = typSym.getImpl
  if typeImpl.kind != nnkTypeDef:
    error("deriveVisitor: argument is not a type definition", typ)
  let body = typeImpl[2]
  if body.kind != nnkObjectTy:
    error("deriveVisitor: only object types are supported (cycle 2 scope)",
          typ)
  let recList = body[2]
  let shape = collectShape(recList)
  if shape.hasVariant:
    result = emitVariantVisitor(typ, typSym, shape)
    return result

  let typName = $typSym
  let nodeName = extractNodeName(typSym)
  let builderName = ident(typName & "VBuilder")
  let bIdent = ident("b")
  let tokIdent = ident("tok")
  let streamIdent = ident("stream")
  let keyStrIdent = ident("keyStr")
  let nameStrIdent = ident("nameStr")
  let idxIdent = ident("idx")
  let entrySpanIdent = ident("entrySpan")
  let nodeFullSpanIdent = ident("nodeFullSpan")

  # Collect kdlChild fields. For seq[T], record the element type so we
  # can wire up a child SeqBuilder slot per field. For non-seq, the
  # singular builder is used directly. Option[Inner] gets a `present`
  # flag so visitEndChildren can commit `some(slot.result)` vs leaving
  # the field at its default `none(Inner)`.
  type ChildField = object
    nimName: string
    kdlName: string         ## name to match in child position (Action's kdlNode)
    elemTypeName: string    ## element type for instantiation (Action / Server / etc.)
    isSeq: bool
    isOption: bool          ## true ⇒ field type is `Option[Inner]`
    expectedReserved: string  ## non-empty ⇒ child node MUST carry this tag
  var children: seq[ChildField]
  var unsupportedChildren: seq[string]  # for runtime-error reporting
  for f in shape.shared:
    if f.kind == fkChild:
      let isSeq = typeNodeIsSeq(f.typeNode)
      let baseTypeNode =
        if f.isOption: f.innerType
        else: f.typeNode
      # Option[seq[T]] children are defensive-skipped — `seq` already
      # carries its own "absent" state (empty), so wrapping in Option is
      # redundant and the per-slot `present` flag would conflict with
      # the slot's own seq accumulator.
      if f.isOption and typeNodeIsSeq(baseTypeNode):
        unsupportedChildren.add(f.nimName)
        continue
      let elemTypeNode =
        if isSeq: f.typeNode[1]
        elif f.isOption: baseTypeNode
        else: f.typeNode
      if elemTypeNode.kind notin {nnkIdent, nnkSym}:
        # Defensive: skip exotic shapes (e.g. seq[Option[T]]) rather
        # than blowing up codegen.
        unsupportedChildren.add(f.nimName)
        continue
      children.add ChildField(
        nimName: f.nimName,
        kdlName: f.kdlName,
        elemTypeName: $elemTypeNode,
        isSeq: isSeq,
        isOption: f.isOption,
        expectedReserved: f.expectedReserved,
      )

  # Track required fields (no defaultExpr → required).
  # Assigns each required field a unique uint8 id used as a set element.
  # Map: nimName -> id. Used by arg/prop to mark "seen" and by endNode
  # to detect missing required fields.
  var requiredIds: Table[string, int]   # fieldNimName -> id
  var requiredNames: seq[string]        # ordered list for error msgs
  for f in shape.shared:
    # Option[T] fields are never "required" — their absent state has
    # a meaningful default (none(T)), and visitor-side emitFieldAssign
    # only fires assignDecoded on the present-arg path. Skip them to
    # keep visitEndNode's required-check honest.
    if f.defaultExpr.kind == nnkEmpty and f.kind in {fkArg, fkAttr} and
       not f.isOption:
      requiredIds[f.nimName] = requiredNames.len
      requiredNames.add(f.nimName)

  # Hard cap on required fields: set[uint8] tops out at 256 elements.
  # Document + enforce at macro time so it's a clear error if hit.
  if requiredNames.len > 256:
    error("deriveVisitor: type `" & typName & "` has " &
          $requiredNames.len & " required fields; max is 256.")

  # 1. Hidden builder type. Per-child-field slots are appended for
  # any kdlChild fields. The slot type is <ElemType>VBuilderSeq for
  # seq[T] children and <ElemType>VBuilder for single. inChildren +
  # curChildName track the dispatch state during child traversal.
  let builderFields = newNimNode(nnkRecList)
  builderFields.add newIdentDefs(ident("result"), typSym)
  if requiredNames.len > 0:
    builderFields.add newIdentDefs(ident("seen"),
      newNimNode(nnkBracketExpr).add(ident("set"), ident("uint8")))
  builderFields.add newIdentDefs(ident("nodeSpan"), ident("Span"))
  # Holds the most recent `(tag)` annotation set by visitValueTypeAnno;
  # consumed (and cleared) by the next visitArg/visitProp. Empty string
  # = no pending annotation.
  builderFields.add newIdentDefs(ident("pendingValueAnno"), ident("string"))
  # Holds the most recent node-level annotation set by visitNodeTypeAnno
  # — read by visitBeginNode to enforce type-level `{.kdlReserved.}`.
  builderFields.add newIdentDefs(ident("pendingNodeAnno"), ident("string"))
  if children.len > 0:
    builderFields.add newIdentDefs(ident("inChildren"), ident("bool"))
    builderFields.add newIdentDefs(ident("curChildName"), ident("string"))
    for c in children:
      let slotName = ident(c.nimName & "_b")
      let slotType = ident(c.elemTypeName &
        (if c.isSeq: "VBuilderSeq" else: "VBuilder"))
      builderFields.add newIdentDefs(slotName, slotType)
      if c.isOption:
        builderFields.add newIdentDefs(
          ident(c.nimName & "_present"), ident("bool"))
      elif not c.isSeq:
        # Singular required child — track seen so visitEndNode can
        # surface a "missing required child" error when absent (matches
        # the AST-walk path's R2-H1 behavior).
        builderFields.add newIdentDefs(
          ident(c.nimName & "_seen"), ident("bool"))
  let builderType = newNimNode(nnkTypeSection).add(
    newNimNode(nnkTypeDef).add(builderName, newEmptyNode(),
      newNimNode(nnkObjectTy).add(newEmptyNode(), newEmptyNode(),
        builderFields)))

  # 2. visitBeginNode: name match + apply field defaults.
  var defaultsBody = newStmtList()
  for f in shape.shared:
    if f.defaultExpr.kind != nnkEmpty:
      let nimName = ident(f.nimName)
      let defExpr = f.defaultExpr
      defaultsBody.add quote do:
        `bIdent`.result.`nimName` = `defExpr`
  let nodeLit = newLit(nodeName)
  let spanIdent = ident("nodeSpan")

  # Type-level kdlReserved check: if the type carries {.kdlReserved: "tag".},
  # the node MUST arrive with that tag. visitNodeTypeAnno fires before
  # visitBeginNode, so we read pendingNodeAnno and validate here.
  let typeReserved = extractTypeReserved(typSym)
  let typeReservedLit = newLit(typeReserved)
  let typeAnnoCheckBody =
    if typeReserved.len > 0:
      quote do:
        if `bIdent`.pendingNodeAnno.len == 0:
          return err[void, ParseError](initError(peTypeReservedMismatch,
            `spanIdent`,
            "type expects (" & `typeReservedLit` & ") tag on its node " &
            "but source has no annotation"))
        if `bIdent`.pendingNodeAnno != `typeReservedLit`:
          return err[void, ParseError](initError(peTypeReservedMismatch,
            `spanIdent`,
            "type expects (" & `typeReservedLit` & ") tag on its node " &
            "but source has (" & `bIdent`.pendingNodeAnno & ")"))
        `bIdent`.pendingNodeAnno = ""
    else:
      # No constraint — leave pendingNodeAnno populated for child-slot
      # forwarding (used by parent's child dispatch).
      newStmtList()

  # Child-dispatch body for visitBeginNode when inChildren is true.
  # Routes the child node name to the right per-field builder slot.
  var childBeginDispatch = newNimNode(nnkCaseStmt).add(quote do:
    openArrayToString(`nameStrIdent`))
  for c in children:
    let kdlLit = newLit(c.kdlName)
    let slot = ident(c.nimName & "_b")
    let expectedLit = newLit(c.expectedReserved)
    let nimNameLit = newLit(c.nimName)
    # Child-field-level kdlReserved: validate parent.pendingNodeAnno
    # matches the field's expected tag (or that the source supplied any
    # tag at all). Then forward parent.pendingNodeAnno to the child
    # slot so the child's own type-level kdlReserved check sees it.
    let childValidate =
      if c.expectedReserved.len > 0:
        quote do:
          if `bIdent`.pendingNodeAnno.len == 0:
            return err[void, ParseError](initError(peTypeReservedMismatch,
              `spanIdent`,
              "child `" & `nimNameLit` & "` expects (" & `expectedLit` &
              ") tag but source child has no annotation"))
          if `bIdent`.pendingNodeAnno != `expectedLit`:
            return err[void, ParseError](initError(peTypeReservedMismatch,
              `spanIdent`,
              "child `" & `nimNameLit` & "` expects (" & `expectedLit` &
              ") tag but source has (" & `bIdent`.pendingNodeAnno & ")"))
      else:
        newStmtList()
    if c.isOption:
      let presentFlag = ident(c.nimName & "_present")
      childBeginDispatch.add(newNimNode(nnkOfBranch).add(kdlLit).add quote do:
        `bIdent`.curChildName = `kdlLit`
        `bIdent`.`presentFlag` = true
        `childValidate`
        `bIdent`.`slot`.pendingNodeAnno = `bIdent`.pendingNodeAnno
        `bIdent`.pendingNodeAnno = ""
        return visitBeginNode(`bIdent`.`slot`, `nameStrIdent`, `spanIdent`))
    elif c.isSeq:
      childBeginDispatch.add(newNimNode(nnkOfBranch).add(kdlLit).add quote do:
        `bIdent`.curChildName = `kdlLit`
        `childValidate`
        `bIdent`.`slot`.pendingNodeAnno = `bIdent`.pendingNodeAnno
        `bIdent`.pendingNodeAnno = ""
        return visitBeginNode(`bIdent`.`slot`, `nameStrIdent`, `spanIdent`))
    else:
      let seenFlag = ident(c.nimName & "_seen")
      childBeginDispatch.add(newNimNode(nnkOfBranch).add(kdlLit).add quote do:
        `bIdent`.curChildName = `kdlLit`
        `bIdent`.`seenFlag` = true
        `childValidate`
        `bIdent`.`slot`.pendingNodeAnno = `bIdent`.pendingNodeAnno
        `bIdent`.pendingNodeAnno = ""
        return visitBeginNode(`bIdent`.`slot`, `nameStrIdent`, `spanIdent`))
  if children.len > 0:
    childBeginDispatch.add(newNimNode(nnkElse).add quote do:
      return err[void, ParseError](initError(peTypeUnknownField, `spanIdent`,
        "`" & `nodeLit` & "` has no child kind `" &
        openArrayToString(`nameStrIdent`) & "`")))

  let beginNodeProc =
    if children.len > 0:
      quote do:
        proc visitBeginNode(`bIdent`: var `builderName`,
                       `nameStrIdent`: openArray[char],
                       `spanIdent`: Span):
            Result[void, ParseError] {.noSideEffect.} =
          if `bIdent`.inChildren:
            `childBeginDispatch`
          `bIdent`.nodeSpan = `spanIdent`
          var match = `nameStrIdent`.len == `nodeLit`.len
          if match:
            for i in 0 ..< `nameStrIdent`.len:
              if `nameStrIdent`[i] != `nodeLit`[i]:
                match = false; break
          if not match:
            return err[void, ParseError](initError(peTypeMismatch,
              `spanIdent`,
              "expected node `" & `nodeLit` & "`"))
          `typeAnnoCheckBody`
          `defaultsBody`
          ok(void, ParseError)
    else:
      quote do:
        proc visitBeginNode(`bIdent`: var `builderName`,
                       `nameStrIdent`: openArray[char],
                       `spanIdent`: Span):
            Result[void, ParseError] {.noSideEffect.} =
          `bIdent`.nodeSpan = `spanIdent`
          var match = `nameStrIdent`.len == `nodeLit`.len
          if match:
            for i in 0 ..< `nameStrIdent`.len:
              if `nameStrIdent`[i] != `nodeLit`[i]:
                match = false; break
          if not match:
            return err[void, ParseError](initError(peTypeMismatch,
              `spanIdent`,
              "expected node `" & `nodeLit` & "`"))
          `typeAnnoCheckBody`
          `defaultsBody`
          ok(void, ParseError)

  # Helper: emit the per-field decode body for visitArg/visitProp.
  # Handles Option[T] for primitive T (wraps in some), enum fields
  # (tkString/tkRawString → decodeEnumFromString), and the primitive
  # int/string/bool/float core. Unsupported shapes fall through to a
  # runtime peTypeMismatch — codegen never errors here so the
  # surrounding `kdl:` block can still emit decode+encode for the type.
  proc emitVisitorFieldAssign(f: FieldSpec, fieldLabel: NimNode,
                              seenStmt: NimNode): NimNode =
    let nimName = ident(f.nimName)
    # For Option[T] fields, the underlying primitive type for token
    # dispatch is f.innerType; we wrap the decoded value in `some(...)`.
    # Option fields skip the seen.incl bit (they're never "required").
    let isOpt = f.isOption
    let primTypeNode = if isOpt: f.innerType else: f.typeNode
    let primTypeName = $primTypeNode
    let typeStr = primTypeName  # for error msgs
    # Reserved-tag validation: if the field declares `{.kdlReserved: "x".}`,
    # the source value MUST carry the matching `(x)` annotation. If the
    # source carries any annotation (even on a non-reserved field), the
    # annotation's content must validate per spec §3 (e.g. `(ipv4)` →
    # validateIpv4). Mirrors DocBuilder's visitArg/visitProp logic so the
    # visitor + AST-walk paths agree on every input.
    let expectedReservedLit = newLit(f.expectedReserved)
    let kdlNameLit = newLit(f.kdlName)
    proc validateReservedBlock(decodedExpr: NimNode, kvCtor: string): NimNode =
      let ctorIdent = ident(kvCtor)
      let valSym = genSym(nskLet, "kdlVal_" & f.nimName)
      let rcheckSym = genSym(nskLet, "rcheck_" & f.nimName)
      quote do:
        if `bIdent`.pendingValueAnno.len == 0:
          if `expectedReservedLit`.len > 0:
            return err[void, ParseError](initError(peTypeReservedMismatch,
              `tokIdent`.span,
              "field `" & `kdlNameLit` & "` expects (" & `expectedReservedLit` &
              ") tag but source value has no annotation"))
        else:
          if `expectedReservedLit`.len > 0 and
             `bIdent`.pendingValueAnno != `expectedReservedLit`:
            return err[void, ParseError](initError(peTypeReservedMismatch,
              `tokIdent`.span,
              "field `" & `kdlNameLit` & "` expects (" & `expectedReservedLit` &
              ") tag but source has (" & `bIdent`.pendingValueAnno & ")"))
          let `valSym` = `ctorIdent`(`decodedExpr`, `tokIdent`.span)
          let `rcheckSym` = validateReserved(`bIdent`.pendingValueAnno, `valSym`)
          if `rcheckSym`.isErr:
            return err[void, ParseError](`rcheckSym`.getErr)
          `bIdent`.pendingValueAnno = ""

    # Build core: a stmtlist that, given a `decoded` ident of the right
    # primitive type, validates any reserved-tag constraint, then assigns
    # to the target field (wrapping in some if Option) and runs the seen
    # bit if not Option.
    proc assignDecoded(decodedExpr: NimNode): NimNode =
      if isOpt:
        quote do:
          `bIdent`.result.`nimName` = some(`decodedExpr`)
      else:
        let asn = quote do:
          `bIdent`.result.`nimName` = `decodedExpr`
        # Append seenStmt
        let s = newStmtList()
        s.add(asn)
        s.add(seenStmt)
        s

    proc validateAndAssign(decodedExpr: NimNode, kvCtor: string): NimNode =
      let s = newStmtList()
      s.add(validateReservedBlock(decodedExpr, kvCtor))
      s.add(assignDecoded(decodedExpr))
      s

    # Enum dispatch: read string payload then decodeEnumFromString.
    if f.typeIsEnum:
      let innerT = primTypeNode
      let strSym = genSym(nskLet, "enumStr")
      let outSym = genSym(nskVar, "enumOut")
      let body = quote do:
        var `outSym`: `innerT`
        if not decodeEnumFromString(`outSym`, `strSym`):
          return err[void, ParseError](initError(peTypeEnumInvalid,
            `tokIdent`.span, "invalid enum value for `" &
            `fieldLabel` & "`: '" & `strSym` & "'"))
      let assignBody = newStmtList()
      assignBody.add(body)
      # Enum source is always a string token — validate via newStringValue
      # against the matched-against string (pre-enum-decode). We use
      # `strSym` (the source bytes) rather than `outSym` (the enum) so the
      # validation operates on the original textual form.
      assignBody.add(validateReservedBlock(strSym, "newStringValue"))
      assignBody.add(assignDecoded(outSym))
      return quote do:
        case `tokIdent`.kind
        of tkString:
          let `strSym` = `streamIdent`.stringPayloads[`tokIdent`.strIdx]
          `assignBody`
        of tkRawString:
          let `strSym` = `streamIdent`.rawStringPayloads[`tokIdent`.rawIdx]
          `assignBody`
        of tkIdent:
          # Bareword identifier — read bytes from the original source via
          # the token span. `stream.source` is set by `lex()`.
          let s0 = `tokIdent`.span.start.offset
          let s1 = `tokIdent`.span.finish.offset - 1
          let `strSym` = `streamIdent`.source[s0 .. s1]
          `assignBody`
        else:
          return err[void, ParseError](initError(peTypeEnumInvalid,
            `tokIdent`.span, "expected string or bareword for enum `" &
            `fieldLabel` & "`"))

    case primTypeName
    of "string":
      let strSym = genSym(nskLet, "strVal")
      let strAssign = validateAndAssign(strSym, "newStringValue")
      quote do:
        case `tokIdent`.kind
        of tkString:
          let `strSym` = `streamIdent`.stringPayloads[`tokIdent`.strIdx]
          `strAssign`
        of tkRawString:
          let `strSym` = `streamIdent`.rawStringPayloads[`tokIdent`.rawIdx]
          `strAssign`
        of tkIdent:
          # KDL v2: a bareword identifier in value position is a string.
          # Mirror DocBuilder's lenient handling.
          let s0 = `tokIdent`.span.start.offset
          let s1 = `tokIdent`.span.finish.offset - 1
          let `strSym` = `streamIdent`.source[s0 .. s1]
          `strAssign`
        else:
          return err[void, ParseError](initError(peTypeMismatch,
            `tokIdent`.span, "expected string for `" &
            `fieldLabel` & "`"))
    of "int":
      let intSym = genSym(nskLet, "intVal")
      let intAssign = validateAndAssign(intSym, "newIntValue")
      quote do:
        if `tokIdent`.kind != tkNumber:
          return err[void, ParseError](initError(peTypeMismatch,
            `tokIdent`.span, "expected int for `" &
            `fieldLabel` & "`"))
        let n = `streamIdent`.numberPayloads[`tokIdent`.numIdx]
        let d = decodeIntFromToken(n, `tokIdent`.span)
        if d.isErr: return err[void, ParseError](d.getErr)
        let `intSym` = int(d.get)
        `intAssign`
    of "bool":
      let boolSym = genSym(nskLet, "boolVal")
      let boolAssign = validateAndAssign(boolSym, "newBoolValue")
      quote do:
        if `tokIdent`.kind != tkKeyword:
          return err[void, ParseError](initError(peTypeMismatch,
            `tokIdent`.span, "expected bool for `" &
            `fieldLabel` & "`"))
        let `boolSym` = (`tokIdent`.keyword == kwTrue)
        `boolAssign`
    of "float", "float64":
      let fltSym = genSym(nskLet, "fltVal")
      let fltAssign = validateAndAssign(fltSym, "newFloatValue")
      quote do:
        if `tokIdent`.kind != tkNumber:
          return err[void, ParseError](initError(peTypeMismatch,
            `tokIdent`.span, "expected number for `" &
            `fieldLabel` & "`"))
        let n = `streamIdent`.numberPayloads[`tokIdent`.numIdx]
        let `fltSym` =
          if looksLikeFloat(n):
            let d = decodeFloatFromToken(n, `tokIdent`.span)
            if d.isErr: return err[void, ParseError](d.getErr)
            d.get
          else:
            let d = decodeIntFromToken(n, `tokIdent`.span)
            if d.isErr: return err[void, ParseError](d.getErr)
            float(d.get)
        `fltAssign`
    else:
      # Unsupported shape (e.g. Option[CustomObject], custom non-enum
      # types, kdlReserved-validated fields where we'd need to track
      # the inbound value annotation). Emit a runtime error — never
      # block codegen, so the surrounding kdl: block can still emit
      # decode + encode for the type. Use decode[T] for these fields.
      let typeStrLit = newLit(typeStr)
      quote do:
        return err[void, ParseError](initError(peTypeMismatch,
          `tokIdent`.span, "unsupported field type `" & `typeStrLit` &
          "` for `" & `fieldLabel` &
          "` in typed-direct path (use decode[T])"))

  # 3. visitArg: dispatch by positional index.
  var argCase = newNimNode(nnkCaseStmt).add(idxIdent)
  var argSeen = 0
  for f in shape.shared:
    if f.kind == fkArg:
      let lit = newLit(argSeen)
      let fieldLabel = newLit(typName & "." & f.nimName)
      # Mark this field "seen" for the required-field check in endNode.
      # Option fields skip this — they're definitionally not required.
      let seenStmt =
        if requiredIds.hasKey(f.nimName) and not f.isOption:
          let idLit = newLit(uint8(requiredIds[f.nimName]))
          quote do: `bIdent`.seen.incl(`idLit`)
        else: newStmtList()
      let assignment = emitVisitorFieldAssign(f, fieldLabel, seenStmt)
      argCase.add(newNimNode(nnkOfBranch).add(lit).add(assignment))
      inc argSeen
  argCase.add(newNimNode(nnkElse).add quote do:
    return err[void, ParseError](initError(peParseUnexpected, `tokIdent`.span,
      "too many positional args for `" & `nodeLit` & "`")))
  # When inChildren, forward visitArg to the right child slot.
  var childArgDispatch = newNimNode(nnkCaseStmt).add(quote do:
    `bIdent`.curChildName)
  for c in children:
    let kdlLit = newLit(c.kdlName)
    let slot = ident(c.nimName & "_b")
    childArgDispatch.add(newNimNode(nnkOfBranch).add(kdlLit).add quote do:
      return visitArg(`bIdent`.`slot`, `idxIdent`, `tokIdent`,
                      `streamIdent`, `entrySpanIdent`))
  if children.len > 0:
    childArgDispatch.add(newNimNode(nnkElse).add quote do:
      return err[void, ParseError](initError(peParseUnexpected, `tokIdent`.span,
        "unrecognized active child")))
  let argProc =
    if children.len > 0:
      quote do:
        proc visitArg(`bIdent`: var `builderName`, `idxIdent`: int,
                 `tokIdent`: Token, `streamIdent`: TokenStream,
                 `entrySpanIdent`: Span):
            Result[void, ParseError] {.noSideEffect.} =
          if `bIdent`.inChildren:
            `childArgDispatch`
          `argCase`
          ok(void, ParseError)
    else:
      quote do:
        proc visitArg(`bIdent`: var `builderName`, `idxIdent`: int,
                 `tokIdent`: Token, `streamIdent`: TokenStream,
                 `entrySpanIdent`: Span):
            Result[void, ParseError] {.noSideEffect.} =
          `argCase`
          ok(void, ParseError)

  # 4. visitProp: dispatch by property key string. Build as a series of
  # nested if/elif with bytesEq compile-time byte compares so the
  # dispatch is zero-alloc (the previous openArrayToString + case was
  # ~2.4% of CPU per perf record).
  var propBranches: seq[(string, NimNode)]  # (kdlName, assignment)
  for f in shape.shared:
    if f.kind == fkAttr:
      let fieldLabel = newLit(typName & "." & f.nimName)
      let seenStmt =
        if requiredIds.hasKey(f.nimName) and not f.isOption:
          let idLit = newLit(uint8(requiredIds[f.nimName]))
          quote do: `bIdent`.seen.incl(`idLit`)
        else: newStmtList()
      let assignment = emitVisitorFieldAssign(f, fieldLabel, seenStmt)
      propBranches.add((f.kdlName, assignment))
  # Build the if/elif/else cascade from the collected branches.
  var propDispatch: NimNode
  if propBranches.len == 0:
    propDispatch = quote do:
      return err[void, ParseError](initError(peTypeUnknownField, `tokIdent`.span,
        "`" & `nodeLit` & "` has no field `" &
        openArrayToString(`keyStrIdent`) & "`"))
  else:
    let elseBranch = quote do:
      return err[void, ParseError](initError(peTypeUnknownField, `tokIdent`.span,
        "`" & `nodeLit` & "` has no field `" &
        openArrayToString(`keyStrIdent`) & "`"))
    # Build elif cascade from back to front
    propDispatch = elseBranch
    for i in countdown(propBranches.high, 0):
      let (kdlName, assignment) = propBranches[i]
      let nameLit = newLit(kdlName)
      let nextNode = propDispatch
      propDispatch = quote do:
        if bytesEq(`keyStrIdent`, `nameLit`):
          `assignment`
        else:
          `nextNode`
  # When inChildren, forward visitProp to the right child slot.
  var childPropDispatch = newNimNode(nnkCaseStmt).add(quote do:
    `bIdent`.curChildName)
  for c in children:
    let kdlLit = newLit(c.kdlName)
    let slot = ident(c.nimName & "_b")
    childPropDispatch.add(newNimNode(nnkOfBranch).add(kdlLit).add quote do:
      return visitProp(`bIdent`.`slot`, `keyStrIdent`,
                       `tokIdent`, `streamIdent`, `entrySpanIdent`))
  if children.len > 0:
    childPropDispatch.add(newNimNode(nnkElse).add quote do:
      return err[void, ParseError](initError(peParseUnexpected, `tokIdent`.span,
        "unrecognized active child")))
  let propProc =
    if children.len > 0:
      quote do:
        proc visitProp(`bIdent`: var `builderName`,
                  `keyStrIdent`: openArray[char],
                  `tokIdent`: Token, `streamIdent`: TokenStream,
                  `entrySpanIdent`: Span):
            Result[void, ParseError] {.noSideEffect.} =
          if `bIdent`.inChildren:
            `childPropDispatch`
          `propDispatch`
          ok(void, ParseError)
    else:
      quote do:
        proc visitProp(`bIdent`: var `builderName`,
                  `keyStrIdent`: openArray[char],
                  `tokIdent`: Token, `streamIdent`: TokenStream,
                  `entrySpanIdent`: Span):
            Result[void, ParseError] {.noSideEffect.} =
          `propDispatch`
          ok(void, ParseError)

  # 5/6/7. Children: no-op for flat case (cycle 7 adds children).
  # visitEndNode: required-field check fires here. Error wording mirrors
  # the AST-walk path (emitArgDecode / emitAttrDecode / emitChildDecode)
  # so consumer error-message matching is identical across both paths.
  var requiredCheckBody = newStmtList()
  if requiredNames.len > 0:
    for f in shape.shared:
      if f.kind notin {fkArg, fkAttr}: continue
      if f.defaultExpr.kind != nnkEmpty or f.isOption: continue
      if not requiredIds.hasKey(f.nimName): continue
      let idLit = newLit(uint8(requiredIds[f.nimName]))
      let msgLit =
        case f.kind
        of fkArg:  newLit("missing required positional arg " &
                          $f.argIndex & " ('" & f.kdlName & "')")
        of fkAttr: newLit("missing required property '" & f.kdlName & "'")
        else: newLit("")  # unreachable per guard above
      requiredCheckBody.add quote do:
        if `idLit` notin `bIdent`.seen:
          return err[void, ParseError](initError(peTypeMissingRequired,
            `bIdent`.nodeSpan, `msgLit`))
  # Singular required children: no default + not Option + not seq.
  for c in children:
    if c.isSeq or c.isOption: continue
    # All singular non-Option children are treated as required (matches
    # AST-walk: emitChildDecode emits a missing-required error when the
    # child node isn't found).
    let seenFlag = ident(c.nimName & "_seen")
    let nameLit = newLit("missing required child node '" & c.kdlName & "'")
    requiredCheckBody.add quote do:
      if not `bIdent`.`seenFlag`:
        return err[void, ParseError](initError(peTypeMissingRequired,
          `bIdent`.nodeSpan, `nameLit`))
  # End-children: commit each child slot's accumulated results into
  # the matching parent.result.<nimName> field, then clear the
  # inChildren flag.
  var endChildrenBody = newStmtList()
  for c in children:
    let slot = ident(c.nimName & "_b")
    let nimField = ident(c.nimName)
    if c.isSeq:
      endChildrenBody.add quote do:
        `bIdent`.result.`nimField` = `bIdent`.`slot`.results
    elif c.isOption:
      let presentFlag = ident(c.nimName & "_present")
      endChildrenBody.add quote do:
        if `bIdent`.`presentFlag`:
          `bIdent`.result.`nimField` = some(`bIdent`.`slot`.result)
    else:
      endChildrenBody.add quote do:
        `bIdent`.result.`nimField` = `bIdent`.`slot`.result
  if children.len > 0:
    endChildrenBody.add quote do:
      `bIdent`.inChildren = false

  # End-node: forward to active child when inChildren, otherwise run
  # the required-field check on self.
  var childEndDispatch = newNimNode(nnkCaseStmt).add(quote do:
    `bIdent`.curChildName)
  for c in children:
    let kdlLit = newLit(c.kdlName)
    let slot = ident(c.nimName & "_b")
    childEndDispatch.add(newNimNode(nnkOfBranch).add(kdlLit).add quote do:
      return visitEndNode(`bIdent`.`slot`, `nodeFullSpanIdent`))
  if children.len > 0:
    childEndDispatch.add(newNimNode(nnkElse).add quote do:
      return ok(void, ParseError))

  let restProcs =
    if children.len > 0:
      quote do:
        proc visitBeginChildren(`bIdent`: var `builderName`):
            Result[void, ParseError] {.noSideEffect.} =
          `bIdent`.inChildren = true
          ok(void, ParseError)
        proc visitEndChildren(`bIdent`: var `builderName`):
            Result[void, ParseError] {.noSideEffect.} =
          `endChildrenBody`
          ok(void, ParseError)
        proc visitEndNode(`bIdent`: var `builderName`, `nodeFullSpanIdent`: Span):
            Result[void, ParseError] {.noSideEffect.} =
          if `bIdent`.inChildren:
            `childEndDispatch`
          `requiredCheckBody`
          ok(void, ParseError)
    else:
      quote do:
        proc visitBeginChildren(`bIdent`: var `builderName`):
            Result[void, ParseError] {.noSideEffect.} =
          ok(void, ParseError)
        proc visitEndChildren(`bIdent`: var `builderName`):
            Result[void, ParseError] {.noSideEffect.} =
          ok(void, ParseError)
        proc visitEndNode(`bIdent`: var `builderName`, `nodeFullSpanIdent`: Span):
            Result[void, ParseError] {.noSideEffect.} =
          `requiredCheckBody`
          ok(void, ParseError)

  # 8. kdlBuildVisitor — the macro-emitted entry the generic parseInto[T]
  # mixins into for the singular case.
  let kvpProc = quote do:
    proc kdlBuildVisitor(_: typedesc[`typSym`], source: string,
                         sourcePath: string): Result[`typSym`, ParseError] =
      var `bIdent` = `builderName`()
      let r = parseWith(source, `bIdent`, sourcePath)
      if r.isErr: return err[`typSym`, ParseError](r.getErr)
      ok[`typSym`, ParseError](`bIdent`.result)

  # 9. Seq variant. Uses a wrapping visitor that holds a seq + per-node
  # builder; visitEndNode commits to the seq and resets the builder for the
  # next sibling. parseDocumentWith drives the loop over top-level nodes,
  # so we filter by name: non-matching top-level nodes are silently
  # skipped (matches AST-walk's "decode[seq[T]] only collects nodes
  # whose name matches T's kdlNode").
  # pendingNodeAnno on the wrapper survives the per-node `cur` reset so a
  # parent's child-dispatch can stash an annotation onto the seq slot
  # before each visitBeginNode forwards it into the fresh `cur`.
  let seqBuilderName = ident(typName & "VBuilderSeq")
  let nodeNameLit = newLit(nodeName)
  # `allMode` + `errors` switch the seq wrapper from strict (return-on-
  # first-error) to accumulating semantics. Per-node: on the first error
  # within a node, capture it, set `curFailed`, swallow further events
  # for that node, and skip the commit when visitEndNode fires. The
  # surrounding parseDocumentWith (driven with errorBuf) handles
  # parser-level error recovery and resync; this flag handles the
  # visitor side of the same contract.
  let seqBuilderType = quote do:
    type `seqBuilderName` = object
      results: seq[`typSym`]
      cur: `builderName`
      pendingNodeAnno: string
      skipping: bool
      allMode: bool
      curFailed: bool
      errors: seq[ParseError]
  let annoStrIdent = ident("annoStr")
  let annoSpanIdent = ident("annoSpan")
  let valueAnnoProc = quote do:
    proc visitValueTypeAnno(`bIdent`: var `builderName`,
                            `annoStrIdent`: openArray[char],
                            `annoSpanIdent`: Span):
        Result[void, ParseError] {.noSideEffect.} =
      `bIdent`.pendingValueAnno = openArrayToString(`annoStrIdent`)
      ok(void, ParseError)
    proc visitNodeTypeAnno(`bIdent`: var `builderName`,
                           `annoStrIdent`: openArray[char],
                           `annoSpanIdent`: Span):
        Result[void, ParseError] {.noSideEffect.} =
      `bIdent`.pendingNodeAnno = openArrayToString(`annoStrIdent`)
      ok(void, ParseError)
  let seqWrapProcs = quote do:
    proc visitBeginNode(`bIdent`: var `seqBuilderName`,
                   `nameStrIdent`: openArray[char],
                   `spanIdent`: Span):
        Result[void, ParseError] {.noSideEffect.} =
      # Top-level name filter: only nodes named per T's kdlNode are
      # decoded. Others (e.g. other top-level node kinds in the same
      # document) are silently skipped — matches AST-walk decode[seq[T]].
      var nameMatch = `nameStrIdent`.len == `nodeNameLit`.len
      if nameMatch:
        for i in 0 ..< `nameStrIdent`.len:
          if `nameStrIdent`[i] != `nodeNameLit`[i]:
            nameMatch = false; break
      if not nameMatch:
        `bIdent`.skipping = true
        `bIdent`.pendingNodeAnno = ""
        return ok(void, ParseError)
      `bIdent`.skipping = false
      `bIdent`.curFailed = false
      `bIdent`.cur = `builderName`()
      `bIdent`.cur.pendingNodeAnno = `bIdent`.pendingNodeAnno
      `bIdent`.pendingNodeAnno = ""
      let r0 = visitBeginNode(`bIdent`.cur, `nameStrIdent`, `spanIdent`)
      if r0.isErr and `bIdent`.allMode:
        `bIdent`.errors.add(r0.getErr)
        `bIdent`.curFailed = true
        return ok(void, ParseError)
      r0
    proc visitArg(`bIdent`: var `seqBuilderName`, `idxIdent`: int,
             `tokIdent`: Token, `streamIdent`: TokenStream,
             `entrySpanIdent`: Span):
        Result[void, ParseError] {.noSideEffect.} =
      if `bIdent`.skipping or `bIdent`.curFailed:
        return ok(void, ParseError)
      let r = visitArg(`bIdent`.cur, `idxIdent`, `tokIdent`,
                       `streamIdent`, `entrySpanIdent`)
      if r.isErr and `bIdent`.allMode:
        `bIdent`.errors.add(r.getErr)
        `bIdent`.curFailed = true
        return ok(void, ParseError)
      r
    proc visitProp(`bIdent`: var `seqBuilderName`,
              `keyStrIdent`: openArray[char],
              `tokIdent`: Token, `streamIdent`: TokenStream,
              `entrySpanIdent`: Span):
        Result[void, ParseError] {.noSideEffect.} =
      if `bIdent`.skipping or `bIdent`.curFailed:
        return ok(void, ParseError)
      let r = visitProp(`bIdent`.cur, `keyStrIdent`, `tokIdent`,
                        `streamIdent`, `entrySpanIdent`)
      if r.isErr and `bIdent`.allMode:
        `bIdent`.errors.add(r.getErr)
        `bIdent`.curFailed = true
        return ok(void, ParseError)
      r
    proc visitValueTypeAnno(`bIdent`: var `seqBuilderName`,
                            `annoStrIdent`: openArray[char],
                            `annoSpanIdent`: Span):
        Result[void, ParseError] {.noSideEffect.} =
      if `bIdent`.skipping or `bIdent`.curFailed:
        return ok(void, ParseError)
      visitValueTypeAnno(`bIdent`.cur, `annoStrIdent`, `annoSpanIdent`)
    proc visitNodeTypeAnno(`bIdent`: var `seqBuilderName`,
                           `annoStrIdent`: openArray[char],
                           `annoSpanIdent`: Span):
        Result[void, ParseError] {.noSideEffect.} =
      # Stash on the wrapper — `cur` gets recreated on the next
      # visitBeginNode, which then forwards into the fresh cur.
      `bIdent`.pendingNodeAnno = openArrayToString(`annoStrIdent`)
      ok(void, ParseError)
    proc visitBeginChildren(`bIdent`: var `seqBuilderName`):
        Result[void, ParseError] {.noSideEffect.} =
      if `bIdent`.skipping or `bIdent`.curFailed:
        return ok(void, ParseError)
      visitBeginChildren(`bIdent`.cur)
    proc visitEndChildren(`bIdent`: var `seqBuilderName`):
        Result[void, ParseError] {.noSideEffect.} =
      if `bIdent`.skipping or `bIdent`.curFailed:
        return ok(void, ParseError)
      visitEndChildren(`bIdent`.cur)
    proc visitEndNode(`bIdent`: var `seqBuilderName`, `nodeFullSpanIdent`: Span):
        Result[void, ParseError] {.noSideEffect.} =
      if `bIdent`.skipping:
        `bIdent`.skipping = false
        return ok(void, ParseError)
      if `bIdent`.curFailed:
        # Error already captured during this node; skip commit so the
        # half-built `cur.result` doesn't leak into `results`.
        return ok(void, ParseError)
      let r = visitEndNode(`bIdent`.cur, `nodeFullSpanIdent`)
      if r.isErr:
        if `bIdent`.allMode:
          `bIdent`.errors.add(r.getErr)
          return ok(void, ParseError)
        return r
      `bIdent`.results.add(`bIdent`.cur.result)
      ok(void, ParseError)
  let kvpSeqProc = quote do:
    proc kdlBuildVisitorSeq(_: typedesc[`typSym`], source: string,
                            sourcePath: string):
        Result[seq[`typSym`], ParseError] =
      var sb = `seqBuilderName`()
      let r = parseDocumentWith(source, sb, sourcePath)
      if r.isErr: return err[seq[`typSym`], ParseError](r.getErr)
      ok[seq[`typSym`], ParseError](sb.results)

  # Accumulating ("all") entry points. Parse runs in recovery mode:
  # lex / syntax / visitor errors at any node boundary push to the
  # error buffer and the parser resyncs at the next node terminator.
  # Surviving nodes still commit to `results`. Powers `decodeAll[T]`.
  let kvpAllSeqProc = quote do:
    proc kdlBuildVisitorAllSeq(_: typedesc[`typSym`], source: string,
                               sourcePath: string):
        tuple[value: seq[`typSym`], errors: seq[ParseError]] =
      var sb = `seqBuilderName`(allMode: true)
      var parserErrs: seq[ParseError]
      discard parseDocumentWith(source, sb, sourcePath, addr parserErrs)
      # Merge parser-level errors (lex / syntax) with visitor-level
      # errors (type mismatches inside otherwise-well-formed nodes).
      (value: sb.results, errors: parserErrs & sb.errors)
  let kvpAllProc = quote do:
    proc kdlBuildVisitorAll(_: typedesc[`typSym`], source: string,
                            sourcePath: string):
        tuple[value: `typSym`, errors: seq[ParseError]] =
      var sb = `seqBuilderName`(allMode: true)
      var parserErrs: seq[ParseError]
      discard parseDocumentWith(source, sb, sourcePath, addr parserErrs)
      let allErrs = parserErrs & sb.errors
      if sb.results.len > 0:
        (value: sb.results[0], errors: allErrs)
      else:
        var errs = allErrs
        if errs.len == 0:
          errs.add(initError(peTypeMissingRequired,
            pointSpan(StartPosition),
            "expected node `" & `nodeNameLit` & "` at top level"))
        (value: default(`typSym`), errors: errs)

  let capsTemplate = quote do:
    template visitorCaps*(_: typedesc[`builderName`]): set[VisitorCap] =
      {vcArgs, vcProps, vcChildren, vcValueAnno, vcNodeAnno}
    template visitorCaps*(_: typedesc[`seqBuilderName`]): set[VisitorCap] =
      {vcArgs, vcProps, vcChildren, vcValueAnno, vcNodeAnno}

  result = newStmtList(
    builderType, beginNodeProc, argProc, propProc, valueAnnoProc, restProcs,
    kvpProc, seqBuilderType, seqWrapProcs, capsTemplate, kvpSeqProc,
    kvpAllProc, kvpAllSeqProc)
  when defined(dumpKdlGen):
    echo "=== deriveVisitor for ", repr(typ), " ==="
    echo result.repr

# ---------------------------------------------------------------------------
# kdl: — block macro. The ONLY public surface for setting up KDL-mapped
# types. Wraps a block containing one or more `type T {.kdlNode: "n".}`
# definitions and emits the visitor + encode machinery for each, so
# `decode[T]` / `decodeAll[T]` / `embed[T]` / `encode[T]` / `encodeFrom[T]`
# all work without per-type derive calls.
#
# Usage:
#
#   kdl:
#     type Service {.kdlNode: "service".} = object
#       name {.kdlArg.}: string
#
# A pragma-form `type T {.kdl: "n".}` was prototyped but blocked by a
# Nim language constraint: type-pragma macros can transform the type
# but cannot emit sibling declarations. Module-level block macros can.
# ---------------------------------------------------------------------------

proc extractKdlTypeSym(typeDef: NimNode): NimNode {.compileTime.} =
  ## Pull the type identifier out of a typedef. Handles bare,
  ## exported (`T*`), and pragma-wrapped (`T {.pragma.}`) name slots.
  let nameNode = typeDef[0]
  case nameNode.kind
  of nnkIdent, nnkSym: nameNode
  of nnkPostfix:       nameNode[1]
  of nnkPragmaExpr:
    let inner = nameNode[0]
    if inner.kind == nnkPostfix: inner[1] else: inner
  else:
    error("kdl block: cannot extract type ident from " & $nameNode.kind, nameNode)
    nameNode

proc hasKdlNodePragma(typeDef: NimNode): bool {.compileTime.} =
  ## True iff the typedef's name slot carries a `{.kdlNode: "name".}`
  ## pragma — the marker that identifies a type as KDL-mapped.
  if typeDef[0].kind != nnkPragmaExpr: return false
  for p in typeDef[0][1]:
    if p.kind in {nnkExprColonExpr, nnkCall} and p.len >= 2:
      if $p[0] == "kdlNode": return true
  false

macro kdl*(body: untyped): untyped =
  ## Scope a region of KDL type definitions. Inside the block, every
  ## `type T {.kdlNode: "name".} = object ...` gets the full
  ## decode + encode + typed-direct surface emitted automatically.
  ##
  ## ```nim
  ## kdl:
  ##   type Service {.kdlNode: "service".} = object
  ##     name {.kdlArg.}: string
  ##     port {.kdlProp.}: int
  ##     enabled {.kdlProp.}: bool = true
  ##
  ##   type Action {.kdlNode: "action".} = object
  ##     tmpl {.kdlArg, kdlRename: "template".}: string
  ##
  ## # decode[Service], parseInto[Service], encodeFrom[Service] all work.
  ## # Same for Action.
  ## ```
  ##
  ## Types in the block without `{.kdlNode.}` are passed through
  ## unchanged — useful for helper types that share the file but aren't
  ## themselves KDL-mapped.
  result = newStmtList()
  let inner =
    if body.kind == nnkStmtList: body
    else: newStmtList(body)
  for stmt in inner:
    case stmt.kind
    of nnkTypeSection:
      # Pass the type section through, then queue derives for any
      # member typedef carrying {.kdlNode.}.
      result.add(stmt)
      for typeDef in stmt:
        if typeDef.kind == nnkTypeDef and hasKdlNodePragma(typeDef):
          let typeSym = extractKdlTypeSym(typeDef)
          result.add(newCall(bindSym"deriveEncode", typeSym))
          result.add(newCall(bindSym"deriveVisitor", typeSym))
    else:
      # Allow non-type statements (imports, helpers, comments).
      result.add(stmt)

  when defined(dumpKdlGen):
    echo "=== kdl block: output ==="
    echo result.repr
