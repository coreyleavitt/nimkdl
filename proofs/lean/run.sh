#!/usr/bin/env bash
# Check the KDL formal-proof track (Tier 0; see docs/rfc-conformance-assurance.md).
# Builds a cached Lean image on first run, then `lean` checks each .lean file.
#   Usage: proofs/lean/run.sh
#   Requires: podman (or CONTAINER_RUNTIME=docker); network only on the first build.
set -euo pipefail
RUNTIME="${CONTAINER_RUNTIME:-podman}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$RUNTIME" image exists localhost/lean-nkdl 2>/dev/null || "$RUNTIME" build -t localhost/lean-nkdl "$DIR"
"$RUNTIME" run --rm -v "$DIR:/work:Z" -w /work localhost/lean-nkdl \
  sh -c 'for f in Kdl/Value.lean Kdl/Number.lean Kdl/Str.lean Kdl/Doc.lean Kdl/NamedDoc.lean Kdl/ArgsDoc.lean; do echo "== $f =="; lean "$f"; done'
