#!/usr/bin/env bash
# Run FlowRat's functional validation.
source "$(dirname "$0")/tools/env.sh"
exec "$FLOW_HOME/flow" run "$RATVILLE_ROOT/validate.flow" "$@"
