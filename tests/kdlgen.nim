## kdlgen — paired KDL surface generators for spec-coverage testing.
##
## Each generator yields a `ValueSurface` = (text, value): a syntactically
## valid KDL surface form paired with the `KdlValue` it MUST denote. The
## property suite (`test_spec_coverage`) asserts that `parse("node " & text)`
## yields exactly one node with one argument whose value equals `value`.
##
## ## Why a generator is the oracle
##
## No KDL parser fully conforms to the spec (the kdl-org reference misses
## corpus cases too), so a differential against any *parser* can't be ground
## truth. The spec grammar is the only authority. We encode it here in the
## **generation** direction, which is structurally simpler than parsing — no
## ambiguity, no lookahead, no error recovery — so each branch is correct by
## audit against one grammar production. See
## `docs/rfc-spec-coverage-testing.md`.
##
## ## The one non-negotiable
##
## The renderer must NOT call nkdl's encoder/formatter (`emitter`, `numlit`,
## `doc_emit`). It hand-writes its own surface forms so a shared bug cannot
## hide from itself. The float slice is the one sanctioned exception (it leans
## on stdlib `addFloatRoundtrip`, which is not nkdl and tests a different
## algorithm than any encoder).

import proptest
import ../src/ast

type
  ValueSurface* = object
    ## A valid KDL surface form of one value, paired with the value it denotes.
    text*:  string
    value*: KdlValue

func valueEq*(a, b: KdlValue): bool =
  ## Kind + payload equality, ignoring `span` and the (absent for these
  ## generators) `typeAnnotation`. Expanded per slice as value kinds land.
  if a.kind != b.kind: return false
  case a.kind
  of kvInt: a.intVal == b.intVal
  else:     false

# ---------------------------------------------------------------------------
# Slice 1 — decimal integers
# ---------------------------------------------------------------------------

proc decimalIntSurfaces*(): Strategy[ValueSurface] =
  ## Plain base-10 integers, including negatives. Renders via `$` (KDL's
  ## decimal-integer surface is identical to Nim's, so this is independent of
  ## nkdl's own formatter).
  integers(-1_000_000, 1_000_000).map(proc(n: int): ValueSurface =
    ValueSurface(text: $n, value: newIntValue(n.int64)))
