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

end Kdl.Number
