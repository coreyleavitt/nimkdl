#!/usr/bin/env bash
# Run all four parsers (nimkdl, ckdl, knus, kdl-rs) back-to-back in
# the same set of containers on the same fixtures. Numbers from this
# script are what BENCHMARK.md claims.
#
# Requires: podman (or docker — set CONTAINER_RUNTIME=docker).
# Each parser runs in its own glibc-based container so allocator
# behavior matches the published numbers.
#
# Usage:
#   benchmarks/comparisons/run.sh           # all four
#   benchmarks/comparisons/run.sh nimkdl    # one specific
set -euo pipefail

CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-podman}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
FIXTURE_DIR="$REPO_ROOT/benchmarks/fixtures"

# Map kdl-org conformance fixtures into the fixture dir for the
# Rust/C harnesses, which expect them at /fixtures/.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
# Stage every committed fixture so each harness sees byte-identical
# inputs at the same paths.
cp "$FIXTURE_DIR"/*.kdl "$STAGE/"
# The two small conformance fixtures live alongside the corpus; vendor
# in if present so old comparison tables can still be reproduced.
for f in all_node_fields.kdl all_escapes.kdl; do
  if [ -f "$REPO_ROOT/tests/conformance/test_cases/input/$f" ]; then
    cp "$REPO_ROOT/tests/conformance/test_cases/input/$f" "$STAGE/"
  fi
done

run_nimkdl() {
  echo "================================================================"
  echo "  nimkdl (this repo)"
  echo "================================================================"
  $CONTAINER_RUNTIME run --rm \
    -v "$REPO_ROOT:/work:Z" -w /work \
    docker.io/nimlang/nim:2.2.0 \
    sh -c 'nim c --hints:off -d:release -d:nimCallDepthLimit=20000 -p:src benchmarks/bench.nim 2>&1 | tail -1 && ./benchmarks/bench'
  echo ""
}

run_ckdl() {
  echo "================================================================"
  echo "  ckdl (C, event-drain)"
  echo "================================================================"
  # Build ckdl + the bench harness in a single gcc image.
  $CONTAINER_RUNTIME run --rm \
    -v "$HERE/ckdl:/work:Z" \
    -v "$STAGE:/fixtures:Z" \
    -w /work \
    docker.io/library/gcc:13 \
    sh -c '
      set -e
      apt-get update -qq >/dev/null 2>&1
      apt-get install -y -qq cmake git >/dev/null 2>&1
      if [ ! -d ckdl ]; then
        git clone --depth 1 https://github.com/tjol/ckdl.git
        cd ckdl
        cmake -B build -DCMAKE_BUILD_TYPE=Release \
          -DBUILD_KDL_SHARED_LIBRARY=OFF -DBUILD_KDLPP=OFF \
          -DBUILD_TESTS=OFF -DBUILD_EXAMPLES=OFF >/dev/null 2>&1
        cmake --build build -j >/dev/null 2>&1
        cd ..
      fi
      gcc -O3 -DNDEBUG -I ckdl/include -o bench bench.c ckdl/build/libkdl.a -lm
      ./bench
    '
  echo ""
}

run_knus() {
  echo "================================================================"
  echo "  knus (Rust, serde-style)"
  echo "================================================================"
  # knus 3.x derive uses edition2024; needs Rust >= 1.85.
  $CONTAINER_RUNTIME run --rm \
    -v "$HERE/knus:/work:Z" \
    -v "$STAGE:/fixtures:Z" \
    -w /work \
    docker.io/library/rust:1.86 \
    sh -c '
      mkdir -p src && cp main.rs src/main.rs
      cargo build --release 2>&1 | tail -3
      ./target/release/knus-bench
    '
  echo ""
}

run_facet_kdl() {
  echo "================================================================"
  echo "  facet-kdl (Rust, knus successor per knus README)"
  echo "================================================================"
  # facet 0.42 requires rustc 1.89+ per its workspace pins.
  $CONTAINER_RUNTIME run --rm \
    -v "$HERE/facet-kdl:/work:Z" \
    -v "$STAGE:/fixtures:Z" \
    -w /work \
    docker.io/library/rust:1.90 \
    sh -c '
      mkdir -p src && cp main.rs src/main.rs
      cargo build --release 2>&1 | tail -3
      ./target/release/facet-kdl-bench
    '
  echo ""
}

run_kdl_rs() {
  echo "================================================================"
  echo "  kdl-rs (Rust, canonical impl)"
  echo "================================================================"
  $CONTAINER_RUNTIME run --rm \
    -v "$HERE/kdl-rs:/work:Z" \
    -v "$STAGE:/fixtures:Z" \
    -w /work \
    docker.io/library/rust:1.83 \
    sh -c '
      mkdir -p src && cp main.rs src/main.rs
      cargo build --release 2>&1 | tail -3
      ./target/release/kdlrs-bench
    '
  echo ""
}

if [ $# -eq 0 ]; then
  run_nimkdl
  run_ckdl
  run_knus
  run_facet_kdl
  run_kdl_rs
  exit 0
fi

for target in "$@"; do
  case "$target" in
    nimkdl)    run_nimkdl ;;
    ckdl)      run_ckdl ;;
    knus)      run_knus ;;
    facet-kdl) run_facet_kdl ;;
    kdl-rs)    run_kdl_rs ;;
    *) echo "unknown target: $target (nimkdl|ckdl|knus|facet-kdl|kdl-rs)" >&2; exit 1 ;;
  esac
done
