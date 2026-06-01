/-
  KDL formal-proof track — string fragment (Tier 0).

  A verified recognizer for QUOTED STRINGS with escapes: the two characters that
  MUST be escaped, `"` and `\`, are written `\"` and `\\`; everything else is
  literal. Render wraps the escaped body in quotes; parse strips the quotes and
  decodes the escapes. The theorem: `parse (render s) = some s` for every string.

  Proved over `List Char` (the character sequence); String is the UTF-8 packing.
-/

namespace Kdl.Str

/-- Escape one character for a quoted string. -/
def escapeChar (c : Char) : List Char :=
  if c = '"' then ['\\', '"']
  else if c = '\\' then ['\\', '\\']
  else [c]

/-- Render a string's characters as a quoted KDL string. -/
def render (s : List Char) : List Char :=
  '"' :: (s.flatMap escapeChar ++ ['"'])

/-- Parse a quoted-string body up to a closing `"` (which must be the final
    character); decodes `\"` and `\\`. -/
def parseBody : List Char → Option (List Char)
  | [] => none
  | '"' :: rest => if rest = [] then some [] else none
  | '\\' :: c :: rest =>
      if c = '"' ∨ c = '\\' then (parseBody rest).map (c :: ·) else none
  | '\\' :: [] => none
  | c :: rest => (parseBody rest).map (c :: ·)

/-- Parse a full quoted string. -/
def parse : List Char → Option (List Char)
  | '"' :: rest => parseBody rest
  | _ => none

/-- The escaped body, followed by the closing quote, parses back to the string. -/
theorem parseBody_escape (s : List Char) :
    parseBody (s.flatMap escapeChar ++ ['"']) = some s := by
  induction s with
  | nil => rfl
  | cons c cs ih =>
    simp only [List.flatMap_cons, escapeChar, List.append_assoc]
    split
    · next h => subst h; simp [parseBody, ih]
    · split
      · next h => subst h; simp [parseBody, ih]
      · next _ h2 => simp [parseBody, ih, h2]

/-- The headline result: parsing the quoted rendering of any string recovers it. -/
theorem parse_render (s : List Char) : parse (render s) = some s := by
  unfold parse render
  exact parseBody_escape s

#print axioms parse_render

end Kdl.Str
