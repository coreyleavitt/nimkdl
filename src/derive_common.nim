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

proc splitWords*(name: string): seq[string] =
  ## Macro-time camelCase/PascalCase/acronym word splitter — the shared
  ## engine behind the default-node-name fallback (S2a) and the
  ## `kdlRenameAll` convention join (S2b). Pure; no allocation beyond the
  ## result seq.
  ##
  ## Boundary rules (standard acronym-aware split):
  ##  - before an uppercase that follows a lowercase or digit
  ##    (`myService` → my|Service, `parseURL2x`… digit handled below);
  ##  - before an uppercase that is followed by a lowercase when the
  ##    preceding char is also uppercase — i.e. the last letter of an
  ##    acronym run that actually begins the next word
  ##    (`HTTPServer` → HTTP|Server, `IOError` → IO|Error);
  ##  - digit runs stay glued to the preceding word
  ##    (`Service2` → ["Service2"], not ["Service", "2"]).
  ##
  ## Non-letter/non-digit chars (e.g. `_`) act as hard separators and are
  ## dropped; empty words are never emitted.
  if name.len == 0: return
  var cur = ""
  template flush() =
    if cur.len > 0:
      result.add(cur)
      cur = ""
  for i in 0 ..< name.len:
    let c = name[i]
    if c notin {'A'..'Z', 'a'..'z', '0'..'9'}:
      flush()
      continue
    if c in {'A'..'Z'} and cur.len > 0:
      let prev = name[i-1]
      let prevLower = prev in {'a'..'z', '0'..'9'}
      let nextLower = i + 1 < name.len and name[i+1] in {'a'..'z'}
      if prevLower or (prev in {'A'..'Z'} and nextLower):
        # boundary: start a new word at this uppercase
        flush()
    cur.add(c)
  flush()

proc toKebab*(words: seq[string]): string =
  ## Lowercase each word and join with '-'. Companion to `splitWords`.
  for wi, w in words:
    if wi > 0: result.add('-')
    for c in w:
      if c in {'A'..'Z'}: result.add(char(uint8(c) + 32))
      else: result.add(c)

proc capitalizeWord(w: string): string =
  ## Uppercase the first letter, lowercase the rest. Pure; ASCII only
  ## (KDL identifiers + Nim field names are ASCII in practice).
  for i, c in w:
    if i == 0 and c in {'a'..'z'}: result.add(char(uint8(c) - 32))
    elif i > 0 and c in {'A'..'Z'}: result.add(char(uint8(c) + 32))
    else: result.add(c)

proc lowerWord(w: string): string =
  for c in w:
    if c in {'A'..'Z'}: result.add(char(uint8(c) + 32))
    else: result.add(c)

proc upperWord(w: string): string =
  for c in w:
    if c in {'a'..'z'}: result.add(char(uint8(c) - 32))
    else: result.add(c)

proc toCamel*(words: seq[string]): string =
  ## camelCase: first word lowercased, the rest Capitalized, no separator.
  ## `["max","Retries"] → maxRetries`. Companion to `splitWords` (S2b).
  for wi, w in words:
    if wi == 0: result.add(lowerWord(w))
    else: result.add(capitalizeWord(w))

proc toPascal*(words: seq[string]): string =
  ## PascalCase: every word Capitalized, no separator.
  ## `["max","Retries"] → MaxRetries`.
  for w in words:
    result.add(capitalizeWord(w))

proc toSnake*(words: seq[string]): string =
  ## snake_case: lowercase each word, join with '_'.
  ## `["max","Retries"] → max_retries`.
  for wi, w in words:
    if wi > 0: result.add('_')
    result.add(lowerWord(w))

proc toScreamingSnake*(words: seq[string]): string =
  ## SCREAMING_SNAKE_CASE: uppercase each word, join with '_'.
  ## `["max","Retries"] → MAX_RETRIES`.
  for wi, w in words:
    if wi > 0: result.add('_')
    result.add(upperWord(w))

proc wireKeyOf*(fieldName: string, pragmas: seq[NimNode],
                convention: string): string =
  ## Single resolver for a field's canonical wire key (rfc §3.5.3). Pure;
  ## unit-tested directly.
  ##
  ## Precedence: an explicit `{.kdlRename: "x".}` WINS — it sets the exact
  ## wire bytes and the convention is ignored. Otherwise the (non-empty,
  ## non-`kcVerbatim`) `convention` string is applied to `fieldName` via the
  ## case engine. `convention` is the `KdlNamingConvention` enum value's
  ## identifier as a string (e.g. "kcKebabCase"), read off the type's
  ## `{.kdlRenameAll.}` pragma by the caller; "" or "kcVerbatim" → verbatim.
  let renameArg = pragmaArg(pragmas, "kdlRename")
  if renameArg != nil and renameArg.kind == nnkStrLit:
    return renameArg.strVal
  case convention
  of "", "kcVerbatim": fieldName
  of "kcKebabCase": toKebab(splitWords(fieldName))
  of "kcCamelCase": toCamel(splitWords(fieldName))
  of "kcSnakeCase": toSnake(splitWords(fieldName))
  of "kcPascalCase": toPascal(splitWords(fieldName))
  of "kcScreamingSnakeCase": toScreamingSnake(splitWords(fieldName))
  else:
    error("kdlRenameAll: unknown naming convention '" & convention & "'")

proc typeConventionOf*(typeSym: NimNode): string =
  ## Read the type-level `{.kdlRenameAll: kcX.}` pragma's argument as a
  ## string (e.g. "kcKebabCase"), or "" if the type has no such pragma.
  ## Threaded into `wireKeyOf` as the `convention` for every field. The
  ## pragma value parses as an `nnkExprColonExpr` (the colon form) or an
  ## `nnkCall` (the paren form); the ident at [1] is the enum value.
  let impl = typeSym.getImpl
  expectKind(impl, nnkTypeDef)
  let nameNode = impl[0]
  if nameNode.kind == nnkPragmaExpr:
    for p in nameNode[1]:
      let head = pragmaHead(p)
      if $head == "kdlRenameAll" and
         p.kind in {nnkCall, nnkExprColonExpr} and p.len >= 2:
        return $p[1]
  ""

proc nodeNameOf*(typeSym: NimNode): string =
  ## Read `kdlNode: "name"` pragma or fall back to the type name run through
  ## acronym-aware word-split → kebab-case (`HTTPServer → http-server`; S2a).
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
  # S2a: acronym-aware word split → kebab. `HTTPServer → http-server`,
  # `MyService → my-service`, `IOError → io-error` (was: lowercase every char,
  # which produced `httpserver`). BREAKING for un-`kdlNode`'d multi-word types.
  result = toKebab(splitWords($typeSym))

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
