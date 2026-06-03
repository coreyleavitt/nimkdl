## derive_common — shared macro helpers for the Cat-2 typed-derive layer
## (deriveDecode/deriveEncode).
##
## Single source of truth — see rfc-derive-vocabulary.md S0a / S0c.
##
## S0c unified the last four source-divergent helpers (nodeNameOf,
## objectRecList, isEnumType, isOptionType) plus isObjectTypeResolved into
## this module; both derive files now use these versions. The canonical
## forms are decode's (isOptionType uses eqIdent so a qualified/aliased
## std/options.Option matches; encode's old `$t[0] == "Option"` was buggy).

import std/macros

proc pragmaHead*(p: NimNode): NimNode {.inline.} =
  ## Extract a pragma's name node — `{.foo.}` is a plain ident,
  ## `{.foo("x").}` is a Call with the ident at [0], `{.foo: "x".}` is
  ## an ExprColonExpr with the ident at [0]. Unify them.
  if p.kind in {nnkCall, nnkExprColonExpr}: p[0]
  else: p

proc hasPragma*(pragmas: seq[NimNode], name: string): bool =
  for p in pragmas:
    if $pragmaHead(p) == name: return true
  false

proc pragmaArg*(pragmas: seq[NimNode], name: string): NimNode =
  ## Return the first argument of pragma `name`, or nil if not present
  ## (or pragma has no argument). Used to read `kdlReserved: "ipv4"` /
  ## `kdlRename: "template"` payloads.
  for p in pragmas:
    if $pragmaHead(p) == name and
       p.kind in {nnkCall, nnkExprColonExpr} and p.len >= 2:
      return p[1]
  nil

proc fieldInfo*(identDefs: NimNode, fieldIdx: int):
    tuple[name: string, pragmas: seq[NimNode]] =
  ## Read (name, pragmas) for the `fieldIdx`-th field of an IdentDefs.
  let fieldNameNode = identDefs[fieldIdx]
  if fieldNameNode.kind == nnkPragmaExpr:
    result.name = $fieldNameNode[0]
    for p in fieldNameNode[1]:
      result.pragmas.add(p)
  else:
    result.name = $fieldNameNode

iterator regularFields*(recList: NimNode):
    tuple[name: string, typ: NimNode, pragmas: seq[NimNode], default: NimNode] =
  ## Walk a RecList yielding plain (non-variant) fields. Variant
  ## structure (RecCase) is handled separately by `findRecCase`.
  ##
  ## `default` is the IdentDefs' trailing default expression (`field = expr`),
  ## or `newEmptyNode()` when the field has no native default. In an
  ## `nnkIdentDefs` the layout is `[name…, type, default]`; `default` is the
  ## last child (`^1`) and is `nnkEmpty` when absent.
  for child in recList:
    if child.kind != nnkIdentDefs: continue
    let fieldType = child[^2]
    let fieldDefault = child[^1]
    for i in 0 ..< child.len - 2:
      let info = fieldInfo(child, i)
      yield (name: info.name, typ: fieldType, pragmas: info.pragmas,
             default: fieldDefault)

proc findRecCase*(recList: NimNode): NimNode =
  ## Return the variant's RecCase node, or nil if the object is not a
  ## variant. KDL derive supports at most one variant per type (the spec
  ## doesn't model nested variants cleanly anyway).
  for child in recList:
    if child.kind == nnkRecCase: return child
  nil

proc innerOfOption*(t: NimNode): NimNode {.inline.} =
  ## Extract the inner T of `Option[T]`.
  t[1]

proc isOptionType*(t: NimNode): bool {.inline.} =
  ## `eqIdent` (not `$t[0] == "Option"`) so a qualified `std/options.Option`
  ## or an aliased import still matches (rfc §8.7 / S0c). Canonical form —
  ## single source of truth for both derive directions.
  t.kind == nnkBracketExpr and t[0].eqIdent("Option")

proc nodeNameOf*(typeSym: NimNode): string =
  ## Read `kdlNode: "name"` pragma or fall back to lowercased type name.
  ## Type-level pragmas live on the TypeDef's pragma node (impl[0] if
  ## attached). `{.kdlNode: "name".}` parses as an ExprColonExpr inside the
  ## pragma list (the colon form is idiomatic); `{.kdlNode("name").}` would
  ## be a Call — both are handled via pragmaHead.
  let impl = typeSym.getImpl
  expectKind(impl, nnkTypeDef)
  let nameNode = impl[0]
  if nameNode.kind == nnkPragmaExpr:
    let pragmas = nameNode[1]
    for p in pragmas:
      let head = pragmaHead(p)
      if $head == "kdlNode" and
         p.kind in {nnkCall, nnkExprColonExpr} and p.len >= 2 and
         p[1].kind == nnkStrLit:
        return p[1].strVal
  result = $typeSym
  for i in 0 ..< result.len:
    if result[i] in {'A'..'Z'}:
      result[i] = char(uint8(result[i]) + 32)

proc objectRecList*(typeSym: NimNode): NimNode =
  ## Return the RecList of `typeSym`'s object (peeling one `ref`).
  let impl = typeSym.getImpl
  let objTy =
    if impl[2].kind == nnkObjectTy: impl[2]
    elif impl[2].kind == nnkRefTy and impl[2][0].kind == nnkObjectTy: impl[2][0]
    else: nil
  doAssert objTy != nil, "deriveCodec: expected an object or ref object type"
  objTy[2]

proc isEnumType*(t: NimNode): bool =
  ## True iff `t`'s underlying type is an enum. Inputs may arrive as the
  ## enum AST itself (nnkEnumTy), a type sym resolving to nnkEnumTy via
  ## getTypeImpl, or a `typeDesc[T]` wrapper (when `t` is the inner of a
  ## BracketExpr like `Option[E]`); unwrap and re-resolve those.
  if t.kind == nnkEnumTy: return true
  try:
    let impl = t.getTypeImpl
    if impl.kind == nnkEnumTy: return true
    if impl.kind == nnkBracketExpr and impl.len >= 2 and $impl[0] == "typeDesc":
      let innerImpl = impl[1].getTypeImpl
      if innerImpl.kind == nnkEnumTy: return true
  except: discard
  false

proc isObjectTypeResolved*(t: NimNode): bool =
  ## True iff `t` resolves (via `getTypeImpl`, following one `ref`) to an
  ## object type. Empirically: primitives → nnkSym, `seq[X]` → nnkBracketExpr,
  ## user object → nnkObjectTy, `ref object` → nnkRefTy→nnkObjectTy. CAVEAT:
  ## `Option[X]` *also* resolves to nnkObjectTy, so the §8.2 inference peels
  ## Option first.
  var impl: NimNode
  try: impl = t.getTypeImpl
  except: return false
  if impl.kind == nnkRefTy: impl = impl[0].getTypeImpl
  impl.kind == nnkObjectTy

proc baseTypeName*(t: NimNode): string =
  ## Resolve a transparent type alias (`type Port = int`) to its
  ## underlying primitive name, so the value dispatch matches on `int`
  ## rather than `Port` (#39 item 5). `getTypeImpl` of an alias sym yields
  ## the underlying sym; distinct types yield `nnkDistinctTy` and are left
  ## as-is (handled — or rejected — by the caller). The bounded loop guards
  ## against pathological alias chains.
  var cur = t
  for _ in 0 ..< 16:
    if cur.kind != nnkSym: break
    let impl = cur.getTypeImpl
    if impl.kind == nnkSym and not impl.eqIdent($cur): cur = impl
    else: break
  $cur
