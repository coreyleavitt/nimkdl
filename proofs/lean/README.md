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

`Kdl/Doc.lean` — the RECURSIVE document fragment (the deep end):
- **round-trip** (`parse_renderForest`): `parse (renderForest f) = some f` for
  every forest — a tree of brace-nested nodes (`{}`, `{{}}`, `{{}{}}`, …), the
  essential recursive skeleton (names/args/Unicode come later). A verified
  recursive-descent parser: FUEL-based (so termination is structural), proved by
  **mutual induction** on the tree/forest with a `size ≤ render-length` fuel bound.
  All theorems axiom-clean (`propext, Quot.sound`).

`Kdl/NamedDoc.lean` — recursion + node CONTENT (the "combine" step):
- **round-trip** (`parse_renderForest`): `forestWF f → parse (renderForest f) =
  some f`. Each node carries a name char and renders `name { children }` (e.g.
  `a{b{}c{}}`). Names must avoid `{`/`}` — the well-formedness predicate
  `treeWF`/`forestWF`, threaded through the mutual induction. The step from the
  brace-only skeleton toward real KDL nodes.

`Kdl/ArgsDoc.lean` — node name + ARGS + children:
- **round-trip** (`parse_renderForest`): `forestWF f → parse (renderForest f) =
  some f`, where each node renders `name args… { children }` (e.g. `axy{b{}}`).
  New ingredient: a variable-length content list parsed as a run up to `{`
  (`takeArgs` + `takeArgs_app`). Proved first try — the recursive-descent
  patterns transferred wholesale.

`Kdl/RawStr.lean` — matched-hash RAW STRINGS (the first lexical hard piece):
- **round-trip** (`parse_render`): `(∀ c ∈ content, c ≠ '"') → parse (render
  content n) = some content`. A raw string `#…#"content"#…#` must close with
  EXACTLY as many `#` as it opened — parse counts the opening hashes
  (`countHashes`) and requires the trailing run to match. The verified property
  is the delimiter count. `propext` only.

`Kdl/Dedent.lean` — multiline DEDENT core (the hardest algorithm):
- **dedent round-trip** (`dedent_render`): `dedent p (lines.map (p ++ ·)) =
  some lines` for every prefix `p` and body — indenting every line by `p` then
  dedenting by `p` recovers the lines. This is the genuinely novel multi-line
  string operation; the `"""`-framing (discover `p` from the closing line, split
  the body on newlines) is plumbing around this core. `propext` only.

`Kdl/Full.lean` — **THE FULL PROOF**: one integrated KDL-core recognizer:
- **round-trip** (`parse_renderForest`): `forestWF f → parse (renderForest f) =
  some f` for every document. A document is a list of nodes; each node has an
  IDENTIFIER name, a list of STRING-VALUED args, and recursive CHILDREN —
  `name "a" "b" { children }`. ONE grammar, ONE parser, ONE theorem, combining
  identifiers + typed values + a space-separated value list (`parseArgs`) + the
  recursive structure. Not the separate fragments — a coherent recognizer.
  `propext, Quot.sound`.

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
