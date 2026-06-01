/-
  KDL formal-proof track — recursive document fragment (Tier 0, the deep end).

  The first fragment with genuine RECURSION: a node contains a children block
  which contains nodes. Stripped to the essential recursive skeleton — a tree of
  brace-nested nodes (`{}`, `{{}}`, `{{}{}}`, …) — so the proof is about the
  recursion itself, not lexical detail (names/args/Unicode come later).

  The parser is FUEL-based (structurally terminating on the fuel), sidestepping
  the well-founded-termination obligation that output-threaded recursive descent
  otherwise incurs. The round-trip is then a mutual induction on the tree.
-/

namespace Kdl.Doc

mutual
  /-- A node is just its children block (no name/args in this skeleton). -/
  inductive Tree where
    | node : Forest → Tree
  /-- A children block: an ordered list of nodes. -/
  inductive Forest where
    | nil  : Forest
    | cons : Tree → Forest → Forest
end

mutual
  def sizeTree : Tree → Nat
    | .node f => sizeForest f + 1
  def sizeForest : Forest → Nat
    | .nil => 0
    | .cons t f => sizeTree t + sizeForest f + 1
end

mutual
  /-- `node f ↦ "{" ++ render f ++ "}"`. -/
  def renderTree : Tree → List Char
    | .node f => '{' :: (renderForest f ++ ['}'])
  def renderForest : Forest → List Char
    | .nil => []
    | .cons t f => renderTree t ++ renderForest f
end

mutual
  /-- Parse one node: `{` children `}`. -/
  def parseTree : Nat → List Char → Option (Tree × List Char)
    | 0, _ => none
    | fuel + 1, '{' :: rest =>
        match parseForest fuel rest with
        | some (f, '}' :: rest') => some (.node f, rest')
        | _ => none
    | _, _ => none
  /-- Parse a children block: nodes until a `}` or end of input. -/
  def parseForest : Nat → List Char → Option (Forest × List Char)
    | 0, _ => none
    | _ + 1, [] => some (.nil, [])
    | _ + 1, '}' :: rest => some (.nil, '}' :: rest)
    | fuel + 1, toks =>
        match parseTree fuel toks with
        | some (t, rest) =>
            match parseForest fuel rest with
            | some (f, rest') => some (.cons t f, rest')
            | none => none
        | none => none
end

-- One-step unfolding of parseForest on a `{`-led input (the match reduces
-- definitionally because `'{' ≠ '}'`), so `rw` can drive the recursion.
theorem parseForest_brace (fuel : Nat) (Y : List Char) :
    parseForest (fuel + 1) ('{' :: Y) =
      (match parseTree fuel ('{' :: Y) with
       | some (t, r) =>
           (match parseForest fuel r with
            | some (g, r') => some (.cons t g, r')
            | none => none)
       | none => none) := rfl

-- Round-trip, mutually with the forest lemma. A tree parses back for ANY
-- trailing input (it consumes exactly one `{…}`), given enough fuel.
mutual
theorem parseTree_render (t : Tree) (fuel : Nat) (rest : List Char)
    (hf : sizeTree t < fuel) :
    parseTree fuel (renderTree t ++ rest) = some (t, rest) := by
  match t, fuel, hf with
  | .node f, fuel + 1, hf =>
    have hsub : sizeForest f < fuel := by
      simp only [sizeTree] at hf; omega
    have hforest := parseForest_render f fuel ('}' :: rest) hsub (Or.inr ⟨rest, rfl⟩)
    simp only [renderTree, List.cons_append, List.append_assoc, List.singleton_append,
               List.nil_append, parseTree, hforest]
-- A forest parses back when the trailing input does not begin a new node
-- (it is empty or starts with the closing `}`), given enough fuel.
theorem parseForest_render (f : Forest) (fuel : Nat) (rest : List Char)
    (hf : sizeForest f < fuel) (hr : rest = [] ∨ ∃ r, rest = '}' :: r) :
    parseForest fuel (renderForest f ++ rest) = some (f, rest) := by
  match f, fuel, hf with
  | .nil, fuel + 1, _ =>
    simp only [renderForest, List.nil_append]
    rcases hr with h | ⟨r, h⟩ <;> subst h <;> simp [parseForest]
  | .cons t f, fuel + 1, hf =>
    simp only [sizeForest] at hf
    have hst : sizeTree t < fuel := by omega
    have hsf : sizeForest f < fuel := by omega
    have htree := parseTree_render t fuel (renderForest f ++ rest) hst
    have hrest := parseForest_render f fuel rest hsf hr
    -- input = renderTree t ++ (renderForest f ++ rest); starts with '{'
    obtain ⟨g⟩ := t
    simp only [renderForest, renderTree, List.append_assoc, List.cons_append,
               List.singleton_append, List.nil_append] at htree ⊢
    rw [parseForest_brace, htree]
    simp only [hrest]
end

-- Size is bounded by render length, so a string's length is enough fuel.
mutual
theorem sizeTree_le (t : Tree) : sizeTree t < (renderTree t).length := by
  obtain ⟨f⟩ := t
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

/-- Full document parser: a forest with unlimited (size-derived) fuel. -/
def parse (s : List Char) : Option Forest :=
  match parseForest (s.length + 1) s with
  | some (f, []) => some f
  | _ => none

/-- The headline result: every forest round-trips. -/
theorem parse_renderForest (f : Forest) : parse (renderForest f) = some f := by
  unfold parse
  have hb : sizeForest f < (renderForest f).length + 1 := by
    have := sizeForest_le f; omega
  have h := parseForest_render f ((renderForest f).length + 1) [] hb (Or.inl rfl)
  simp only [List.append_nil] at h
  rw [h]

#print axioms parse_renderForest

end Kdl.Doc
