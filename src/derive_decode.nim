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
import ./lexer      # TokenKind / KeywordKind dispatch in emitted code
import ./numlit     # decodeIntFromToken / decodeFloatFromToken
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

proc emitTypedDecode(targetIdent: NimNode, tokIndexExpr: NimNode,
                     fieldType: NimNode, cSym: NimNode): NimNode =
  ## Emit the typed decode of a token at `tokIndexExpr` into
  ## `targetIdent`. Used by both arg-positional dispatch and
  ## prop-by-key dispatch — single source of truth for token-to-typed
  ## conversion.
  case $fieldType
  of "string":
    return quote do:
      let tok = `cSym`.stream[].tokens[`tokIndexExpr`]
      case tok.kind
      of tkString, tkRawString, tkIdent:
        `targetIdent` = tokenAsString(tok, `cSym`.stream[], `cSym`.source)
      else:
        return err[void, ParseError](
          initError(peTypeMismatch, tok.span, "expected string value"))
  of "int", "int8", "int16", "int32", "int64":
    let typeNode = fieldType
    return quote do:
      let tok = `cSym`.stream[].tokens[`tokIndexExpr`]
      if tok.kind != tkNumber:
        return err[void, ParseError](
          initError(peTypeMismatch, tok.span, "expected integer value"))
      let nPayload = `cSym`.stream[].numberPayloads[tok.numIdx]
      let decoded = decodeIntFromToken(nPayload, tok.span)
      if decoded.isErr:
        return err[void, ParseError](decoded.getErr)
      `targetIdent` = `typeNode`(decoded.get)
  of "float", "float32", "float64":
    let typeNode = fieldType
    return quote do:
      let tok = `cSym`.stream[].tokens[`tokIndexExpr`]
      case tok.kind
      of tkNumber:
        let nPayload = `cSym`.stream[].numberPayloads[tok.numIdx]
        let decoded = decodeFloatFromToken(nPayload, tok.span)
        if decoded.isErr:
          return err[void, ParseError](decoded.getErr)
        `targetIdent` = `typeNode`(decoded.get)
      of tkKeyword:
        case tok.keyword
        of kwInf:    `targetIdent` = `typeNode`(Inf)
        of kwNegInf: `targetIdent` = `typeNode`(NegInf)
        of kwNan:    `targetIdent` = `typeNode`(NaN)
        else:
          return err[void, ParseError](
            initError(peTypeMismatch, tok.span, "expected float value"))
      else:
        return err[void, ParseError](
          initError(peTypeMismatch, tok.span, "expected float value"))
  of "bool":
    return quote do:
      let tok = `cSym`.stream[].tokens[`tokIndexExpr`]
      if tok.kind != tkKeyword:
        return err[void, ParseError](
          initError(peTypeMismatch, tok.span, "expected bool value"))
      case tok.keyword
      of kwTrue:  `targetIdent` = true
      of kwFalse: `targetIdent` = false
      else:
        return err[void, ParseError](
          initError(peTypeMismatch, tok.span, "expected bool value"))
  else:
    error("deriveDecode: field type " & $fieldType &
          " not yet supported (D1-D3 cover string/int/float/bool)")
    return newEmptyNode()

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

  # Collect kdlArg + kdlProp + kdlChild fields by pragma role.
  type ChildKind = enum ckSingle, ckSeq
  var argFields: seq[tuple[name: string, typ: NimNode]]
  var propFields: seq[tuple[name: string, typ: NimNode, wireKey: string]]
  var childFields: seq[tuple[name: string, elemType: NimNode,
                             kind: ChildKind, wireName: string]]
  let recList = objectRecList(typeSym)
  for (fieldName, fieldType, pragmas) in regularFields(recList):
    if hasPragma(pragmas, "kdlArg"):
      argFields.add((name: fieldName, typ: fieldType))
    elif hasPragma(pragmas, "kdlProp"):
      let renameArg = pragmaArg(pragmas, "kdlRename")
      let wireKey =
        if renameArg != nil and renameArg.kind == nnkStrLit:
          renameArg.strVal
        else: fieldName
      propFields.add((name: fieldName, typ: fieldType, wireKey: wireKey))
    elif hasPragma(pragmas, "kdlChild"):
      var kind: ChildKind
      var elemType: NimNode
      if fieldType.kind == nnkBracketExpr and $fieldType[0] == "seq":
        kind = ckSeq
        elemType = fieldType[1]
      else:
        kind = ckSingle
        elemType = fieldType
      let elemWire = nodeNameOf(elemType)
      childFields.add((name: fieldName, elemType: elemType, kind: kind,
                       wireName: elemWire))

  # Build the per-arg dispatch.
  var argCase = newTree(nnkCaseStmt, argIdxSym)
  for i, (fName, fType) in argFields:
    let fIdent = ident(fName)
    let idxLit = newIntLitNode(i)
    let tokIndexExpr = quote do: `evSym2`.argTok
    let target = quote do: `vSym`.`fIdent`
    let branchBody = emitTypedDecode(target, tokIndexExpr, fType, cSym)
    argCase.add(newTree(nnkOfBranch, idxLit, branchBody))
  argCase.add(newTree(nnkElse,
    quote do:
      return err[void, ParseError](
        initError(peParseUnexpected, `evSym2`.span,
                  "unexpected extra positional argument"))))

  # Build the per-prop dispatch: bytesEq if-elif chain.
  # bytesEq's `unsafeAddr s[0]` needs an addressable location; we lift
  # each prop key literal to a `let` at proc-entry scope so the
  # comparisons see a real address. The lets live in `propKeyLets`
  # and are spliced into the proc body before the event loop.
  var propKeyLets = newStmtList()
  var propKeySyms: seq[NimNode]
  for (_, _, wireKey) in propFields:
    let sym = genSym(nskLet, "expectedPropKey")
    let lit = newStrLitNode(wireKey)
    propKeyLets.add(quote do:
      let `sym` = `lit`)
    propKeySyms.add(sym)
  # Same lift for child wire-names — bytesEq against an addressable let.
  var childKeyLets = newStmtList()
  var childKeySyms: seq[NimNode]
  for (_, _, _, wireName) in childFields:
    let sym = genSym(nskLet, "expectedChildName")
    let lit = newStrLitNode(wireName)
    childKeyLets.add(quote do:
      let `sym` = `lit`)
    childKeySyms.add(sym)
  var propDispatch = newStmtList()
  if propFields.len > 0:
    var rootIf: NimNode = nil
    for i, (fName, fType, _) in propFields:
      let fIdent = ident(fName)
      let keySym = propKeySyms[i]
      let tokIndexExpr = quote do: `evSym2`.propValueTok
      let target = quote do: `vSym`.`fIdent`
      let decodeBody = emitTypedDecode(target, tokIndexExpr, fType, cSym)
      let branchCond = quote do: bytesEq(`cSym`, `evSym2`.propKeyTok, `keySym`)
      let branchBody = decodeBody
      if rootIf.isNil:
        rootIf = newNimNode(nnkIfStmt)
        rootIf.add(newNimNode(nnkElifBranch).add(branchCond).add(branchBody))
      else:
        rootIf.add(newNimNode(nnkElifBranch).add(branchCond).add(branchBody))
    rootIf.add(newNimNode(nnkElse).add(quote do:
      return err[void, ParseError](
        initError(peParseUnexpected, `evSym2`.span,
                  "unknown property"))))
    propDispatch.add(rootIf)
  else:
    propDispatch.add(quote do:
      return err[void, ParseError](
        initError(peParseUnexpected, `evSym2`.span,
                  "unexpected property")))

  # Build the per-child dispatch (used inside the ceChildrenBegin loop).
  let nextEvSym = ident("nextEv")
  let childPeekSym = ident("childPeek")
  var childDispatchBody: NimNode
  if childFields.len > 0:
    var rootIf: NimNode = nil
    for i, (fName, _, kind, _) in childFields:
      let fIdent = ident(fName)
      let keySym = childKeySyms[i]
      let cond = quote do:
        bytesEq(`cSym`, `childPeekSym`.nodeNameTok, `keySym`)
      let body =
        case kind
        of ckSingle:
          quote do:
            let r = kdlDecode(`vSym`.`fIdent`, `cSym`)
            if r.isErr: return r
        of ckSeq:
          # Append a fresh element to the seq, decode into it.
          let elemSym = genSym(nskVar, "childElem")
          let elemType = childFields[i].elemType
          quote do:
            var `elemSym`: `elemType`
            let r = kdlDecode(`elemSym`, `cSym`)
            if r.isErr: return r
            `vSym`.`fIdent`.add(`elemSym`)
      if rootIf.isNil:
        rootIf = newNimNode(nnkIfStmt)
        rootIf.add(newNimNode(nnkElifBranch).add(cond).add(body))
      else:
        rootIf.add(newNimNode(nnkElifBranch).add(cond).add(body))
    rootIf.add(newNimNode(nnkElse).add(quote do:
      # Unknown child name — skip its subtree (we already peeked it,
      # so consume via skip after advance).
      skip(`cSym`)))
    childDispatchBody = rootIf
  else:
    childDispatchBody = quote do:
      skip(`cSym`)

  let body = quote do:
    block:
      `propKeyLets`
      `childKeyLets`
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
        of ceProp:
          `propDispatch`
        of ceChildrenBegin:
          # Inner child-loop: drives until ceChildrenEnd. For each
          # ceNodeBegin we peek (so the recursive kdlDecode can read
          # the ceNodeBegin itself), dispatch by wire-name, and
          # recurse. Unknown names get skip()'d.
          while true:
            let `childPeekSym` = peek(`cSym`)
            case `childPeekSym`.kind
            of ceChildrenEnd:
              discard advance(`cSym`)
              break
            of ceNodeBegin:
              `childDispatchBody`
            of ceEof:
              return err[void, ParseError](
                initError(peParseExpected, `childPeekSym`.span,
                          "unexpected EOF in children block"))
            of ceError:
              discard advance(`cSym`)
              return err[void, ParseError](`childPeekSym`.err)
            else:
              discard advance(`cSym`)
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
