## derive_common — shared macro helpers for the Cat-2 typed-derive layer
## (deriveDecode/deriveEncode).
##
## Single source of truth — see rfc-derive-vocabulary.md S0a.
##
## Only the helpers that are SEMANTICALLY IDENTICAL between derive_decode
## and derive_encode live here. Helpers that still differ between the two
## (nodeNameOf, objectRecList, isEnumType, isOptionType) remain local to
## each file until a later slice (S0c) unifies them.

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
