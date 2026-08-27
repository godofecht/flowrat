#!/usr/bin/env bash
# Regenerate the demo configurations in data/configs.
source "$(dirname "$0")/env.sh"
cd "$RATVILLE_ROOT" || exit 1
exec "$FLOW_HOME/flow" run "$RATVILLE_ROOT/mkconfig.flow"
