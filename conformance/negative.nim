## conformance/negative.nim — the must-REJECT corpus (clean-room).
##
## A conformance suite is only half-complete without negative space: inputs that
## a conforming parser MUST reject. Each fixture is transcribed from an explicit
## spec MUST/MUST-NOT and tagged with the grammar production it violates, so the
## corpus documents *why* each must fail — not just that it does. An impl that
## ACCEPTS any of these has a real bug (or the fixture misreads the spec, which
## is then a spec-transcription fix — never a silent corpus edit).
##
## Imports nothing — pure data. The adapter asserts rejection; emit writes these
## to `corpus/negative/` with a manifest mapping each input to its violated rule.

type NegFixture* = object
  name*: string       ## stable fixture id
  input*: string      ## the (invalid) document text
  violates*: string   ## the spec production / rule it breaks

proc negativeFixtures*(): seq[NegFixture] =
  ## Spec-transcribed must-reject inputs (KDL 2.0, docs/kdl-2.0-spec.md).
  @[
    # §Identifier String: the keywords inf/-inf/nan/true/false/null are illegal
    # as bare identifiers; they MUST carry the leading `#`.
    NegFixture(name: "bare-keyword-true", input: "node true\n",
               violates: "reserved-bareword"),
    NegFixture(name: "bare-keyword-inf", input: "node inf\n",
               violates: "reserved-bareword"),
    NegFixture(name: "bare-keyword-null-prop", input: "node k=null\n",
               violates: "reserved-bareword"),
    # §Number / §Identifier String: "almost a number" — a decimal point with no
    # leading digit is illegal as both a number and an identifier.
    NegFixture(name: "ident-leading-dot-digit", input: "node .1\n",
               violates: "ident-like-number"),
    # §Number: an identifier that starts like a number (digit-led with letters).
    NegFixture(name: "number-then-letters", input: "node 1.0v2\n",
               violates: "ident-like-number"),
    # §Number: `_` is not allowed before the digits (`0x_1a` is simply invalid).
    NegFixture(name: "hex-underscore-before-digit", input: "node 0x_1\n",
               violates: "number-underscore-before-digit"),
    # §Quoted String / Invalid escapes: `\` MUST NOT precede a non-escape char.
    NegFixture(name: "invalid-escape", input: "node \"a\\qb\"\n",
               violates: "invalid-escape"),
    # §Quoted String: an unterminated quoted string.
    NegFixture(name: "unterminated-quoted", input: "node \"abc\n",
               violates: "unterminated-string"),
    # §Raw String: the closing `#` count must MATCH the opening; here open=2,
    # close=1, so the string never closes.
    NegFixture(name: "raw-hash-mismatch", input: "node ##\"abc\"#\n",
               violates: "raw-string-delimiter-mismatch"),
    # §Multi-line String: the first line MUST start with a newline right after
    # the opening `"""`.
    NegFixture(name: "multiline-no-leading-newline", input: "node \"\"\"x\"\"\"\n",
               violates: "multiline-missing-leading-newline"),
    # Grammar (node-prop-or-arg): a property needs a value after `=`.
    NegFixture(name: "prop-missing-value", input: "node k=\n",
               violates: "property-missing-value"),
    # Grammar (node-children): an unterminated children block.
    NegFixture(name: "unterminated-children", input: "node {\n",
               violates: "unterminated-children"),
    # §Disallowed literal code points: a literal C0 control (BEL, U+0007) in a
    # string body MUST NOT appear directly (only via `\u{...}`).
    NegFixture(name: "disallowed-literal-control", input: "node \"a\x07b\"\n",
               violates: "disallowed-literal-codepoint"),
  ]
