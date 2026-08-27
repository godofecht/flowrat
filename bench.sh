#!/usr/bin/env bash
# Run FlowRat's benchmarks.
source "$(dirname "$0")/tools/env.sh"
echo "machine: $(sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m)"
echo "os:      $(uname -sr)"
echo "cc:      $(clang --version | head -1)"
if [ "$FLOWRAT_OPENMP" = "1" ]; then
    echo "openmp:  enabled (parallel for is threaded)"
else
    echo "openmp:  not available (parallel for runs serially)"
fi
echo
exec "$FLOW_HOME/flow" run "$RATVILLE_ROOT/bench.flow" "$@"
