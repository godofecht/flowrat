#!/usr/bin/env bash
# Compile and render N frames headless, then report where they went.
source "$(dirname "$0")/env.sh"
set +e
target="${1:?usage: record.sh <file.flow> [frames] [outdir]}"
frames="${2:-6}"
out="${3:-$RATVILLE_ROOT/data/out/frames}"
mkdir -p "$out"
"$FLOW_HOME/flow" record "$RATVILLE_ROOT/$target" --frames "$frames" --out "$out" 2>&1 \
  | grep -vE "Falling back|^Overload resolution" | tail -25
