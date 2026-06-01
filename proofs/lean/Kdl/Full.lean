/-
  KDL formal-proof track — INTEGRATED recognizer (Tier 0).

  The "full proof": one grammar, one parser, one round-trip theorem — combining
  the proven patterns into a coherent KDL core. A document is a list of nodes;
  a node has a multi-char IDENTIFIER name, a list of ENTRIES — positional args
  (bareword, quoted string, or `(type)`-annotated) and `key=value` PROPS — and
  recursive children:
      `name (u8)bareword "string" key=val key2=(date)"v" { children }`.

  This integrates: multi-char identifiers (takeWord run-lemma), typed values
  (quoted strings via takeStr, barewords via takeWord, dispatched by leading
  char), `(type)` ANNOTATIONS (takeType run-lemma in front of a base value), the
  arg/prop ENTRY split (`=` terminates a bareword, so `key=value` divides
  cleanly), a space-separated ENTRY LIST (parseArgs), and the recursive document
  structure (fuel-based mutual recursion) — all in one end-to-end
  `parse (renderForest f) = some f` for every well-formed document.
-/

namespace Kdl.Full

-- ===========================================================================
-- Values: quoted strings.
-- ===========================================================================

/-- A delimiter that ends a bareword: space, brace, quote, `=` (so `key=value`
    splits), or `(`/`)` (so type annotations are unambiguous). None of these are
    valid identifier chars in KDL. -/
def isSpecial (c : Char) : Bool :=
  c = ' ' || c = '{' || c = '}' || c = '"' || c = '=' || c = '(' || c = ')'

inductive Value where
  | str  : List Char → Value          -- quoted string
  | word : List Char → Value          -- bareword (nonempty run of non-special chars)
  | anno : List Char → Value → Value  -- (type) annotation on a base value

def renderValue : Value → List Char
  | .str s    => '"' :: (s ++ ['"'])
  | .word w   => w
  | .anno t v => '(' :: (t ++ ')' :: renderValue v)

/-- A base value (no annotation) — the body an annotation may wrap. -/
def baseWF : Value → Prop
  | .str s   => ∀ c ∈ s, c ≠ '"'
  | .word w  => w ≠ [] ∧ ∀ c ∈ w, isSpecial c = false
  | .anno .. => False                 -- KDL allows at most one annotation: no nesting

def valueWF : Value → Prop
  | .anno t v => t ≠ [] ∧ (∀ c ∈ t, c ≠ ')') ∧ baseWF v
  | v         => baseWF v

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

/-- Read a `(type)` annotation's name: up to the first `)`. -/
def takeType : List Char → Option (List Char × List Char)
  | [] => none
  | c :: rest => if c = ')' then some ([], rest) else (takeType rest).map (fun p => (c :: p.1, p.2))

theorem takeType_app (t rest : List Char) (h : ∀ c ∈ t, c ≠ ')') :
    takeType (t ++ ')' :: rest) = some (t, rest) := by
  induction t with
  | nil => simp [takeType]
  | cons c cs ih =>
    have hc : c ≠ ')' := h c (by simp)
    simp [takeType, hc, ih (fun a ha => h a (by simp [ha]))]

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

/-- Parse a base value: a quoted string or a bareword. -/
def parseBase : List Char → Option (Value × List Char)
  | [] => none
  | c :: rest =>
      if c = '"' then (takeStr rest).map (fun p => (Value.str p.1, p.2))
      else if isSpecial c then none
      else let p := takeWord (c :: rest); some (.word p.1, p.2)

/-- Parse a value: an optional `(type)` annotation in front of a base value. -/
def parseValue : List Char → Option (Value × List Char)
  | [] => none
  | c :: rest =>
      if c = '(' then
        match takeType rest with
        | some (t, r) => (parseBase r).map (fun p => (Value.anno t p.1, p.2))
        | none => none
      else parseBase (c :: rest)

theorem parseBase_render (v : Value) (rest : List Char) (h : baseWF v)
    (hr : rest = [] ∨ ∃ c r, rest = c :: r ∧ isSpecial c = true) :
    parseBase (renderValue v ++ rest) = some (v, rest) := by
  match v, h with
  | .str s, h =>
    simp [renderValue, parseBase, takeStr_app s rest h]
  | .word (c :: cs), ⟨_, hw⟩ =>
    have hc : isSpecial c = false := hw c (by simp)
    have hcq : c ≠ '"' := by intro h; subst h; simp [isSpecial] at hc
    have htw : takeWord (c :: (cs ++ rest)) = (c :: cs, rest) :=
      takeWord_app (c :: cs) rest hw hr
    simp [renderValue, parseBase, hcq, hc, htw]

-- A non-`(`-led input is parsed as a base value (no annotation).
theorem parseValue_not_paren (c : Char) (rest : List Char) (hc : c ≠ '(') :
    parseValue (c :: rest) = parseBase (c :: rest) := by
  simp only [parseValue, if_neg hc]

-- A `(type)`-led input parses the annotation then the base after `)`.
theorem parseValue_paren (t r : List Char) (h : ∀ c ∈ t, c ≠ ')') :
    parseValue ('(' :: (t ++ ')' :: r)) =
      (parseBase r).map (fun p => (Value.anno t p.1, p.2)) := by
  simp only [parseValue]
  split
  · rw [takeType_app t r h]
  · rename_i hcond; exact absurd trivial hcond

theorem parseValue_render (v : Value) (rest : List Char) (h : valueWF v)
    (hr : rest = [] ∨ ∃ c r, rest = c :: r ∧ isSpecial c = true) :
    parseValue (renderValue v ++ rest) = some (v, rest) := by
  match v, h with
  | .str s, h =>
    have hpb := parseBase_render (.str s) rest h hr
    rw [show renderValue (.str s) ++ rest = '"' :: (s ++ ['"'] ++ rest) from rfl] at hpb ⊢
    rw [parseValue_not_paren _ _ (by decide), hpb]
  | .word (a :: as), h =>
    have hw : ∀ c ∈ (a :: as), isSpecial c = false := h.2
    have hc : isSpecial a = false := hw a (by simp)
    have hcp : a ≠ '(' := by intro h; subst h; simp [isSpecial] at hc
    have hpb := parseBase_render (.word (a :: as)) rest h hr
    rw [show renderValue (.word (a :: as)) ++ rest = a :: (as ++ rest) from rfl] at hpb ⊢
    rw [parseValue_not_paren _ _ hcp, hpb]
  | .anno t v, ⟨_, htnp, hbv⟩ =>
    have hbase := parseBase_render v rest hbv hr
    rw [show renderValue (.anno t v) ++ rest = '(' :: (t ++ ')' :: (renderValue v ++ rest)) by
          simp [renderValue, List.append_assoc],
        parseValue_paren t (renderValue v ++ rest) htnp, hbase, Option.map_some]

-- ===========================================================================
-- Entries: a node's child entries are positional ARGS or `key=value` PROPS.
-- ===========================================================================

inductive Entry where
  | arg  : Value → Entry                 -- positional value
  | prop : List Char → Value → Entry     -- key=value (key is a bareword)

def renderEntry : Entry → List Char
  | .arg v    => renderValue v
  | .prop k v => k ++ '=' :: renderValue v

def entryWF : Entry → Prop
  | .arg v    => valueWF v
  | .prop k v => k ≠ [] ∧ (∀ c ∈ k, isSpecial c = false) ∧ valueWF v

/-- Parse one entry: a quoted-string or `(type)`-annotated value is an arg
    (no key); otherwise read a bareword — if `=` follows it is a prop key (parse
    the value after `=`), else it is a bareword arg. -/
def parseEntry : List Char → Option (Entry × List Char)
  | [] => none
  | c :: rest =>
      if c = '"' ∨ c = '(' then (parseValue (c :: rest)).map (fun p => (Entry.arg p.1, p.2))
      else if isSpecial c then none
      else
        let (w, r) := takeWord (c :: rest)
        match r with
        | '=' :: r2 => (parseValue r2).map (fun p => (Entry.prop w p.1, p.2))
        | _         => some (Entry.arg (.word w), r)

-- A `"`- or `(`-led input is parsed as a value arg (no key).
theorem parseEntry_value (c : Char) (rest : List Char) (hc : c = '"' ∨ c = '(') :
    parseEntry (c :: rest) = (parseValue (c :: rest)).map (fun p => (Entry.arg p.1, p.2)) := by
  simp only [parseEntry, if_pos hc]

/-- An entry round-trips, provided the trailing input is led by a delimiter that
    is NOT `=` (so a bareword arg is not mistaken for a prop key). -/
theorem parseEntry_render (e : Entry) (rest : List Char) (h : entryWF e)
    (hr : rest = [] ∨ ∃ c r, rest = c :: r ∧ isSpecial c = true ∧ c ≠ '=') :
    parseEntry (renderEntry e ++ rest) = some (e, rest) := by
  -- weaken to the parseValue precondition (drops the `≠ '='` clause)
  have hr' : rest = [] ∨ ∃ c r, rest = c :: r ∧ isSpecial c = true := by
    rcases hr with h | ⟨c, r, he, hs, _⟩
    · exact Or.inl h
    · exact Or.inr ⟨c, r, he, hs⟩
  match e, h with
  | .arg (.str s), h =>
      have hpv := parseValue_render (.str s) rest h hr'
      show parseEntry (renderValue (.str s) ++ rest) = some (Entry.arg (.str s), rest)
      rw [show renderValue (.str s) ++ rest = '"' :: (s ++ ['"'] ++ rest) from rfl] at hpv ⊢
      rw [parseEntry_value _ _ (Or.inl rfl), hpv, Option.map_some]
  | .arg (.anno t v), h =>
      have hpv := parseValue_render (.anno t v) rest h hr'
      show parseEntry (renderValue (.anno t v) ++ rest) = some (Entry.arg (.anno t v), rest)
      rw [show renderValue (.anno t v) ++ rest = '(' :: (t ++ ')' :: (renderValue v ++ rest)) by
            simp [renderValue, List.append_assoc]] at hpv ⊢
      rw [parseEntry_value _ _ (Or.inr rfl), hpv, Option.map_some]
  | .arg (.word (a :: as)), ⟨_, hw⟩ =>
      have ha : isSpecial a = false := hw a (by simp)
      have haq : ¬ (a = '"' ∨ a = '(') := by
        rintro (h | h) <;> (subst h; simp [isSpecial] at ha)
      have hsp : ¬ (isSpecial a = true) := by rw [ha]; decide
      have htw : takeWord (a :: (as ++ rest)) = (a :: as, rest) :=
        takeWord_app (a :: as) rest hw hr'
      simp only [renderEntry, renderValue, List.cons_append, parseEntry, if_neg haq,
                 if_neg hsp, htw]
      -- rest is not `=`-led, so the prop branch does not fire
      rcases hr with h | ⟨x, r, he, _, hxq⟩
      · subst h; rfl
      · subst he
        split
        · next heq => injection heq with h1 _; exact absurd h1 hxq
        · rfl
  | .prop (a :: as) v, ⟨_, hk, hv⟩ =>
      have ha : isSpecial a = false := hk a (by simp)
      have haq : ¬ (a = '"' ∨ a = '(') := by
        rintro (h | h) <;> (subst h; simp [isSpecial] at ha)
      have hsp : ¬ (isSpecial a = true) := by rw [ha]; decide
      have htw : takeWord (a :: (as ++ '=' :: (renderValue v ++ rest)))
          = (a :: as, '=' :: (renderValue v ++ rest)) :=
        takeWord_app (a :: as) ('=' :: (renderValue v ++ rest)) hk
          (Or.inr ⟨'=', renderValue v ++ rest, rfl, by decide⟩)
      have hpv := parseValue_render v rest hv hr'
      simp only [renderEntry, List.cons_append, List.append_assoc, parseEntry, if_neg haq,
                 if_neg hsp, htw, hpv, Option.map_some]

-- ===========================================================================
-- Document structure: nodes with name + entries + recursive children.
-- ===========================================================================

mutual
  inductive Tree where
    | node : List Char → List Entry → Forest → Tree   -- name + entries (args/props)
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
    | .node name args f =>
        name ≠ [] ∧ (∀ c ∈ name, isSpecial c = false) ∧ (∀ e ∈ args, entryWF e) ∧ forestWF f
  def forestWF : Forest → Prop
    | .nil => True
    | .cons t f => treeWF t ∧ forestWF f
end

/-- Each entry is ` <entry>` (space then the rendered arg/prop). -/
def renderArgs : List Entry → List Char
  | [] => []
  | v :: vs => ' ' :: (renderEntry v ++ renderArgs vs)

mutual
  def renderTree : Tree → List Char
    | .node name args f => name ++ (renderArgs args ++ ' ' :: '{' :: (renderForest f ++ ['}']))
  def renderForest : Forest → List Char
    | .nil => []
    | .cons t f => renderTree t ++ renderForest f
end

/-- Parse the space-separated arg list, stopping before the ` {` that begins the
    children block. Fuel = arg-list length bound. -/
def parseArgs : Nat → List Char → Option (List Entry × List Char)
  | 0, _ => none
  | fuel + 1, ' ' :: c :: rest =>
      if c = '{' then some ([], ' ' :: '{' :: rest)
      else
        match parseEntry (c :: rest) with
        | some (v, rest2) => (parseArgs fuel rest2).map (fun p => (v :: p.1, p.2))
        | none => none
  | _ + 1, toks => some ([], toks)

-- One-step reduction of parseArgs on ` c…` where `c ≠ '{'` (an entry, not ` {`).
theorem parseArgs_step (fuel : Nat) (c : Char) (rest : List Char) (hc : c ≠ '{') :
    parseArgs (fuel + 1) (' ' :: c :: rest) =
      (match parseEntry (c :: rest) with
       | some (v, rest2) => (parseArgs fuel rest2).map (fun p => (v :: p.1, p.2))
       | none => none) := by
  simp only [parseArgs, if_neg hc]

theorem renderArgs_append_cons (vs : List Entry) (Z : List Char) :
    ∃ r, renderArgs vs ++ ' ' :: Z = ' ' :: r := by
  cases vs with
  | nil => exact ⟨Z, rfl⟩
  | cons v vs => exact ⟨renderEntry v ++ renderArgs vs ++ ' ' :: Z, by
      simp [renderArgs, List.append_assoc]⟩

theorem parseArgs_render (args : List Entry) (Y : List Char) (F : Nat)
    (hwf : ∀ e ∈ args, entryWF e) (hF : args.length < F) :
    parseArgs F (renderArgs args ++ ' ' :: '{' :: Y) = some (args, ' ' :: '{' :: Y) := by
  induction args generalizing F with
  | nil =>
    match F with
    | F + 1 => simp [renderArgs, parseArgs]
  | cons v vs ih =>
    match F with
    | F + 1 =>
      have hv : entryWF v := hwf _ (by simp)
      have hvs : ∀ w ∈ vs, entryWF w := fun w hw => hwf w (by simp [hw])
      have hF' : vs.length < F := by simp only [List.length_cons] at hF; omega
      -- the trailing input after this entry is space-led (and not `=`-led)
      obtain ⟨r0, hr0⟩ := renderArgs_append_cons vs ('{' :: Y)
      have hpv := parseEntry_render v (renderArgs vs ++ ' ' :: '{' :: Y) hv
        (Or.inr ⟨' ', r0, hr0, by decide, by decide⟩)
      have hia := ih F hvs hF'
      -- renderEntry v = c :: tail with c ≠ '{', so parseArgs takes the entry branch
      obtain ⟨c, tl, hvr, hc⟩ : ∃ c tl, renderEntry v = c :: tl ∧ c ≠ '{' := by
        match v, hv with
        | .arg (.str s), _ => exact ⟨'"', s ++ ['"'], rfl, by decide⟩
        | .arg (.word (a :: as)), ⟨_, hw⟩ =>
            refine ⟨a, as, rfl, ?_⟩
            have := hw a (by simp); simp only [isSpecial, Bool.or_eq_false_iff] at this
            intro h; simp_all
        | .arg (.anno t w), _ => exact ⟨'(', t ++ ')' :: renderValue w, rfl, by decide⟩
        | .prop (a :: as) w, ⟨_, hk, _⟩ =>
            refine ⟨a, as ++ '=' :: renderValue w, rfl, ?_⟩
            have := hk a (by simp); simp only [isSpecial, Bool.or_eq_false_iff] at this
            intro h; simp_all
      simp only [renderArgs, hvr, List.cons_append, List.append_assoc] at hpv ⊢
      rw [parseArgs_step _ _ _ hc, hpv]
      simp [hia]

mutual
  def parseTree : Nat → List Char → Option (Tree × List Char)
    | 0, _ => none
    | fuel + 1, toks =>
        match takeWord toks with
        | (name, rest) =>
          if name = [] then none      -- a node must have a non-empty identifier
          else
            match parseArgs (rest.length + 1) rest with
            | some (args, ' ' :: '{' :: rest3) =>
                match parseForest fuel rest3 with
                | some (f, '}' :: rest4) => some (.node name args f, rest4)
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

theorem renderArgs_length (args : List Entry) : args.length ≤ (renderArgs args).length := by
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
  | .node name args g, fuel + 1, hf =>
    obtain ⟨hne, hnsp, hargs, hwfg⟩ := hwf
    have hsub : sizeForest g < fuel := by simp only [sizeTree] at hf; omega
    have hforest := parseForest_render g fuel ('}' :: rest) hwfg hsub (Or.inr ⟨rest, rfl⟩)
    -- the identifier name is read by takeWord; the tail begins with a space, so
    -- the run stops exactly at the name's end
    have htw : takeWord
        (name ++ (renderArgs args ++ ' ' :: '{' :: (renderForest g ++ '}' :: rest)))
        = (name, renderArgs args ++ ' ' :: '{' :: (renderForest g ++ '}' :: rest)) := by
      obtain ⟨r0, hr0⟩ := renderArgs_append_cons args ('{' :: (renderForest g ++ '}' :: rest))
      exact takeWord_app name _ hnsp (Or.inr ⟨' ', r0, hr0, by decide⟩)
    have hpa := parseArgs_render args (renderForest g ++ '}' :: rest)
      ((renderArgs args ++ ' ' :: '{' :: (renderForest g ++ '}' :: rest)).length + 1)
      hargs (by have := renderArgs_length args; simp only [List.length_append]; omega)
    simp only [renderTree, List.cons_append, List.append_assoc,
               List.nil_append, parseTree, htw, if_neg hne, hpa, hforest]
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
    obtain ⟨name, args, g⟩ := t
    obtain ⟨hne, hnsp, _, _⟩ := hwft
    -- the forest begins with the node's name; its head char is non-special (≠ '}')
    match name, hnsp, htree with
    | a :: as, hnsp, htree =>
      have ha : a ≠ '}' := by
        have := hnsp a (by simp); intro h; subst h; simp [isSpecial] at this
      simp only [renderForest, renderTree, List.append_assoc, List.cons_append,
                 List.nil_append] at htree ⊢
      rw [parseForest_node _ _ _ ha, htree]
      simp only [hrest]
end

def parse (s : List Char) : Option Forest :=
  match parseForest (s.length + 1) s with
  | some (f, []) => some f
  | _ => none

/-- THE FULL PROOF: every well-formed document — nodes with multi-char identifier
    names, entry lists of args (bareword | string | `(type)`-annotated) and
    `key=value` props, and recursive children — round-trips. -/
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
