/-
  KDL formal-proof track — matched-hash RAW STRINGS (Tier 0, lexical).

  A raw string `#…#"content"#…#` opens with some number of `#`, a quote, the
  literal content, a quote, and a *matching* number of `#`. The verified
  property is the MATCH: parse counts the opening hashes and requires exactly
  that many to close. No escapes, no Unicode — the interesting part is the
  delimiter count.

  Scope: content with no `"` (a sufficient unambiguity condition — the first
  closing quote is then unmistakable); arbitrary hash counts n ≥ 0.
-/

namespace Kdl.RawStr

def hashes (n : Nat) : List Char := List.replicate n '#'

/-- `#…# " content " #…#` with `n` hashes on each side. -/
def render (content : List Char) (n : Nat) : List Char :=
  hashes n ++ '"' :: (content ++ '"' :: hashes n)

/-- Consume a leading run of `#`, returning the count and the remainder. -/
def countHashes : List Char → Nat × List Char
  | [] => (0, [])
  | c :: rest =>
      if c = '#' then let p := countHashes rest; (p.1 + 1, p.2)
      else (0, c :: rest)

/-- Read up to the first `"`, returning (content, remainder-after-quote). -/
def takeContent : List Char → Option (List Char × List Char)
  | [] => none
  | c :: rest =>
      if c = '"' then some ([], rest)
      else (takeContent rest).map (fun p => (c :: p.1, p.2))

/-- Parse a raw string: count opening `#`s, a quote, content up to a quote, then
    require EXACTLY the same number of closing `#`s (and nothing after). -/
def parse (s : List Char) : Option (List Char) :=
  let (n, s1) := countHashes s
  match s1 with
  | '"' :: s2 =>
      match takeContent s2 with
      | some (content, s3) => if s3 = hashes n then some content else none
      | none => none
  | _ => none

/-- `n` hashes then a non-`#`-led tail counts to exactly `n`. -/
theorem countHashes_app (n : Nat) (Y : List Char)
    (h : ∀ c r, Y = c :: r → c ≠ '#') :
    countHashes (hashes n ++ Y) = (n, Y) := by
  induction n with
  | zero =>
    simp only [hashes, List.replicate, List.nil_append]
    match Y with
    | [] => rfl
    | c :: r => simp only [countHashes, if_neg (h c r rfl)]
  | succ k ih =>
    have he : hashes (k + 1) ++ Y = '#' :: (hashes k ++ Y) := by
      simp [hashes, List.replicate_succ]
    rw [he]
    simp [countHashes, ih]

/-- A `"`-free run then a `"`-led tail splits at that quote. -/
theorem takeContent_app (content rest : List Char) (h : ∀ c ∈ content, c ≠ '"') :
    takeContent (content ++ '"' :: rest) = some (content, rest) := by
  induction content with
  | nil => simp [takeContent]
  | cons c cs ih =>
    have hc : c ≠ '"' := h c (by simp)
    have ih' := ih (fun a ha => h a (by simp [ha]))
    simp [takeContent, hc, ih']

/-- The headline result: parsing the rendering of any (quote-free) content with
    any hash count recovers the content — the closing hashes are matched. -/
theorem parse_render (content : List Char) (n : Nat) (h : ∀ c ∈ content, c ≠ '"') :
    parse (render content n) = some content := by
  unfold parse render
  rw [countHashes_app n ('"' :: (content ++ '"' :: hashes n))
        (fun c r heq => by injection heq with h1 _; subst h1; decide)]
  simp [takeContent_app content (hashes n) h]

#print axioms parse_render

theorem hashes_length (n : Nat) : (hashes n).length = n := by simp [hashes]

/-- SOUNDNESS: the delimiter match is ENFORCED — a closing hash count `m` that
    differs from the opening count `n` is REJECTED. So the verified property
    (matching) holds both ways: matched closes accept (`parse_render`), and
    mismatched closes reject. -/
theorem parse_mismatch (content : List Char) (n m : Nat) (hne : m ≠ n)
    (h : ∀ c ∈ content, c ≠ '"') :
    parse (hashes n ++ '"' :: (content ++ '"' :: hashes m)) = none := by
  have h' : hashes m ≠ hashes n := fun hc =>
    hne (by have := congrArg List.length hc; simpa [hashes_length] using this)
  unfold parse
  rw [countHashes_app n ('"' :: (content ++ '"' :: hashes m))
        (fun c r heq => by injection heq with h1 _; subst h1; decide)]
  simp [takeContent_app content (hashes m) h, h']

#print axioms parse_mismatch

end Kdl.RawStr
