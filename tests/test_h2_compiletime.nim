## H2 acceptance: can decode[T] run at compile time?
##
## If `const x = decode[T](src)` compiles, the entire chain
## (lexer → parser → kdlDecodeImpl) is VM-callable and the
## decoded value is a binary-embedded constant — no module-init cost.
##
## The compile fails (rather than fallback to runtime) if any proc
## in the chain breaks the {.noSideEffect.} / VM-safe contract.

import std/unittest

import ../src/codegen
import ../src/spans

type
  Rule {.kdlNode: "rule".} = object
    id {.kdlArg.}: string
    enabled {.kdlProp.}: bool = false

deriveDecode(Rule)

# The acid test: if this `const` compiles, decode[T] runs at compile time.
const compileTimeDecoded = decode[Rule]("rule \"baked-in\" enabled=#true")

# Negative-side acid test: const-evaluating a malformed input gives an
# Err *at compile time* — the const carries the parse error itself.
const compileTimeBad = decode[Rule]("rule")  # missing required arg

suite "H2: compile-time decode":
  test "const-evaluated Result carries Ok for valid input":
    check compileTimeDecoded.isOk

  test "embedded value matches what we wrote in source":
    check compileTimeDecoded.isOk
    if compileTimeDecoded.isOk:
      check compileTimeDecoded.get.id == "baked-in"
      check compileTimeDecoded.get.enabled

  test "const-evaluated Result carries Err for malformed input":
    # Proves the WHOLE chain runs at compile time — if lex/parse/decode
    # weren't VM-safe, the `const compileTimeBad` declaration would
    # fail at compile time with a VM error, not silently fall through.
    check compileTimeBad.isErr
