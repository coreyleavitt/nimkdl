/-
  KDL formal-proof track — Tier 0 (see docs/rfc-conformance-assurance.md).

  Tracer: a verified recognizer for the KEYWORD VALUE fragment of KDL
  (§Boolean / §Null / §Keyword Numbers). This is the formal-proof analogue of
  the conformance corpus's "generation < parsing": instead of generating
  (input, expected) pairs and TESTING agreement, we define `render` and `parse`
  and PROVE, for all inputs, that they agree — `∀`, not statistically.

  Two theorems together pin down correctness:
    • completeness (`parse_render`): parse recovers every rendered value.
    • soundness    (`render_parse`): parse succeeds only on a canonical
                                     rendering, returning the value that renders to it.
  Both are axiom-free (see `#print axioms`).

  The fragment is deliberately finite (no Unicode / dedent / recursion) — the
  tracer establishes the toolchain + the render/parse/proof structure that the
  number, string, and document fragments grow into.
-/

namespace Kdl

/-- The keyword values of KDL: booleans, null, and the IEEE-754 keyword numbers. -/
inductive KValue where
  | bool (b : Bool)
  | null
  | inf
  | negInf
  | nan
deriving DecidableEq, Repr

/-- The canonical surface spelling of each keyword value. -/
def render : KValue → String
  | .bool true  => "#true"
  | .bool false => "#false"
  | .null       => "#null"
  | .inf        => "#inf"
  | .negInf     => "#-inf"
  | .nan        => "#nan"

/-- Recognizer for the keyword values; `none` on anything else. -/
def parse (s : String) : Option KValue :=
  if s = "#true" then some (.bool true)
  else if s = "#false" then some (.bool false)
  else if s = "#null" then some .null
  else if s = "#inf" then some .inf
  else if s = "#-inf" then some .negInf
  else if s = "#nan" then some .nan
  else none

/-- COMPLETENESS / round-trip: `parse` recovers every value `render` produces. -/
theorem parse_render (v : KValue) : parse (render v) = some v := by
  cases v with
  | bool b => cases b <;> rfl
  | null   => rfl
  | inf    => rfl
  | negInf => rfl
  | nan    => rfl

/-- SOUNDNESS: if `parse s` succeeds with `v`, then `s` is exactly `render v`.
    So the recognizer accepts only canonical spellings and never lies about the
    value. -/
theorem render_parse (s : String) (v : KValue) (h : parse s = some v) :
    render v = s := by
  unfold parse at h
  repeat' split at h
  all_goals (
    -- taken leaves: `some kv = some v` ⇒ substitute v; `none = some v` leaves
    -- revert the `try` and are closed by `simp_all` (none ≠ some).
    try (injection h with h; subst h)
    simp_all [render])

#print axioms parse_render
#print axioms render_parse

end Kdl
