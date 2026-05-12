## reserved — parse-time interpretation of KDL v2 reserved type
## annotations.
##
## Spec reference: draft-marchan-kdl2 §3 Components, "Reserved Type
## Annotations". The spec lists ~30 reserved tag names (numeric like
## `(u8)`, temporal like `(date-time)`, network like `(ipv4)`, etc.)
## and says implementations MAY recognize them; if they do, they SHOULD
## interpret the value per the cited RFC/ISO/IEEE standard.
##
## We choose to recognize them, which obligates us to validate. This
## module is the single source of truth for that validation, dispatched
## from both the hand parser (`parser.nim parseValue`) and the reference
## interpreter (`grammar.nim buildValue`) so both interpreters agree on
## what a reserved-tag-annotated value means.
##
## ## Scope
##
## Tier 1 (numeric range): `i8 i16 i32 i64 i128 u8 u16 u32 u64 u128
##                          isize usize f32 f64`
## Tier 2 (string formats): `uuid ipv4 ipv6 date time date-time duration
##                           base64 base85`
## Tier 3 (RFC-shape):      `email idn-email hostname idn-hostname url
##                           url-reference irl irl-reference url-template
##                           regex`
## Tier 4 (static tables):  `country-2 country-3 country-subdivision
##                           currency decimal decimal64 decimal128`
##
## Each tier lands as its own slice. This file is the dispatcher; the
## validators are added incrementally.
##
## ## Contract
##
## `validateReserved(tag, value)` returns `ok(void, ParseError)` when:
##   - The tag is not in the reserved registry (open-world: user-defined
##     tags pass through opaquely per spec).
##   - The tag is in the registry and the value's content matches the
##     standard interpretation.
##
## Returns `Err(peReservedTypeInvalid, ...)` when the tag is in the
## registry but the content doesn't match. The hint always cites the
## tag name and the specific constraint violated.
##
## All procs are `{.noSideEffect.}` so the chain stays VM-callable for
## `embed[T]` compile-time decode.

import ./ast
import ./spans

func validateU8(v: KdlValue): Result[void, ParseError] =
  ## `(u8)` — unsigned 8-bit integer, range [0, 255]. The value must be
  ## an integer literal (not float, not bigint — both are out of u8 range
  ## by construction).
  case v.kind
  of kvInt:
    if v.intVal < 0 or v.intVal > 255:
      return err[void, ParseError](initError(peReservedTypeInvalid, v.span,
        "(u8) value " & $v.intVal & " is out of range [0, 255]"))
    ok(void, ParseError)
  of kvBigInt:
    # Bigint magnitudes exceed int64.high by definition; cannot fit u8.
    err[void, ParseError](initError(peReservedTypeInvalid, v.span,
      "(u8) value exceeds 8-bit range (literal too large)"))
  else:
    err[void, ParseError](initError(peReservedTypeInvalid, v.span,
      "(u8) requires an integer value"))

func validateReserved*(tag: string, v: KdlValue):
    Result[void, ParseError] {.noSideEffect.} =
  ## Dispatch a reserved tag to its validator. Returns ok for unknown
  ## tags (open-world per spec) and ok for known tags with valid content.
  case tag
  of "u8": validateU8(v)
  else:    ok(void, ParseError)  # user-defined or not-yet-implemented
