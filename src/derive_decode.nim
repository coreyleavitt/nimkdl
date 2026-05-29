## derive_decode — per-type macro emitting `kdlDecode(v, c)` procs.
##
## The Cat 2 IN codegen path. `deriveDecode(T)` inspects T's structure
## at compile time and emits a proc specialized to T's field shape
## that pulls cursor events and populates a `var T` destination.
##
## ## Target cursor type — concrete StringCursor
##
## Mirrors the deriveEncode-targets-BufferEmitter decision (Stage C
## design notes). The cursor's token-resolution surface (bytes,
## bytesEq, tokenAsString) lives on StringCursor rather than the
## KdlCursor concept; a generic-on-concept derive would either pull
## all of that into the concept or pay an indirection cost per
## per-field lookup. Concrete is cleaner.
##
## ## Result shape
##
## `Result[void, ParseError]`. Caller pre-allocates `var T`; the
## decoder mutates. Aligns with `parser.parse` / `cursor.advance`
## error-path conventions.
##
## ## Stage D buildout
##
## - D1: tracer — single kdlArg string field
## - D2-D15: per docs/branch-rebuild-plan.md

import std/macros

import ./ast
import ./cursor
import ./doc_build  # tokenAsString — single source of truth for token → string
import ./spans

# ---------------------------------------------------------------------------
# Shared AST inspection helpers (mirror those in derive_encode)
# ---------------------------------------------------------------------------

proc pragmaHead(p: NimNode): NimNode {.inline.} =
  if p.kind in {nnkCall, nnkExprColonExpr}: p[0]
  else: p

proc hasPragma(pragmas: seq[NimNode], name: string): bool =
  for p in pragmas:
    if $pragmaHead(p) == name: return true
  false

proc pragmaArg(pragmas: seq[NimNode], name: string): NimNode =
  for p in pragmas:
    if $pragmaHead(p) == name and
       p.kind in {nnkCall, nnkExprColonExpr} and p.len >= 2:
      return p[1]
  nil

proc nodeNameOf(typeSym: NimNode): string =
  ## Read `kdlNode: "name"` pragma or fall back to lowercased type name.
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

proc fieldInfo(identDefs: NimNode, fieldIdx: int):
    tuple[name: string, pragmas: seq[NimNode]] =
  let fieldNameNode = identDefs[fieldIdx]
  if fieldNameNode.kind == nnkPragmaExpr:
    result.name = $fieldNameNode[0]
    for p in fieldNameNode[1]:
      result.pragmas.add(p)
  else:
    result.name = $fieldNameNode

iterator regularFields(recList: NimNode):
    tuple[name: string, typ: NimNode, pragmas: seq[NimNode]] =
  for child in recList:
    if child.kind != nnkIdentDefs: continue
    let fieldType = child[^2]
    for i in 0 ..< child.len - 2:
      let info = fieldInfo(child, i)
      yield (name: info.name, typ: fieldType, pragmas: info.pragmas)

proc objectRecList(typeSym: NimNode): NimNode =
  let impl = typeSym.getImpl
  let objTy =
    if impl[2].kind == nnkObjectTy: impl[2]
    elif impl[2].kind == nnkRefTy and impl[2][0].kind == nnkObjectTy: impl[2][0]
    else: nil
  doAssert objTy != nil, "deriveDecode: expected an object or ref object type"
  objTy[2]

# ---------------------------------------------------------------------------
# Macro
# ---------------------------------------------------------------------------

macro deriveDecode*(T: typedesc): untyped =
  ## Emit `proc kdlDecode(v: var T; c: var StringCursor): Result[void, ParseError]`
  ## specialized to T's field shape. Pulls cursor events, dispatches
  ## each to the right field, returns success or the first error.
  let typeSym = T.getTypeInst[1]
  let wireName = nodeNameOf(typeSym)
  let vSym = ident("v")
  let cSym = ident("c")
  let evSym = ident("ev")
  let evSym2 = ident("ev2")
  let argIdxSym = ident("argIdx")

  # Collect kdlArg fields (positional, in order). D1 supports kdlArg
  # string only — subsequent cycles widen.
  var argFields: seq[tuple[name: string, typ: NimNode]]
  let recList = objectRecList(typeSym)
  for (fieldName, fieldType, pragmas) in regularFields(recList):
    if hasPragma(pragmas, "kdlArg"):
      argFields.add((name: fieldName, typ: fieldType))

  # Build the per-arg dispatch: `case argIdx of 0: v.<f0> = ... 1: ... else: error`
  var argCase = newTree(nnkCaseStmt, argIdxSym)
  for i, (fName, fType) in argFields:
    let fIdent = ident(fName)
    let idxLit = newIntLitNode(i)
    var branchBody: NimNode
    case $fType
    of "string":
      branchBody = quote do:
        `vSym`.`fIdent` = tokenAsString(`cSym`.stream[].tokens[`evSym2`.argTok],
                                        `cSym`.stream[], `cSym`.source)
    else:
      error("deriveDecode (D1): kdlArg field type " & $fType &
            " not yet supported (D2 widens)")
    argCase.add(newTree(nnkOfBranch, idxLit, branchBody))
  # else branch: too many positional args
  argCase.add(newTree(nnkElse,
    quote do:
      return err[void, ParseError](
        initError(peParseUnexpected, `evSym2`.span,
                  "unexpected extra positional argument"))))

  let body = quote do:
    block:
      let `evSym` = advance(`cSym`)
      if `evSym`.kind == ceError:
        return err[void, ParseError](`evSym`.err)
      if `evSym`.kind != ceNodeBegin:
        return err[void, ParseError](
          initError(peParseExpected, `evSym`.span,
                    "expected node begin"))
      let expectedNodeName = `wireName`
      if not bytesEq(`cSym`, `evSym`.nodeNameTok, expectedNodeName):
        return err[void, ParseError](
          initError(peParseExpected, `evSym`.span,
                    "expected node named '" & expectedNodeName & "'"))
      var `argIdxSym` = 0
      while true:
        let `evSym2` = advance(`cSym`)
        case `evSym2`.kind
        of ceArg:
          `argCase`
          inc `argIdxSym`
        of ceNodeEnd:
          break
        of ceError:
          return err[void, ParseError](`evSym2`.err)
        of ceEof:
          return err[void, ParseError](
            initError(peParseExpected, `evSym2`.span,
                      "unexpected EOF inside node"))
        else:
          discard
      return ok(void, ParseError)

  result = newProc(
    name = newIdentNode("kdlDecode"),
    params = @[
      newIdentDefs(ident("__unused_result"), newEmptyNode(),
                   newEmptyNode())  # placeholder; replaced below
    ],
    body = body
  )
  # Re-build params with the correct shape (avoids fighting newProc's
  # awkward result-type-as-first-param convention).
  result.params = newTree(nnkFormalParams,
    nnkBracketExpr.newTree(ident("Result"), ident("void"), ident("ParseError")),
    newIdentDefs(vSym, nnkVarTy.newTree(typeSym)),
    newIdentDefs(cSym, nnkVarTy.newTree(ident("StringCursor")))
  )
