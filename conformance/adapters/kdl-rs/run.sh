#!/usr/bin/env bash
# Cross-impl certification: run the clean-room corpus against the Rust `kdl`
# crate (the KDL 2.0 reference impl) and check agreement with the oracle.
#   Usage: conformance/adapters/kdl-rs/run.sh
#   Requires: podman (or CONTAINER_RUNTIME=docker) + network (cargo fetches kdl).
set -euo pipefail
RUNTIME="${CONTAINER_RUNTIME:-podman}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
"$RUNTIME" run --rm -v "$REPO:/work:Z" -w /work docker.io/library/rust:1-slim \
  cargo run -q --manifest-path conformance/adapters/kdl-rs/Cargo.toml -- conformance/corpus
