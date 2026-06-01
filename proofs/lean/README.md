# proofs/lean — KDL formal-proof track (Tier 0)

The strongest tier of the conformance assurance hierarchy
(`docs/rfc-conformance-assurance.md`, GH #29): formalize KDL in Lean 4 and
**prove** a reference recognizer correct — `∀`, not statistically.

This is the proof analogue of the conformance corpus's "generation < parsing":
instead of generating `(input, expected)` pairs and *testing* agreement, we
define `render` and `parse` and *prove* they agree for every input.

## What's proved (axiom-clean — see `#print axioms`)

`Kdl/Value.lean` — the KEYWORD VALUE fragment (`#true/#false/#null/#inf/#-inf/#nan`):
- **completeness** (`parse_render`): `parse (render v) = some v` — depends on no axioms.
- **soundness** (`render_parse`): `parse s = some v → render v = s` — depends only
  on `propext` (a core Lean axiom; not a `sorry`).

Together: the recognizer accepts exactly the canonical renderings and never lies
about the value.

`Kdl/Number.lean` — the NUMBER fragment (first requiring real INDUCTION):
- **faithfulness** (`ofDigits_toDigits`): `ofDigits (toDigits n) = n` — the
  decimal digits of a natural number denote it exactly.
- **char round-trip** (`charDigit_digitChar`): each digit's character decodes back.
- **full round-trip** (`parse_render`): `parseChars (renderChars n) = some n` —
  parsing the decimal rendering of any natural number recovers it, ∀ n.

A verified decimal recognizer. Proved over `List Char` (the character sequence
the recognizer sees); the `List Char ↔ String` UTF-8 packing is a trivial
boundary, deferred only because Lean 4's `String` is now `ByteArray`-backed.
All three: `propext, Quot.sound` (core; no `sorryAx`).

`Kdl/Str.lean` — the QUOTED STRING fragment (escapes + recursion):
- **round-trip** (`parse_render`): `parse (render s) = some s` for every string —
  `"` and `\` are escaped as `\"` / `\\`; parse strips the quotes and decodes the
  escapes. Proved by induction over the content with the escape-character cases.

## Run

```
proofs/lean/run.sh           # builds the cached Lean image once, then checks both files
```


```
proofs/lean/run.sh           # builds the cached Lean image once, then checks
```

## Growth path (each a fragment, render+parse+two theorems)

The tracer establishes the toolchain + the render/parse/proof shape. Next
fragments, hardest last: exact-decimal NUMBER (digit-string induction), quoted
STRING + escapes, then the recursive NODE/DOCUMENT grammar. The genuinely hard
spec pieces (Unicode tables, multiline dedent, matched-hash) come with the
string/number work. The high-leverage target is a proven *reference* recognizer;
nkdl is then validated against that authority by the conformance corpus.
