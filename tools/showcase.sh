#!/usr/bin/env bash
# One-command, deterministic FlowRat showcase for a YouTube rough cut.
# It captures several live arenas, then uses the shared movie editor runner to
# add a title card and assemble them into one 16:9 H.264 file.
source "$(dirname "$0")/env.sh"
set -euo pipefail

out="${1:-$RATVILLE_ROOT/data/out/showcase}"
mkdir -p "$out"

record() {
  local name="$1" keycode="$2"
  FLOW_GFX_RECORD_KEYS="35:${keycode}" \
    "$FLOW_HOME/flow" record "$RATVILLE_ROOT/flowrat.flow" \
    --frames 420 --out "$out/$name" --fps 30 --stride 1 --width 1280 \
    2>&1 | grep -vE "Falling back|^Overload resolution|warning:|^ +\\||^ +\\^|generated\." | tail -5
}

# 23 = 5/T-maze, 25 = 7/obstacle field, 27 = 9/large colony field.
record t-maze 23
record obstacles 25
record large-field 27

for name in t-maze obstacles large-field; do
  ffmpeg -y -loglevel error -framerate 30 -i "$out/$name/%06d.ppm" \
    -c:v libx264 -pix_fmt yuv420p -crf 18 "$out/$name.mp4"
done

plan="$out/edit-plan.json"
python3 - "$out" "$plan" <<'PY'
import json, sys
from pathlib import Path
root = Path(sys.argv[1])
plan = {
    "inputs": [str(root / f"{name}.mp4") for name in ("t-maze", "obstacles", "large-field")],
    "output": str(root / "flowrat-showcase.mp4"),
    "fps": 30,
    "codec": "libx264",
    "audio_codec": "aac",
    "concat_method": "compose",
    "operations": [
        {"action": "resize", "width": 1920, "height": 1080},
        {"action": "fade_in", "duration": 0.6},
        {"action": "fade_out", "duration": 0.8},
        {"action": "text", "text": "FLOWRAT  /  living navigation experiments", "position": "top-left", "font_size": 42, "color": "#edf0f7", "start": 0, "duration": 42}
    ]
}
Path(sys.argv[2]).write_text(json.dumps(plan, indent=2))
PY
python3 "/Users/abhishekshivakumar/.codex/skills/moviepy-video-editor/scripts/run_moviepy_edit.py" --plan-file "$plan"
echo "showcase: $out/flowrat-showcase.mp4"
