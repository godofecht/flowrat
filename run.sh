#!/usr/bin/env bash
# Launch FlowRat in a window.
#
# Default: Flow -> C native gfx path.
# --mlir:   Flow -> MLIR -> LLVM native gfx path.
#
# Needs a display. In a headless session use tools/record.sh instead, which
# renders frames to disk, or tools/uidemo.sh for a scripted session.
source "$(dirname "$0")/tools/env.sh"

if [ "${1:-}" = "--mlir" ]; then
    shift
    exec "$RATVILLE_ROOT/tools/run-mlir.sh" "$@"
fi

exec "$FLOW_HOME/flow" gfx "$RATVILLE_ROOT/flowrat.flow" "$@"
