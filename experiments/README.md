# FlowRat experiments

Experiment plans use TOML. The plan is the cue sheet: it names the protocol,
seed, arena, simulation timing, movement, behavior, neural settings, recording,
and analysis outputs in one reproducible file.

```bash
python3 tools/flowrat_experiment.py validate experiments/open-field.flowrat.toml
python3 tools/flowrat_experiment.py generate experiments/open-field.flowrat.toml \
  --output data/out/experiments/open-field.synthetic.csv
python3 tools/flowrat_experiment.py analyze data/out/experiments/open-field.synthetic.csv \
  --output data/out/experiments/open-field.metrics.json
```

To run the actual FlowRat simulator, use `run`. It executes the same Flow
`Sim` and recorder used by the app and copies trajectory, neural, recurrent,
occupancy, and rate-map outputs into the requested directory:

```bash
python3 tools/flowrat_experiment.py run experiments/presets/t-maze.flowrat.toml \
  --output-dir data/out/experiments/tmaze-flow
```

The included protocols are behavioral experiments, not just visual arenas:

- `open-field`: baseline exploration and occupancy
- `t-maze`: left/right goal choice
- `obstacle-navigation`: boundary and obstacle avoidance
- `homing`: outbound exploration followed by return-to-home
- `cue-remapping`: a goal/cue change halfway through the run

## Real tracked movement

Export a tracker table with `time,x,y,rat` (or `frame,x_px,y_px,animal_id`) and
normalize it into the FlowRat trajectory schema:

```bash
python3 tools/flowrat_experiment.py import-tracking tracked.csv \
  --pixels-per-unit 120 --frame-rate 30 \
  --output data/out/experiments/rat-01.normalized.csv
python3 tools/flowrat_experiment.py compare \
  --real data/out/experiments/rat-01.normalized.csv \
  --synthetic data/out/experiments/homing.synthetic.csv \
  --output data/out/experiments/homing-vs-real.json
```

This bridge is deliberately measurement-first: it compares movement features
such as path length, speed, turning rate, and duration. It does not claim that
synthetic behavior is biological evidence. The next extension should add
tracker confidence, missing-frame interpolation, arena calibration, and neural
recordings synchronized to the same timestamps.

For a quick fixed-camera video baseline, foreground centroids can be emitted
directly. This is useful for smoke tests and sparse single-animal footage; use
DeepLabCut or SLEAP for identity-preserving research tracks:

```bash
python3 tools/flowrat_experiment.py track-video rat.mp4 \
  --frame-rate 30 --min-area 80 --max-area 10000 \
  --output data/out/experiments/rat.video-track.csv
```
