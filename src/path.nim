## path — typed schema-path DSL.
##
## ## Why it exists
##
## After `parse[T]` (#528) turns KDL documents into real Nim types, "query"
## is just typed field access. This module adds the convenience layer that
## makes filter+access chains read as a single expression — and, more
## importantly, **catches field-name typos at compile time** with Nim's
## standard "undeclared field; did you mean ...?" diagnostic.
##
## That property is the headline differentiator over every other config-
## language query system. KQL, JSON Path, jq, CUE all defer typo detection
## to runtime ("empty result", surprise). The Nim macro lowers to direct
## field access, so a misspelled `enabel` is the same compile error you'd
## get from writing `r.enabel` by hand.
##
## ## Surface
##
## ```nim
## # Pattern 1: filter + terminal field on seq[T]
## for tpl in path(rules, [it.enabled].template):
##   process(tpl)
##
## # Pattern 2: typed-iterator chain (no macro needed)
## for r in rules.where(it.enabled):
##   process(r.template)
##
## # Pattern 3: native Nim pattern matching (free; document in README)
## # See std/fusion/matching or `gara`.
## ```
##
## ## Implementation
##
## `path(receiver, expr)` is a macro. It walks `expr` as Nim AST:
##
##   - `[predicate]`     — filter; `it` binds to current element
##   - `.field`          — access field on each surviving element
##   - terminal step     — yielded by the resulting iterator
##
## The macro emits an inline iterator that's equivalent to writing the
## filter + field chain by hand. Field access goes through Nim's normal
## typecheck, so misspellings produce the standard "undeclared field"
## diagnostic with the standard suggestion list.

import std/macros

# ---------------------------------------------------------------------------
# The simple typed-iterator chain (Style 2 from #534)
# ---------------------------------------------------------------------------

template where*(items, cond: untyped): untyped =
  ## `items.where(it.enabled)` — yields elements where the body
  ## evaluates true, with `it` auto-bound to the current element.
  ##
  ## Compile-time-typed: a misspelled field on `it` produces Nim's
  ## standard `undeclared field` diagnostic with suggestion list.
  iterator anon(): auto {.gensym.} =
    for it {.inject.} in items:
      if cond:
        yield it
  anon()

template first*(items, cond: untyped): untyped =
  ## First element matching `cond`, or `default(...)` if none.
  block:
    var found = default(typeof(items[0]))
    for it {.inject.} in items:
      if cond:
        found = it
        break
    found

template only*(items: untyped): untyped =
  ## Asserts the seq has exactly one element and returns it.
  doAssert items.len == 1,
    "only: expected exactly one element, got " & $items.len
  items[0]

# ---------------------------------------------------------------------------
# The path{} macro (Style 1)
# ---------------------------------------------------------------------------

macro path*(source: typed; expr: untyped): untyped =
  ## Walk `expr` as a chain of `[predicate]` filters and `.field`
  ## accesses, producing an iterator over the resulting values.
  ##
  ## ```nim
  ## # Filter by `enabled`, yield each surviving rule's `template`:
  ## for tpl in path(rules, [it.enabled].template):
  ##   process(tpl)
  ## ```
  ##
  ## **Compile-time typo detection.** Misspell `enabled` and Nim's
  ## normal field-resolution diagnoses it — there is no runtime
  ## fallback that would silently return nothing.
  ##
  ## Currently supports a single optional predicate followed by a
  ## single-or-multi field-access chain. Deeply nested
  ## children/predicates can use `.where(...).field` chains
  ## instead — same compile-time properties, less novel syntax.

  # Parse `expr` as ([predicate])? (.field)*
  var predicate: NimNode = nil
  var fieldChain: seq[NimNode] = @[]

  proc collect(node: NimNode) =
    case node.kind
    of nnkBracket:
      # `[predicate]` parses as an nnkBracket (array literal) at the
      # head of a chain, e.g. `[it.enabled].id`. A subscript on an
      # earlier expression — e.g. `rules[0]` — would be nnkBracketExpr;
      # we don't support indexing in v0.1.
      if node.len != 1:
        error("path: expected [predicate] with one expression, got " &
              node.repr, node)
      if predicate != nil:
        error("path: only one [predicate] per chain in v0.1; chain " &
              ".where(...) calls for multiple", node)
      predicate = node[0]
    of nnkBracketExpr:
      # `<chain>[predicate]` — predicate appended to an earlier path
      # head. Recurse into LHS, then capture the predicate.
      if node.len != 2:
        error("path: expected [predicate], got " & node.repr, node)
      if predicate != nil:
        error("path: only one [predicate] per chain in v0.1", node)
      collect(node[0])
      predicate = node[1]
    of nnkDotExpr:
      collect(node[0])
      fieldChain.add(node[1])
    of nnkIdent, nnkSym:
      fieldChain.add(node)
    else:
      error("path: unexpected " & $node.kind & " in path expression",
            node)

  collect(expr)
  # collect builds the chain in source order already (recursing into the
  # dotExpr's LHS first, then appending the rhs); no reverse needed.

  # First field is field-on-element; rest are sub-fields chained.
  let itSym = ident("it")
  var accessExpr: NimNode = itSym
  for f in fieldChain:
    accessExpr = newDotExpr(accessExpr, f)

  let predExpr =
    if predicate != nil: predicate
    else: newLit(true)

  # Manual collect-into-seq. The yield type is computed via a
  # `typeof(block: ...)` expression that declares `it` with the same
  # symbol used inside `accessExpr`, so the same name binds in both
  # the type computation and the runtime loop.
  let resultSym = genSym(nskVar, "pathResult")
  result = quote do:
    block:
      var `resultSym`: seq[(typeof(block:
        var `itSym`: typeof(`source`[0])
        `accessExpr`))] = @[]
      for `itSym` in `source`:
        if `predExpr`:
          `resultSym`.add(`accessExpr`)
      `resultSym`
