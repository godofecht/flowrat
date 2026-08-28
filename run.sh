#!/usr/bin/env bash
# Launch FlowRat in a window.
#
# Default: C backend via Flow's native gfx command.
# MLIR:   ./run.sh --mlir
#         FLOWRAT_BACKEND=mlir ./run.sh
#
# Needs a display. In a headless session use tools/record.sh instead, which
# renders frames to disk, or tools/uidemo.sh for a scripted session.
source "$(dirname "$0")/tools/env.sh"

backend="${FLOWRAT_BACKEND:-c}"

case "${1:-}" in
    --mlir|--backend=mlir)
        backend="mlir"
        shift
        ;;
    --backend=c)
        backend="c"
        shift
        ;;
    --backend)
        backend="${2:-}"
        if [ -z "$backend" ]; then
            echo "flowrat: --backend requires c or mlir" >&2
            exit 2
        fi
        shift 2
        ;;
esac

case "$backend" in
    mlir)
        exec bash "$RATVILLE_ROOT/tools/mlir-gfx.sh" "$@"
        ;;
    c)
        exec "$FLOW_HOME/flow" gfx "$RATVILLE_ROOT/flowrat.flow" "$@"
        ;;
    *)
        echo "flowrat: unknown backend '$backend' (expected c or mlir)" >&2
        exit 2
        ;;
esac
