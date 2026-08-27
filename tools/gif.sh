#!/usr/bin/env bash
# Record the scripted session straight to a GIF.
source "$(dirname "$0")/env.sh"
set +e
gif="${1:-$RATVILLE_ROOT/docs/flowrat.gif}"
frames="${2:-300}"
KEYS="60:23"
MOUSE="130,134,1200,623,1200,623,1,0;150,200,240,200,360,330,1,0;210,214,1290,643,1290,643,1,0;240,244,300,265,300,265,1,0"
mkdir -p "$(dirname "$gif")"
FLOW_GFX_RECORD_KEYS="$KEYS" FLOW_GFX_RECORD_MOUSE="$MOUSE" \
  "$FLOW_HOME/flow" record "$RATVILLE_ROOT/flowrat.flow" \
  --frames "$frames" --gif "$gif" --stride 3 --width 720 2>&1 \
  | grep -viE "falling back|overload resolution|warning:|^ +\||^ +\^|generated\." | tail -5
