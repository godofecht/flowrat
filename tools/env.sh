#!/usr/bin/env bash
# Shared environment for every FlowRat entry point.
#
# FLOW_HOME    where the Flow compiler lives. Override if your checkout is
#              somewhere else.
# FLOW_HOST    FlowRat uses imports, gfx and variadic printf, all of which are
#              Python-host features. The self-hosted flowc does not cover them
#              yet, so the host is pinned rather than left to default.
# CPATH /
# LIBRARY_PATH Apple clang rejects a bare -fopenmp and cannot find Homebrew's
#              libomp on the default search paths, so Flow's OpenMP probe
#              fails and every `parallel for` compiles to a serial loop. These
#              two variables are what the probe needs to succeed. Without
#              libomp installed the build still works and stays serial.

set -euo pipefail

FLOW_HOME="${FLOW_HOME:-$HOME/flow}"
export FLOW_HOST="${FLOW_HOST:-python}"

if [ ! -x "$FLOW_HOME/flow" ]; then
    echo "flowrat: no Flow compiler at $FLOW_HOME/flow" >&2
    echo "         set FLOW_HOME to your Flow checkout" >&2
    exit 1
fi

# Homebrew libomp, if present, on either Apple silicon or Intel prefixes.
for omp in /opt/homebrew/opt/libomp /usr/local/opt/libomp; do
    if [ -d "$omp/lib" ]; then
        export CPATH="${CPATH:+$CPATH:}$omp/include"
        export LIBRARY_PATH="${LIBRARY_PATH:+$LIBRARY_PATH:}$omp/lib"
        export DYLD_LIBRARY_PATH="${DYLD_LIBRARY_PATH:+$DYLD_LIBRARY_PATH:}$omp/lib"
        FLOWRAT_OPENMP=1
        break
    fi
done
FLOWRAT_OPENMP="${FLOWRAT_OPENMP:-0}"

# env.sh always lives in <root>/tools, so locate the root from this file
# rather than from $0: $0 is the calling script, which may sit anywhere.
_flowrat_self="${BASH_SOURCE[0]:-$0}"
RATVILLE_ROOT="$(cd "$(dirname "$_flowrat_self")/.." && pwd)"

flowrat_run() {
    "$FLOW_HOME/flow" "$@"
}
