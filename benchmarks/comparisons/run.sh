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
  echo "  nimkdl (this repo) -- comprehensive harness"
  echo "  parse / typed-decode (legacy + direct) / typed-encode (legacy + direct, flat + nested)"
  echo "================================================================"
  # Comprehensive harness: parse + typed decode (both legacy AST and
  # direct parseInto) + typed encode (both legacy and direct encodeFrom,
  # flat + nested shapes). All in one container build so the comparison
  # transcript is contiguous with the Rust/C harnesses below.
  $CONTAINER_RUNTIME run --rm \
    -v "$REPO_ROOT:/work:Z" \
    -v "$STAGE:/fixtures:Z" \
    -w /work \
    docker.io/nimlang/nim:2.2.0 \
    sh -c '
      set -e
      nim c --hints:off -d:release -d:lto \
        -p:/work/src -o:/tmp/nimkdl-bench \
        benchmarks/comparisons/nimkdl/bench.nim 2>&1 | tail -3
      /tmp/nimkdl-bench
    '
  echo ""
}

run_nimkdl_legacy() {
  # The original parse-only bench, kept around for historical
  # continuity with old comparison tables in BENCHMARK.md.
  echo "================================================================"
  echo "  nimkdl (legacy parse-only bench — for historical continuity)"
  echo "================================================================"
  $CONTAINER_RUNTIME run --rm \
    -v "$REPO_ROOT:/work:Z" -w /work \
    docker.io/nimlang/nim:2.2.0 \
    sh -c 'nim c --hints:off -d:release -d:lto -p:src benchmarks/bench.nim 2>&1 | tail -1 && ./benchmarks/bench'
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
      mkdir -p src && cp main.rs src/main.rs && cp mem.rs src/mem.rs
      cargo build --release --bin knus-bench 2>&1 | tail -3
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
      mkdir -p src && cp main.rs src/main.rs && cp mem.rs src/mem.rs
      cargo build --release --bin facet-kdl-bench 2>&1 | tail -3
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

# Canonical fixtures for memory matrix — the three that exercise the
# distinct regimes: huge tree (peak-driven), small realistic (held-doc-
# driven), and typed homogeneous (apples-to-apples typed decode).
MEM_FIXTURES=(tree-d8-b3.kdl realistic-config.kdl homogeneous-services-100.kdl)

run_memory() {
  echo "================================================================"
  echo "  Memory footprint (Linux VmPeak, KB)"
  echo "  One fresh process per (parser, fixture) — VmPeak is monotonic."
  echo "================================================================"

  # nimkdl mem — build once, run per fixture.
  $CONTAINER_RUNTIME run --rm \
    -v "$REPO_ROOT:/work:Z" \
    -v "$STAGE:/fixtures:Z" \
    -w /work \
    docker.io/nimlang/nim:2.2.0 \
    sh -c '
      set -e
      nim c --hints:off -d:release -d:lto \
        -p:/work/src -o:/tmp/nimkdl-mem \
        benchmarks/comparisons/nimkdl/mem.nim 2>&1 | tail -1 >&2
      for f in '"${MEM_FIXTURES[*]}"'; do
        /tmp/nimkdl-mem /fixtures/$f
      done
    '

  # ckdl mem — build alongside the existing bench binary.
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
      gcc -O3 -DNDEBUG -I ckdl/include -o ckdl-mem mem.c ckdl/build/libkdl.a -lm
      for f in '"${MEM_FIXTURES[*]}"'; do
        ./ckdl-mem /fixtures/$f
      done
    '

  # knus mem.
  $CONTAINER_RUNTIME run --rm \
    -v "$HERE/knus:/work:Z" \
    -v "$STAGE:/fixtures:Z" \
    -w /work \
    docker.io/library/rust:1.86 \
    sh -c '
      set -e
      mkdir -p src && cp main.rs src/main.rs && cp mem.rs src/mem.rs
      cargo build --release --bin knus-mem 2>&1 | tail -1 >&2
      for f in '"${MEM_FIXTURES[*]}"'; do
        ./target/release/knus-mem /fixtures/$f
      done
    '

  # facet-kdl mem (only homogeneous-services is supported; others
  # print a SKIPPED line — see harness comment for the asymmetry).
  $CONTAINER_RUNTIME run --rm \
    -v "$HERE/facet-kdl:/work:Z" \
    -v "$STAGE:/fixtures:Z" \
    -w /work \
    docker.io/library/rust:1.90 \
    sh -c '
      set -e
      mkdir -p src && cp main.rs src/main.rs && cp mem.rs src/mem.rs
      cargo build --release --bin facet-kdl-mem 2>&1 | tail -1 >&2
      for f in '"${MEM_FIXTURES[*]}"'; do
        ./target/release/facet-kdl-mem /fixtures/$f
      done
    '

  # kdl-rs mem.
  $CONTAINER_RUNTIME run --rm \
    -v "$HERE/kdl-rs:/work:Z" \
    -v "$STAGE:/fixtures:Z" \
    -w /work \
    docker.io/library/rust:1.83 \
    sh -c '
      set -e
      cargo build --release --bin kdlrs-mem 2>&1 | tail -1 >&2
      for f in '"${MEM_FIXTURES[*]}"'; do
        ./target/release/kdlrs-mem /fixtures/$f
      done
    '
  echo ""
}

if [ $# -eq 0 ]; then
  run_nimkdl
  run_ckdl
  run_knus
  run_facet_kdl
  run_kdl_rs
  run_memory
  exit 0
fi

for target in "$@"; do
  case "$target" in
    nimkdl)        run_nimkdl ;;
    nimkdl-legacy) run_nimkdl_legacy ;;
    ckdl)          run_ckdl ;;
    knus)          run_knus ;;
    facet-kdl)     run_facet_kdl ;;
    kdl-rs)        run_kdl_rs ;;
    memory)        run_memory ;;
    *) echo "unknown target: $target (nimkdl|nimkdl-legacy|ckdl|knus|facet-kdl|kdl-rs|memory)" >&2; exit 1 ;;
  esac
done
