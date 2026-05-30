#!/bin/bash
# Multi-run perf bench. Reports min/median/max per profile so noise
# vs signal is distinguishable. PhD-CS hygiene.
set -euo pipefail

N="${N:-7}"
HERE="$(cd "$(dirname "$0")" && pwd)"

run_profile() {
  local prof="$1"
  local times=()
  for ((i=0; i<N; i++)); do
    local us
    # Parse the "= NN.NN μs/op" tail from the profile binary's output.
    us=$(/tmp/$prof | sed -n 's/.* = \([0-9.]*\) μs\/.*/\1/p' | head -1)
    times+=("$us")
  done
  IFS=$'\n' sorted=($(sort -g <<< "${times[*]}"))
  unset IFS
  local n=${#sorted[@]}
  local mid=$((n/2))
  printf "  %-18s  min=%s  median=%s  max=%s\n" \
    "$prof" "${sorted[0]}" "${sorted[$mid]}" "${sorted[$((n-1))]}"
}

cd "$HERE/.."
for prof in profile_cat1 profile_decode profile_parse; do
  nim c --hints:off -d:release -d:lto -p:src \
      -o:/tmp/$prof benchmarks/$prof.nim >/dev/null 2>&1
done
echo "=== $N runs each, units = μs/op ==="
for prof in profile_cat1 profile_decode profile_parse; do
  run_profile "$prof"
done
