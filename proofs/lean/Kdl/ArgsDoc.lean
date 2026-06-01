/-
  KDL formal-proof track — node with ARGS (Tier 0).

  Next combine after NamedDoc: a node now has a name AND a list of argument
  characters, rendering `name args… { children }` (e.g. `axy{b{}}` = node 'a'
  with args ['x','y'] and one child 'b'). The new ingredient is a VARIABLE-LENGTH
  content list, parsed as a run up to the `{` delimiter (`takeArgs`).

  Names and args must avoid `{`/`}` (well-formedness, threaded through). Parser
  is fuel-based; proof is mutual induction as before, plus the `takeArgs` run lemma.
-/

namespace Kdl.ArgsDoc

mutual
  inductive Tree where
    | node : Char → List Char → Forest → Tree
  inductive Forest where
    | nil  : Forest
    | cons : Tree → Forest → Forest
end

mutual
  def treeWF : Tree → Prop
    | .node c args f =>
        c ≠ '{' ∧ c ≠ '}' ∧ (∀ a ∈ args, a ≠ '{' ∧ a ≠ '}') ∧ forestWF f
  def forestWF : Forest → Prop
    | .nil => True
    | .cons t f => treeWF t ∧ forestWF f
end

mutual
  def sizeTree : Tree → Nat
    | .node _ _ f => sizeForest f + 1
  def sizeForest : Forest → Nat
    | .nil => 0
    | .cons t f => sizeTree t + sizeForest f + 1
end

mutual
  def renderTree : Tree → List Char
    | .node c args f => c :: (args ++ '{' :: (renderForest f ++ ['}']))
  def renderForest : Forest → List Char
    | .nil => []
    | .cons t f => renderTree t ++ renderForest f
end

/-- Split a list at the first `{`: `(chars before, the `{`-led remainder)`. -/
def takeArgs : List Char → List Char × List Char
  | [] => ([], [])
  | c :: rest =>
      if c = '{' then ([], c :: rest)
      else let p := takeArgs rest; (c :: p.1, p.2)

/-- A `{`-free run, then a `{`-led tail, splits exactly. -/
theorem takeArgs_app (args X : List Char) (h : ∀ a ∈ args, a ≠ '{') :
    takeArgs (args ++ '{' :: X) = (args, '{' :: X) := by
  induction args with
  | nil => rfl
  | cons c cs ih =>
    have hc : c ≠ '{' := h c (by simp)
    have ih' := ih (fun a ha => h a (by simp [ha]))
    simp [takeArgs, hc, ih']

mutual
  def parseTree : Nat → List Char → Option (Tree × List Char)
    | 0, _ => none
    | _ + 1, [] => none
    | fuel + 1, c :: rest =>
        if c = '{' ∨ c = '}' then none
        else
          let (args, rest2) := takeArgs rest
          match rest2 with
          | '{' :: rest3 =>
              match parseForest fuel rest3 with
              | some (f, '}' :: rest4) => some (.node c args f, rest4)
              | _ => none
          | _ => none
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

theorem parseForest_node (fuel : Nat) (c : Char) (rest : List Char) (hc : c ≠ '}') :
    parseForest (fuel + 1) (c :: rest) =
      (match parseTree fuel (c :: rest) with
       | some (t, r) =>
           (match parseForest fuel r with
            | some (f, r') => some (.cons t f, r')
            | none => none)
       | none => none) := by
  simp only [parseForest, if_neg hc]

mutual
theorem sizeTree_le (t : Tree) : sizeTree t < (renderTree t).length := by
  obtain ⟨c, args, f⟩ := t
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
  | .node c args g, fuel + 1, hf =>
    obtain ⟨hc1, hc2, hargs, hwfg⟩ := hwf
    have hsub : sizeForest g < fuel := by simp only [sizeTree] at hf; omega
    have hforest := parseForest_render g fuel ('}' :: rest) hwfg hsub (Or.inr ⟨rest, rfl⟩)
    have hnb : ¬ (c = '{' ∨ c = '}') := fun h => h.elim hc1 hc2
    have hta := takeArgs_app args (renderForest g ++ '}' :: rest)
      (fun a ha => (hargs a ha).1)
    simp only [renderTree, List.cons_append, List.append_assoc, List.singleton_append,
               List.nil_append, parseTree, if_neg hnb, hta, hforest]
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
    obtain ⟨c, args, g⟩ := t
    obtain ⟨_, hc, _, _⟩ := hwft
    simp only [renderForest, renderTree, List.append_assoc, List.cons_append,
               List.singleton_append, List.nil_append] at htree ⊢
    rw [parseForest_node _ _ _ hc, htree]
    simp only [hrest]
end

def parse (s : List Char) : Option Forest :=
  match parseForest (s.length + 1) s with
  | some (f, []) => some f
  | _ => none

/-- Every well-formed forest round-trips — now with named, arg-bearing nodes. -/
theorem parse_renderForest (f : Forest) (hwf : forestWF f) :
    parse (renderForest f) = some f := by
  unfold parse
  have hb : sizeForest f < (renderForest f).length + 1 := by
    have := sizeForest_le f; omega
  have h := parseForest_render f ((renderForest f).length + 1) [] hwf hb (Or.inl rfl)
  simp only [List.append_nil] at h
  rw [h]

#print axioms parse_renderForest

end Kdl.ArgsDoc
