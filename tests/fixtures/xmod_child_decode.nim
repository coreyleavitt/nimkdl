## Fixture for the cross-module deriveDecode export regression (see
## test_derive_decode.nim). `XmodChild` is derived here at TOP LEVEL with
## `exported = true` so its generated `kdlDecode` crosses the module boundary —
## a parent type in another module can then compose it as a {.kdlChild.}.
import ../../src/nkdl

type XmodChild* {.kdlNode: "child".} = object
  items* {.kdlSkip.}: seq[string]       # exercises the skip-seq drop too
  flag* {.kdlProp.}: bool = false

deriveDecode(XmodChild, exported = true)
