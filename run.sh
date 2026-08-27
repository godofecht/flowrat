#!/usr/bin/env bash
# Launch FlowRat in a window.
#
# Needs a display. In a headless session use tools/record.sh instead, which
# renders frames to disk, or tools/uidemo.sh for a scripted session.
source "$(dirname "$0")/tools/env.sh"
exec "$FLOW_HOME/flow" gfx "$RATVILLE_ROOT/flowrat.flow" "$@"
