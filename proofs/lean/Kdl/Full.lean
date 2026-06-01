/-
  KDL formal-proof track — INTEGRATED recognizer (Tier 0).

  The "full proof": one grammar, one parser, one round-trip theorem — combining
  the proven patterns into a coherent KDL core. A document is a list of nodes;
  a node has an identifier name, a list of STRING-valued arguments, and recursive
  children:  `name "arg1" "arg2" { children }`.

  This integrates: identifiers (name char), typed values (quoted strings, with
  the takeStr run-lemma), a space-separated VALUE LIST (parseArgs), and the
  recursive document structure (fuel-based mutual recursion) — all in one
  end-to-end `parse (renderForest f) = some f` for every well-formed document.

  (Single value kind = quoted string; numbers/barewords are the obvious widening.)
-/

namespace Kdl.Full

-- ===========================================================================
-- Values: quoted strings.
-- ===========================================================================

/-- A delimiter that ends a bareword: space, brace, or quote. -/
def isSpecial (c : Char) : Bool := c = ' ' || c = '{' || c = '}' || c = '"'

inductive Value where
  | str  : List Char → Value     -- quoted string
  | word : List Char → Value     -- bareword (nonempty run of non-special chars)

def renderValue : Value → List Char
  | .str s  => '"' :: (s ++ ['"'])
  | .word w => w

def valueWF : Value → Prop
  | .str s  => ∀ c ∈ s, c ≠ '"'
  | .word w => w ≠ [] ∧ ∀ c ∈ w, isSpecial c = false

/-- Read up to the first `"`. -/
def takeStr : List Char → Option (List Char × List Char)
  | [] => none
  | c :: rest => if c = '"' then some ([], rest) else (takeStr rest).map (fun p => (c :: p.1, p.2))

theorem takeStr_app (s rest : List Char) (h : ∀ c ∈ s, c ≠ '"') :
    takeStr (s ++ '"' :: rest) = some (s, rest) := by
  induction s with
  | nil => simp [takeStr]
  | cons c cs ih =>
    have hc : c ≠ '"' := h c (by simp)
    simp [takeStr, hc, ih (fun a ha => h a (by simp [ha]))]

/-- Read a bareword: a run of non-special chars, stopping at the first delimiter. -/
def takeWord : List Char → List Char × List Char
  | [] => ([], [])
  | c :: rest => if isSpecial c then ([], c :: rest) else let p := takeWord rest; (c :: p.1, p.2)

theorem takeWord_app (w rest : List Char) (hw : ∀ c ∈ w, isSpecial c = false)
    (hr : rest = [] ∨ ∃ c r, rest = c :: r ∧ isSpecial c = true) :
    takeWord (w ++ rest) = (w, rest) := by
  induction w with
  | nil =>
    simp only [List.nil_append]
    rcases hr with h | ⟨c, r, heq, hs⟩
    · subst h; rfl
    · subst heq; simp [takeWord, hs]
  | cons c cs ih =>
    have hc : isSpecial c = false := hw c (by simp)
    have ih' := ih (fun a ha => hw a (by simp [ha]))
    simp [takeWord, hc, ih']

def parseValue : List Char → Option (Value × List Char)
  | [] => none
  | c :: rest =>
      if c = '"' then (takeStr rest).map (fun p => (Value.str p.1, p.2))
      else if isSpecial c then none
      else let p := takeWord (c :: rest); some (.word p.1, p.2)

theorem parseValue_render (v : Value) (rest : List Char) (h : valueWF v)
    (hr : rest = [] ∨ ∃ c r, rest = c :: r ∧ isSpecial c = true) :
    parseValue (renderValue v ++ rest) = some (v, rest) := by
  match v, h with
  | .str s, h =>
    simp [renderValue, parseValue, takeStr_app s rest h]
  | .word (c :: cs), ⟨_, hw⟩ =>
    have hc : isSpecial c = false := hw c (by simp)
    have hcq : c ≠ '"' := by intro h; subst h; simp [isSpecial] at hc
    have htw : takeWord (c :: (cs ++ rest)) = (c :: cs, rest) :=
      takeWord_app (c :: cs) rest hw hr
    simp [renderValue, parseValue, hcq, hc, htw]

-- ===========================================================================
-- Document structure: nodes with name + args + recursive children.
-- ===========================================================================

mutual
  inductive Tree where
    | node : Char → List Value → Forest → Tree
  inductive Forest where
    | nil  : Forest
    | cons : Tree → Forest → Forest
end

mutual
  def sizeTree : Tree → Nat
    | .node _ _ f => sizeForest f + 1
  def sizeForest : Forest → Nat
    | .nil => 0
    | .cons t f => sizeTree t + sizeForest f + 1
end

mutual
  def treeWF : Tree → Prop
    | .node c args f =>
        c ≠ ' ' ∧ c ≠ '{' ∧ c ≠ '}' ∧ c ≠ '"' ∧ (∀ v ∈ args, valueWF v) ∧ forestWF f
  def forestWF : Forest → Prop
    | .nil => True
    | .cons t f => treeWF t ∧ forestWF f
end

/-- Each arg is ` "…"` (space then the value). -/
def renderArgs : List Value → List Char
  | [] => []
  | v :: vs => ' ' :: (renderValue v ++ renderArgs vs)

mutual
  def renderTree : Tree → List Char
    | .node c args f => c :: (renderArgs args ++ ' ' :: '{' :: (renderForest f ++ ['}']))
  def renderForest : Forest → List Char
    | .nil => []
    | .cons t f => renderTree t ++ renderForest f
end

/-- Parse the space-separated arg list, stopping before the ` {` that begins the
    children block. Fuel = arg-list length bound. -/
def parseArgs : Nat → List Char → Option (List Value × List Char)
  | 0, _ => none
  | fuel + 1, ' ' :: c :: rest =>
      if c = '{' then some ([], ' ' :: '{' :: rest)
      else
        match parseValue (c :: rest) with
        | some (v, rest2) => (parseArgs fuel rest2).map (fun p => (v :: p.1, p.2))
        | none => none
  | _ + 1, toks => some ([], toks)

-- One-step reduction of parseArgs on ` c…` where `c ≠ '{'` (a value, not ` {`).
theorem parseArgs_step (fuel : Nat) (c : Char) (rest : List Char) (hc : c ≠ '{') :
    parseArgs (fuel + 1) (' ' :: c :: rest) =
      (match parseValue (c :: rest) with
       | some (v, rest2) => (parseArgs fuel rest2).map (fun p => (v :: p.1, p.2))
       | none => none) := by
  simp only [parseArgs, if_neg hc]

theorem renderArgs_append_cons (vs : List Value) (Z : List Char) :
    ∃ r, renderArgs vs ++ ' ' :: Z = ' ' :: r := by
  cases vs with
  | nil => exact ⟨Z, rfl⟩
  | cons v vs => exact ⟨renderValue v ++ renderArgs vs ++ ' ' :: Z, by
      simp [renderArgs, List.append_assoc]⟩

theorem parseArgs_render (args : List Value) (Y : List Char) (F : Nat)
    (hwf : ∀ v ∈ args, valueWF v) (hF : args.length < F) :
    parseArgs F (renderArgs args ++ ' ' :: '{' :: Y) = some (args, ' ' :: '{' :: Y) := by
  induction args generalizing F with
  | nil =>
    match F with
    | F + 1 => simp [renderArgs, parseArgs]
  | cons v vs ih =>
    match F with
    | F + 1 =>
      have hv : valueWF v := hwf _ (by simp)
      have hvs : ∀ w ∈ vs, valueWF w := fun w hw => hwf w (by simp [hw])
      have hF' : vs.length < F := by simp only [List.length_cons] at hF; omega
      -- the trailing input after this value is space-led, so it ends a bareword
      obtain ⟨r0, hr0⟩ := renderArgs_append_cons vs ('{' :: Y)
      have hpv := parseValue_render v (renderArgs vs ++ ' ' :: '{' :: Y) hv
        (Or.inr ⟨' ', r0, hr0, by decide⟩)
      have hia := ih F hvs hF'
      -- renderValue v = c :: tail with c ≠ '{', so parseArgs takes the value branch
      obtain ⟨c, tl, hvr, hc⟩ : ∃ c tl, renderValue v = c :: tl ∧ c ≠ '{' := by
        match v, hv with
        | .str s, _ => exact ⟨'"', s ++ ['"'], rfl, by decide⟩
        | .word (a :: as), ⟨_, hw⟩ =>
            refine ⟨a, as, rfl, ?_⟩
            have := hw a (by simp); simp only [isSpecial, Bool.or_eq_false_iff] at this
            intro h; simp_all
      simp only [renderArgs, hvr, List.cons_append, List.append_assoc] at hpv ⊢
      rw [parseArgs_step _ _ _ hc, hpv]
      simp [hia]

mutual
  def parseTree : Nat → List Char → Option (Tree × List Char)
    | 0, _ => none
    | _ + 1, [] => none
    | fuel + 1, c :: rest =>
        if c = ' ' ∨ c = '{' ∨ c = '}' ∨ c = '"' then none
        else
          match parseArgs (rest.length + 1) rest with
          | some (args, ' ' :: '{' :: rest3) =>
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

theorem renderArgs_length (args : List Value) : args.length ≤ (renderArgs args).length := by
  induction args with
  | nil => simp [renderArgs]
  | cons v vs ih =>
    simp only [renderArgs, List.length_cons, List.length_append]
    omega

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
    obtain ⟨h1, h2, h3, h4, hargs, hwfg⟩ := hwf
    have hsub : sizeForest g < fuel := by simp only [sizeTree] at hf; omega
    have hforest := parseForest_render g fuel ('}' :: rest) hwfg hsub (Or.inr ⟨rest, rfl⟩)
    have hns : ¬ (c = ' ' ∨ c = '{' ∨ c = '}' ∨ c = '"') := by
      rintro (h | h | h | h)
      · exact h1 h
      · exact h2 h
      · exact h3 h
      · exact h4 h
    have hpa := parseArgs_render args (renderForest g ++ '}' :: rest)
      ((renderArgs args ++ ' ' :: '{' :: (renderForest g ++ '}' :: rest)).length + 1)
      hargs (by have := renderArgs_length args; simp only [List.length_append]; omega)
    simp only [renderTree, List.cons_append, List.append_assoc, List.singleton_append,
               List.nil_append, parseTree, if_neg hns, hpa, hforest]
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
    obtain ⟨_, _, hc, _, _, _⟩ := hwft
    simp only [renderForest, renderTree, List.append_assoc, List.cons_append,
               List.singleton_append, List.nil_append] at htree ⊢
    rw [parseForest_node _ _ _ hc, htree]
    simp only [hrest]
end

def parse (s : List Char) : Option Forest :=
  match parseForest (s.length + 1) s with
  | some (f, []) => some f
  | _ => none

/-- THE FULL PROOF: every well-formed document — nodes with identifier names,
    string-valued argument lists, and recursive children — round-trips. -/
theorem parse_renderForest (f : Forest) (hwf : forestWF f) :
    parse (renderForest f) = some f := by
  unfold parse
  have hb : sizeForest f < (renderForest f).length + 1 := by
    have := sizeForest_le f; omega
  have h := parseForest_render f ((renderForest f).length + 1) [] hwf hb (Or.inl rfl)
  simp only [List.append_nil] at h
  rw [h]

#print axioms parse_renderForest

end Kdl.Full
