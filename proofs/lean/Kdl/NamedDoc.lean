/-
  KDL formal-proof track — named recursive document (Tier 0).

  Combines RECURSION (Doc.lean) with node CONTENT: each node now carries a name
  character, so a node renders as `name { children }` (e.g. `a{b{}c{}}`). This is
  the step from the brace-only skeleton toward the real KDL node grammar.

  Names must avoid `{` and `}` (else the surface is ambiguous); that is the
  well-formedness predicate `treeWF`/`forestWF`, threaded through the mutual
  round-trip. Parser is fuel-based; proof is mutual induction, as in Doc.lean.
-/

namespace Kdl.NamedDoc

mutual
  inductive Tree where
    | node : Char → Forest → Tree
  inductive Forest where
    | nil  : Forest
    | cons : Tree → Forest → Forest
end

-- Well-formedness: every node name avoids the brace delimiters.
mutual
  def treeWF : Tree → Prop
    | .node c f => c ≠ '{' ∧ c ≠ '}' ∧ forestWF f
  def forestWF : Forest → Prop
    | .nil => True
    | .cons t f => treeWF t ∧ forestWF f
end

mutual
  def sizeTree : Tree → Nat
    | .node _ f => sizeForest f + 1
  def sizeForest : Forest → Nat
    | .nil => 0
    | .cons t f => sizeTree t + sizeForest f + 1
end

mutual
  def renderTree : Tree → List Char
    | .node c f => c :: '{' :: (renderForest f ++ ['}'])
  def renderForest : Forest → List Char
    | .nil => []
    | .cons t f => renderTree t ++ renderForest f
end

mutual
  def parseTree : Nat → List Char → Option (Tree × List Char)
    | 0, _ => none
    | fuel + 1, c :: '{' :: rest =>
        if c = '{' ∨ c = '}' then none
        else
          match parseForest fuel rest with
          | some (f, '}' :: rest') => some (.node c f, rest')
          | _ => none
    | _, _ => none
  def parseForest : Nat → List Char → Option (Forest × List Char)
    | 0, _ => none
    | _ + 1, [] => some (.nil, [])
    | fuel + 1, c :: rest =>
        if c = '}' then some (.nil, c :: rest)
        else
          match parseTree fuel (c :: rest) with
          | some (t, r) =>
              match parseForest fuel r with
              | some (f, r') => some (.cons t f, r')
              | none => none
          | none => none
end

-- One-step unfolding of parseForest on a non-`}` head, so `rw` can drive it.
theorem parseForest_node (fuel : Nat) (c : Char) (rest : List Char) (hc : c ≠ '}') :
    parseForest (fuel + 1) (c :: rest) =
      (match parseTree fuel (c :: rest) with
       | some (t, r) =>
           (match parseForest fuel r with
            | some (f, r') => some (.cons t f, r')
            | none => none)
       | none => none) := by
  simp only [parseForest, if_neg hc]

-- Size is bounded by render length, so the input length is enough fuel.
mutual
theorem sizeTree_le (t : Tree) : sizeTree t < (renderTree t).length := by
  obtain ⟨c, f⟩ := t
  have := sizeForest_le f
  simp only [sizeTree, renderTree, List.length_cons, List.length_append]
  omega
theorem sizeForest_le (f : Forest) : sizeForest f ≤ (renderForest f).length := by
  match f with
  | .nil => simp [sizeForest, renderForest]
  | .cons t f =>
    have := sizeTree_le t
    have := sizeForest_le f
    simp only [sizeForest, renderForest, List.length_append]
    omega
end

mutual
theorem parseTree_render (t : Tree) (fuel : Nat) (rest : List Char)
    (hwf : treeWF t) (hf : sizeTree t < fuel) :
    parseTree fuel (renderTree t ++ rest) = some (t, rest) := by
  match t, fuel, hf with
  | .node c f, fuel + 1, hf =>
    obtain ⟨hc1, hc2, hwff⟩ := hwf
    have hsub : sizeForest f < fuel := by simp only [sizeTree] at hf; omega
    have hforest := parseForest_render f fuel ('}' :: rest) hwff hsub (Or.inr ⟨rest, rfl⟩)
    have hnb : ¬ (c = '{' ∨ c = '}') := fun h => h.elim hc1 hc2
    simp only [renderTree, List.cons_append, List.append_assoc, List.singleton_append,
               List.nil_append, parseTree, if_neg hnb, hforest]
theorem parseForest_render (f : Forest) (fuel : Nat) (rest : List Char)
    (hwf : forestWF f) (hf : sizeForest f < fuel) (hr : rest = [] ∨ ∃ r, rest = '}' :: r) :
    parseForest fuel (renderForest f ++ rest) = some (f, rest) := by
  match f, fuel, hf with
  | .nil, fuel + 1, _ =>
    simp only [renderForest, List.nil_append]
    rcases hr with h | ⟨r, h⟩ <;> subst h <;> simp [parseForest]
  | .cons t f, fuel + 1, hf =>
    obtain ⟨hwft, hwff⟩ := hwf
    simp only [sizeForest] at hf
    have hst : sizeTree t < fuel := by omega
    have hsf : sizeForest f < fuel := by omega
    have htree := parseTree_render t fuel (renderForest f ++ rest) hwft hst
    have hrest := parseForest_render f fuel rest hwff hsf hr
    obtain ⟨c, g⟩ := t
    obtain ⟨_, hc, _⟩ := hwft
    simp only [renderForest, renderTree, List.append_assoc, List.cons_append,
               List.singleton_append, List.nil_append] at htree ⊢
    rw [parseForest_node _ _ _ hc, htree]
    simp only [hrest]
end

/-- Full parser: a forest with input-length fuel. -/
def parse (s : List Char) : Option Forest :=
  match parseForest (s.length + 1) s with
  | some (f, []) => some f
  | _ => none

/-- The headline result: every WELL-FORMED forest round-trips. -/
theorem parse_renderForest (f : Forest) (hwf : forestWF f) :
    parse (renderForest f) = some f := by
  unfold parse
  have hb : sizeForest f < (renderForest f).length + 1 := by
    have := sizeForest_le f; omega
  have h := parseForest_render f ((renderForest f).length + 1) [] hwf hb (Or.inl rfl)
  simp only [List.append_nil] at h
  rw [h]

#print axioms parse_renderForest

end Kdl.NamedDoc
