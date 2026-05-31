#!/usr/bin/env bash
# Spec-coverage gap finder.
#
# Measures which branches of the LEXER (and numlit) the spec-coverage
# generators actually exercise, via gcov/lcov. A COLD function — never
# called across the whole generator campaign — is a lexical form the
# generators don't yet produce (or, for error-emit paths, an input class
# that needs negative generation). This is the measured driver of generator
# completeness: run it after each new slice and watch the cold set shrink.
#
# Why coverage and not eyeballing the grammar: a generator's self-coverage
# can't reveal a form it doesn't know about, but nkdl code coverage can —
# the corresponding branch stays cold until something generates the input.
# gcov counts are deterministic (immune to the WSL2 wall-clock noise).
#
#   Usage: tests/coverage.sh [test-file]   (default tests/test_spec_coverage.nim)
#   Requires: podman (or CONTAINER_RUNTIME=docker).
set -euo pipefail

TEST="${1:-tests/test_spec_coverage.nim}"
RUNTIME="${CONTAINER_RUNTIME:-podman}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

"$RUNTIME" run --rm -e NKDL_PROPTEST=1 -v "$REPO:/work:Z" -w /work \
  docker.io/nimlang/nim:2.2.0 sh -c '
    set -e
    apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq lcov >/dev/null 2>&1
    rm -rf /tmp/cov && mkdir -p /tmp/cov
    nim c --hints:off --warnings:off --debugger:native \
      --passC:--coverage --passL:--coverage \
      --nimcache:/tmp/cov -d:nimCallDepthLimit=20000 \
      -o:/tmp/covtest '"$TEST"' >/dev/null 2>&1
    /tmp/covtest >/dev/null 2>&1 || true
    cd /tmp/cov
    # lcov 2.0 is strict about Nim`s #line directives; downgrade to warnings.
    IGN="--ignore-errors inconsistent,mismatch,source,unused,empty,negative,range,gcov,utility"
    lcov --capture --directory . --output-file cov.info $IGN --quiet 2>/dev/null
    lcov --extract cov.info "*lexer.nim" "*numlit.nim" -o filt.info $IGN --quiet 2>/dev/null
    echo "=== line / function coverage ==="
    lcov --list filt.info $IGN 2>/dev/null | grep -E "nim|Total"
    echo "=== COLD functions (never exercised — gaps to close) ==="
    awk -F, "/^FNA:/ && \$2==0 {print \$3}" filt.info \
      | sed -E "s/_ZN[0-9]+(lexer|numlit)[0-9]+([A-Za-z0-9_]+)E.*/\1.\2/; s/E[0-9].*$//" \
      | grep -vE "dollar|^_ZN" | sort -u
  ' 2>&1 | grep -vE "warning|inconsistent|ignore message|Message summary|count:"
