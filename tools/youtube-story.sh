#!/usr/bin/env bash
# Build a coherent ten-minute FlowRat explainer from live recordings.
source "$(dirname "$0")/env.sh"
set -euo pipefail

out="${1:-$RATVILLE_ROOT/data/out/youtube-story}"
mkdir -p "$out"

record() {
  local name="$1" key="$2"
  FLOW_GFX_RECORD_KEYS="35:${key}" \
    "$FLOW_HOME/flow" record "$RATVILLE_ROOT/flowrat.flow" \
    --frames 420 --out "$out/frames-$name" --fps 30 --stride 1 --width 1280 \
    2>&1 | grep -vE "Falling back|^Overload resolution|warning:|^ +\\||^ +\\^|generated\." | tail -3
  ffmpeg -y -loglevel error -framerate 30 \
    -i "$out/frames-$name/frame_%05d.ppm" -c:v libx264 -pix_fmt yuv420p \
    -crf 18 "$out/$name.mp4"
}

# macOS virtual keycodes: 1=18, 4=21, 5=23, 7=26, 8=28, 9=25.
record open-field 18
record four-rooms 21
record t-maze 23
record obstacles 26
record plus-maze 28
record large-field 25

python3 - "$out" <<'PY'
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
import sys
root = Path(sys.argv[1])
font_paths = ["/System/Library/Fonts/Helvetica.ttc", "/System/Library/Fonts/SFNS.ttf"]
font_path = next((p for p in font_paths if Path(p).exists()), None)
def font(size):
    return ImageFont.truetype(font_path, size) if font_path else ImageFont.load_default()
def card(path, kicker, title, body, accent):
    im = Image.new("RGB", (1920, 1080), (9, 11, 18)); d = ImageDraw.Draw(im)
    for y in range(1080):
        mix = int(20 * y / 1080)
        d.line((0,y,1920,y), fill=(9+mix//3,11+mix//4,18+mix))
    d.rectangle((110, 130, 125, 950), fill=accent)
    d.text((180, 170), kicker.upper(), fill=(137, 150, 176), font=font(30))
    d.text((180, 250), title, fill=(237, 240, 247), font=font(78))
    d.multiline_text((185, 410), body, fill=(190, 199, 218), font=font(40), spacing=18)
    d.text((180, 920), "FLOWRAT  ·  illustrative computational experiment", fill=accent, font=font(26))
    im.save(path)
chapters = [
    ("01 · BASELINE", "Open-field exploration", "Question: how does a colony distribute\nitself when there is no internal structure?", "open-field", (131,173,255)),
    ("02 · SPATIAL MEMORY", "Four rooms + doorways", "Question: can navigation remain coherent\nwhen walls hide the goal?", "four-rooms", (123,211,177)),
    ("03 · DECISION", "T-maze choice", "Question: when two arms pay differently,\nwhich path does the colony learn to prefer?", "t-maze", (240,168,85)),
    ("04 · GEOMETRY", "Obstacle navigation", "Question: how much does internal geometry\nreshape trajectories and boundary signals?", "obstacles", (226,132,184)),
    ("05 · COMPETITION", "Plus maze + shared resources", "Question: what changes when rats must\nshare narrow routes and finite food?", "plus-maze", (224,177,104)),
    ("06 · COLONY SCALE", "Large field: hierarchy + life history", "Question: what becomes visible when the\nenvironment is large enough for social structure?", "large-field", (126,204,206)),
]
for idx, (kicker, title, body, name, accent) in enumerate(chapters):
    card(root / f"{name}-title.png", kicker, title, body, accent)
    conclusions = {
        "open-field": "Conclusion: occupancy spreads across the arena,\nwhile wall distance and local cues shape the paths.\n\nThis is a control condition—not a claim about rats.",
        "four-rooms": "Conclusion: barriers turn a single field into\nsequential navigation problems. Memory lets a\nrat revisit a useful room after losing sight of it.",
        "t-maze": "Conclusion: asymmetric reward creates a measurable\nchoice bias over repeated runs. The bias is a\nmodel result that can be compared with real tracks.",
        "obstacles": "Conclusion: internal walls add route structure\nand increase turning. Geometry alone can reshape\nneural and behavioral readouts.",
        "plus-maze": "Conclusion: shared patches create competition.\nSlow, proximity-gated bites make consumption\nvisible instead of instantaneous.",
        "large-field": "Conclusion: social rank, pregnancy, and juveniles\ncreate population-level state changes. The next step\nis calibration against tracked colony data.",
    }[name]
    card(root / f"{name}-conclusion.png", "WHAT THE RUN SUGGESTS", "Readout", conclusions, accent)
PY

names=(open-field four-rooms t-maze obstacles plus-maze large-field)
: > "$out/concat.txt"
for name in "${names[@]}"; do
  ffmpeg -y -loglevel error \
    -loop 1 -i "$out/$name-title.png" -t 6 -r 30 -pix_fmt yuv420p "$out/$name-title.mp4"
  ffmpeg -y -loglevel error \
    -stream_loop 5 -i "$out/$name.mp4" -t 84 -r 30 -pix_fmt yuv420p "$out/$name-run.mp4"
  ffmpeg -y -loglevel error \
    -loop 1 -i "$out/$name-conclusion.png" -t 10 -r 30 -pix_fmt yuv420p "$out/$name-conclusion.mp4"
  printf "file '%s'\nfile '%s'\nfile '%s'\n" \
    "$out/$name-title.mp4" "$out/$name-run.mp4" "$out/$name-conclusion.mp4" \
    >> "$out/concat.txt"
done
ffmpeg -y -loglevel error -f concat -safe 0 -i "$out/concat.txt" \
  -c:v libx264 -crf 19 -pix_fmt yuv420p -r 30 -movflags +faststart \
  "$out/flowrat-youtube-10min.mp4"
ffprobe -v error -show_entries format=duration,size \
  -show_entries stream=width,height,r_frame_rate -of default=noprint_wrappers=1 \
  "$out/flowrat-youtube-10min.mp4"
echo "story video: $out/flowrat-youtube-10min.mp4"
