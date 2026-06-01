/-
  KDL formal-proof track — multiline DEDENT (Tier 0, the hardest lexical piece).

  A multi-line string strips the closing line's whitespace prefix from every
  content line (§Multi-line String). This file verifies the DEDENT OPERATION
  itself — the genuinely novel algorithm — independent of the surrounding `"""`
  framing: given the prefix `p` (which the full parser reads off the closing
  line) and lines each rendered as `p ++ line`, dedenting recovers the lines
  exactly, for every prefix and every set of lines.

  The remaining wrapper (discover `p` from the closing line, split the body on
  newlines, re-assemble) is plumbing around this core; it is the next step.
-/

namespace Kdl.Dedent

/-- Strip a known prefix `p` from the front of `s` (`none` if it doesn't match). -/
def stripPrefix : List Char → List Char → Option (List Char)
  | [], s => some s
  | _ :: _, [] => none
  | a :: p, c :: s => if a = c then stripPrefix p s else none

/-- Stripping a genuine prefix always succeeds and removes exactly it. -/
theorem stripPrefix_app (p l : List Char) : stripPrefix p (p ++ l) = some l := by
  induction p with
  | nil => rfl
  | cons a p ih => simp [stripPrefix, ih]

/-- The dedent operation: strip the prefix `p` from EVERY line; fail if any line
    lacks it (the spec requires every content line to carry the prefix). -/
def dedent (p : List Char) : List (List Char) → Option (List (List Char))
  | [] => some []
  | l :: ls =>
      match stripPrefix p l, dedent p ls with
      | some l', some ls' => some (l' :: ls')
      | _, _ => none

/-- DEDENT round-trip: indenting every line by `p` and then dedenting by `p`
    recovers the original lines — for every prefix and every document body. -/
theorem dedent_render (p : List Char) (lines : List (List Char)) :
    dedent p (lines.map (fun l => p ++ l)) = some lines := by
  induction lines with
  | nil => rfl
  | cons l ls ih => simp [dedent, stripPrefix_app p l, ih]

#print axioms dedent_render

end Kdl.Dedent
