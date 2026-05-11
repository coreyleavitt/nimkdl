# KDL v2 conformance corpus

Vendored from [kdl-org/kdl](https://github.com/kdl-org/kdl) at commit
`b8570137b6d3486a6b0cd64706f749c624ffd0ad` (matches the `CORPUS_SHA` file
in this directory).

The corpus is the canonical KDL v2 spec compliance suite — 338 input
documents, 243 of which have an `expected_kdl` counterpart (the
remaining 95 are negative cases that must fail to parse).

## How it's used

`test_conformance.nim` walks `input/` and for each case:

1. Parses with the **hand parser** (`parser.nim`)
2. Parses with the **reference interpreter** (`grammar.nim`)
3. If `expected_kdl/<case>.kdl` exists:
   - Both parses must succeed
   - Both parses must agree (`docEqual`)
   - Encoding either via `encode.nim` must round-trip-parse to a `docEqual` result
4. If `expected_kdl/<case>.kdl` is **absent** (negative case):
   - Both parsers must reject

`skips.txt` lists cases skipped from the harness, each with a one-line
reason. The bar for adding a skip is high: skips are tracked as
deliberate deviations from spec, not silent ignores.

## Updating the corpus

```
cd /tmp && git clone --depth 1 https://github.com/kdl-org/kdl.git
cp -r /tmp/kdl/tests/test_cases lib/kdl/tests/conformance/
cd /tmp/kdl && git rev-parse HEAD > lib/kdl/tests/conformance/CORPUS_SHA
```

Then re-run `./dev test`. Any new failures need either a fix in lib/kdl
or a documented `skips.txt` entry.
