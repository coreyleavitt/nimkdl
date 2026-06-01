/-
  KDL formal-proof track — number fragment (Tier 0).

  The first fragment requiring real INDUCTION (the keyword tracer was finite).
  Core: the digit representation of a natural number is faithful — converting a
  Nat to its decimal digits and back is the identity. This is the arithmetic
  heart of a verified decimal-number recognizer; the string surface
  (chars ↔ digits) layers on top.
-/

namespace Kdl.Number

/-- A decimal digit. -/
abbrev Digit := Fin 10

/-- Little-endian value: the head digit is least significant.
    `ofDigits [3,2,1] = 3 + 10*(2 + 10*(1 + 0)) = 123`. -/
def ofDigits : List Digit → Nat
  | [] => 0
  | d :: ds => d.val + 10 * ofDigits ds

/-- Little-endian digits of `n` (head least significant); `0 ↦ []`. -/
def toDigits (n : Nat) : List Digit :=
  if h : n = 0 then []
  else ⟨n % 10, Nat.mod_lt n (by decide)⟩ :: toDigits (n / 10)
decreasing_by exact Nat.div_lt_self (Nat.pos_of_ne_zero h) (by decide)

/-- FAITHFULNESS / round-trip: the decimal digits of `n` denote `n` exactly. -/
theorem ofDigits_toDigits (n : Nat) : ofDigits (toDigits n) = n := by
  induction n using Nat.strongRecOn with
  | _ n ih =>
    unfold toDigits
    split
    · next h => simp [h, ofDigits]
    · next h =>
      have hlt : n / 10 < n := Nat.div_lt_self (Nat.pos_of_ne_zero h) (by decide)
      simp only [ofDigits]
      rw [ih _ hlt]
      omega

#print axioms ofDigits_toDigits

-- ===========================================================================
-- String surface: decimal digit characters ↔ digits.
-- ===========================================================================

/-- The ASCII character for a decimal digit (`0 ↦ '0'`, …, `9 ↦ '9'`). -/
def digitChar (d : Digit) : Char := Char.ofNat (d.val + 48)

/-- Recover a decimal digit from a character; `none` if not `'0'..'9'`. -/
def charDigit (c : Char) : Option Digit :=
  if h : 48 ≤ c.toNat ∧ c.toNat ≤ 57 then some ⟨c.toNat - 48, by omega⟩ else none

/-- Char round-trip: every digit's character decodes back to it.
    Finite (`Fin 10`) so `decide` evaluates all ten cases. -/
theorem charDigit_digitChar : ∀ d : Digit, charDigit (digitChar d) = some d := by
  decide

#print axioms charDigit_digitChar

-- ===========================================================================
-- Full string round-trip: parse (render n) = some n.
-- ===========================================================================

/-- Parse a run of decimal digit characters; all-or-nothing. -/
def parseDigits : List Char → Option (List Digit)
  | [] => some []
  | c :: cs =>
    match charDigit c, parseDigits cs with
    | some d, some ds => some (d :: ds)
    | _, _ => none

theorem parseDigits_map (xs : List Digit) :
    parseDigits (xs.map digitChar) = some xs := by
  induction xs with
  | nil => rfl
  | cons d ds ih => simp [parseDigits, charDigit_digitChar d, ih]

theorem toDigits_ne_nil {n : Nat} (h : n ≠ 0) : toDigits n ≠ [] := by
  unfold toDigits; simp [h]

/-- Render a natural number as its decimal CHARACTER sequence (big-endian;
    `0 ↦ ['0']`). String is the UTF-8 packing of this `List Char` — a trivial
    boundary deferred only because Lean 4's String is now ByteArray-backed. -/
def renderChars (n : Nat) : List Char :=
  if n = 0 then ['0'] else (toDigits n).reverse.map digitChar

/-- Parse a non-empty run of decimal digit characters to a natural number. -/
def parseChars (cs : List Char) : Option Nat :=
  match parseDigits cs with
  | some (d :: ds) => some (ofDigits (d :: ds).reverse)
  | _ => none

/-- The headline result: parsing the rendering of any natural number recovers
    it. A verified decimal round-trip, ∀ n. -/
theorem parse_render (n : Nat) : parseChars (renderChars n) = some n := by
  unfold renderChars
  split
  · next h => subst h; rfl
  · next h =>
    unfold parseChars
    rw [parseDigits_map]
    have hne : (toDigits n).reverse ≠ [] := by
      simp [List.reverse_eq_nil_iff, toDigits_ne_nil h]
    cases hr : (toDigits n).reverse with
    | nil => exact absurd hr hne
    | cons d ds =>
      simp only
      rw [← hr, List.reverse_reverse, ofDigits_toDigits]

#print axioms parse_render

end Kdl.Number
