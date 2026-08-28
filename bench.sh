#!/usr/bin/env bash
# Run FlowRat's benchmarks.
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
    c|mlir) ;;
    *)
        echo "flowrat: unknown backend '$backend' (expected c or mlir)" >&2
        exit 2
        ;;
esac

echo "machine: $(sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m)"
echo "os:      $(uname -sr)"
echo "cc:      $(clang --version | head -1)"
echo "backend: $backend"
if [ "$FLOWRAT_OPENMP" = "1" ]; then
    echo "openmp:  enabled (parallel for is threaded when the backend lowers to the runtime path)"
else
    echo "openmp:  not available"
fi
echo
exec "$FLOW_HOME/flow" run --backend="$backend" "$RATVILLE_ROOT/bench.flow" "$@"
