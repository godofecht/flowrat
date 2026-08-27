#!/usr/bin/env bash
# Drive the interface through a scripted session and record the frames.
#
# This exercises the interactive path the headless validation cannot reach:
# a keyboard arena switch, a click on a tool in the editor panel, and a drag
# in the arena that has to commit a new obstacle on release.
source "$(dirname "$0")/env.sh"
set +e
out="${1:-$RATVILLE_ROOT/data/out/uidemo}"
frames="${2:-300}"
mkdir -p "$out"

# key windows: frame:keycode   23 = '5' -> the t maze preset
KEYS="60:23"

# mouse: first,last,x0,y0,x1,y1,button,wheel   segments separated by ';'
#   130-134  press the box tool in the editor panel
#   150-200  drag a block inside the arena
#   210-214  press the erase tool (row 2, middle column of the tool grid)
#   240-244  click inside the block to remove it again
MOUSE="130,134,1200,623,1200,623,1,0;150,200,240,200,360,330,1,0;210,214,1290,643,1290,643,1,0;240,244,300,265,300,265,1,0"

FLOW_GFX_RECORD_KEYS="$KEYS" FLOW_GFX_RECORD_MOUSE="$MOUSE" \
  "$FLOW_HOME/flow" record "$RATVILLE_ROOT/flowrat.flow" \
  --frames "$frames" --out "$out" 2>&1 \
  | grep -vE "Falling back|^Overload resolution|warning:|^ +\||^ +\^|generated\." | tail -6
