## conformance/groups.nim — spec-transcribed surface interaction groups and
## their instantiators (clean-room: coverage + render + model, NO `../src`).
##
## Each grammar production whose surface has interacting choices is declared as
## an `InteractionGroup` (factors + constraints) PLUS an `instantiate*` that
## turns one covering-array row into a concrete `(text, value)` witness. The
## group is the spec transcription in the *recognition* direction (what choices
## exist); the instantiator is the same production in the *generation*
## direction (knows the value by construction). Keeping them adjacent makes the
## production the single source of truth for both coverage and witnesses.
##
## A value's surface factors split into two kinds, and the distinction is
## load-bearing:
##   • SEMANTIC factors change the model value (a number's sign);
##   • PRESENTATION factors are pure spelling (base, hex-case, underscores).
## The covering array covers both; only presentation factors are subject to the
## metamorphic "same value under different surface" invariant.

import ./model
import ./render
import ./coverage

# ---------------------------------------------------------------------------
# Integer  (grammar §Number: decimal / hex / octal / binary, sign, underscores)
# ---------------------------------------------------------------------------

const intRepr = 42'i64
  ## Representative magnitude: ≥ 2 digits in every base (so underscores have a
  ## gap to sit in) and contains a hex letter (0x2A) so hex-case is observable.

proc integerGroup*(): InteractionGroup =
  ## base{dec,hex,oct,bin} × hexcase{lower,upper,∅} × sign{none,plus,minus}
  ## × underscore{yes,no}, pairwise, constrained: hex-case exists ⇔ base = hex
  ## (a decimal/octal/binary number has no notion of letter case).
  InteractionGroup(
    name: "integer",
    t: 2,
    factors: @[
      Factor(name: "int.base",       levels: @["dec", "hex", "oct", "bin"]),
      Factor(name: "int.hexcase",    levels: @["lower", "upper", ""]),  # "" = absent
      Factor(name: "int.sign",       levels: @["none", "plus", "minus"]),
      Factor(name: "int.underscore", levels: @["yes", "no"]),
    ],
    valid: proc(c: Tagset): bool =
      (lvl(c, "int.base") == "hex") == (lvl(c, "int.hexcase") != ""))

proc instantiateInteger*(row: Tagset): ValueSurface =
  ## Render one integer covering-array row to a witness. Presentation factors
  ## (base/case/underscore) shape only the text; the sign factor is semantic and
  ## flows into the model value, so the pair stays an oracle by construction.
  let base = case lvl(row, "int.base")
             of "hex": 16
             of "oct": 8
             of "bin": 2
             else: 10
  let upperHex = lvl(row, "int.hexcase") == "upper"
  let signMode = case lvl(row, "int.sign")
                 of "plus": 1
                 of "minus": 2
                 else: 0
  let value = (if signMode == 2: -intRepr else: intRepr)
  let nDigits = magnitudeDigits(uint64(intRepr), base, upperHex).len
  var underscores = newSeq[int](nDigits)
  if lvl(row, "int.underscore") == "yes" and nDigits >= 2:
    underscores[0] = 1            # one `_`-run after the first magnitude digit
  let st = IntStyle(base: base, upperHex: upperHex,
                    signMode: signMode, underscores: underscores)
  ValueSurface(text: renderInt(value, st), value: kInt(value))
