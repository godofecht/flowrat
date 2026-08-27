#!/usr/bin/env bash
# Build FlowRat for the browser and serve it.
#
# The --link is not optional. The profiler's monotonic clock lives in
# flow_rt_support.c, which the browser build does not pull in on its own, and
# without it emcc fails on that one undefined symbol.
#
# The batch runs single-threaded in the browser: `parallel for` needs
# SharedArrayBuffer and the cross-origin isolation headers that go with it,
# so this is the serial fallback rather than a slower copy of the native run.
source "$(dirname "$0")/env.sh"
set -e
out="$FLOW_HOME/build/wasm/flowrat"
"$FLOW_HOME/flow" wasm "$RATVILLE_ROOT/flowrat.flow" \
    --link "$FLOW_HOME/runtime/flow_rt_support.c"
# The compiler owns the WASM loader, while this checked-in shell owns the
# product UI. Keeping the shell here means rebuilds retain the intro,
# transport controls, fullscreen action, and FlowRat extension API.
cp "$RATVILLE_ROOT/web/index.html" "$out/index.html"
port="${1:-8731}"
echo
echo "serving $out on http://localhost:$port"
exec python3 -m http.server "$port" -d "$out"
