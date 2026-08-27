#!/usr/bin/env python3
"""Reproducible FlowRat experiment plans, synthetic data, and tracker analysis.

The simulator remains the authoritative biological model. This tool is the
experiment layer around it: it validates a readable TOML protocol, generates
deterministic movement fixtures for protocol development, normalizes tracked
rat CSVs, and compares movement features without pretending synthetic data is
experimental evidence.
"""
from __future__ import annotations

import argparse
import csv
import json
import math
import os
import random
import shutil
import statistics
import subprocess
import sys
import tempfile
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PRESET_DIR = ROOT / "experiments" / "presets"
DEFAULT_OUT = ROOT / "data" / "out" / "experiments"
PRESET_IDS = {"open_field": 0, "circle": 1, "two_rooms": 2, "four_rooms": 3,
              "t_maze": 4, "linear_track": 5, "obstacles": 6, "plus_maze": 7}
PRESET_IDS["large_field"] = 8

PRESET_DEFAULTS = {
    "open_field": {"arena": {"width": 2.0, "height": 2.0, "goal_x": 1.0, "goal_y": 1.0}, "policy": "explore"},
    "t_maze": {"arena": {"width": 2.0, "height": 1.4, "goal_x": 1.0, "goal_y": 1.2}, "policy": "choice"},
    "obstacle_navigation": {"arena": {"width": 2.0, "height": 2.0, "goal_x": 1.8, "goal_y": 1.8}, "policy": "avoid"},
    "homing": {"arena": {"width": 2.0, "height": 2.0, "goal_x": 0.3, "goal_y": 0.3}, "policy": "home"},
    "cue_remapping": {"arena": {"width": 2.0, "height": 2.0, "goal_x": 1.7, "goal_y": 1.7}, "policy": "remap"},
    "large_field": {"arena": {"width": 4.0, "height": 3.2, "goal_x": 2.0, "goal_y": 1.6}, "policy": "colony"},
}


def deep_merge(base: dict, override: dict) -> dict:
    out = dict(base)
    for key, value in override.items():
        if isinstance(value, dict) and isinstance(out.get(key), dict):
            out[key] = deep_merge(out[key], value)
        else:
            out[key] = value
    return out


def load_toml(path: Path) -> dict:
    with path.open("rb") as handle:
        return tomllib.load(handle)


def load_plan(path: Path) -> dict:
    plan = load_toml(path)
    experiment = plan.get("experiment", {})
    preset = experiment.get("preset", "open_field")
    merged = deep_merge(PRESET_DEFAULTS.get(preset, {}), plan)
    merged["_source"] = str(path)
    merged["_preset"] = preset
    return merged


def validate(plan: dict) -> list[str]:
    errors = []
    exp = plan.get("experiment", {})
    sim = plan.get("simulation", {})
    arena = plan.get("arena", {})
    if not exp.get("name"):
        errors.append("[experiment].name is required")
    if plan.get("_preset") not in PRESET_DEFAULTS:
        errors.append(f"unknown experiment preset: {plan.get('_preset')}")
    for key, low in (("seed", 0), ("rats", 1), ("duration_s", 0.01), ("sample_hz", 1)):
        value = exp.get(key)
        if value is None:
            errors.append(f"[experiment].{key} is required")
        elif value < low:
            errors.append(f"[experiment].{key} must be >= {low}")
    for key, low in (("dt", 1e-5), ("steps_per_frame", 1)):
        value = sim.get(key)
        if value is not None and value < low:
            errors.append(f"[simulation].{key} must be >= {low}")
    for key in ("width", "height"):
        if arena.get(key, 0) <= 0:
            errors.append(f"[arena].{key} must be positive")
    if exp.get("rats", 1) > 4096:
        errors.append("[experiment].rats exceeds FlowRat MAX_RATS (4096)")
    return errors


def clamp(value: float, low: float, high: float) -> float:
    return max(low, min(high, value))


def unit(dx: float, dy: float) -> tuple[float, float]:
    length = math.hypot(dx, dy) or 1.0
    return dx / length, dy / length


def synthetic(plan: dict, output: Path) -> dict:
    exp, arena = plan["experiment"], plan["arena"]
    width, height = float(arena["width"]), float(arena["height"])
    hz, duration, rats = float(exp["sample_hz"]), float(exp["duration_s"]), int(exp["rats"])
    steps = int(round(hz * duration))
    rng = random.Random(int(exp["seed"]))
    speed = float(plan.get("motion", {}).get("speed_mean", 0.22))
    turn_noise = float(plan.get("motion", {}).get("turn_sigma", 1.1))
    policy = plan.get("policy", "explore")
    output.parent.mkdir(parents=True, exist_ok=True)
    rows = []
    for rat in range(rats):
        x = rng.uniform(0.12 * width, 0.88 * width)
        y = rng.uniform(0.12 * height, 0.88 * height)
        heading = rng.uniform(-math.pi, math.pi)
        hunger = 0.15
        for step in range(steps + 1):
            time = step / hz
            goal_x, goal_y = float(arena.get("goal_x", width / 2)), float(arena.get("goal_y", height / 2))
            if policy == "choice":
                goal_x = 0.18 * width if rat % 2 == 0 else 0.82 * width
                goal_y = 0.88 * height
            elif policy == "home":
                if time < duration * 0.42:
                    goal_x, goal_y = 0.82 * width, 0.82 * height
                else:
                    goal_x, goal_y = 0.18 * width, 0.18 * height
            elif policy == "remap" and time > duration * 0.5:
                goal_x, goal_y = 0.25 * width, 0.8 * height
            dx, dy = goal_x - x, goal_y - y
            if policy == "explore":
                desired = heading + rng.gauss(0.0, turn_noise * 0.08)
            else:
                desired = math.atan2(dy, dx) + rng.gauss(0.0, turn_noise * 0.05)
            delta = (desired - heading + math.pi) % (2 * math.pi) - math.pi
            heading += clamp(delta, -0.18, 0.18)
            if policy == "avoid":
                for ox, oy, radius in ((0.65 * width, 0.52 * height, 0.18), (0.48 * width, 0.78 * height, 0.14)):
                    odx, ody = x - ox, y - oy
                    if math.hypot(odx, ody) < radius:
                        away_x, away_y = unit(odx, ody)
                        heading = math.atan2(away_y, away_x)
            actual_speed = max(0.01, speed * (0.82 + 0.26 * rng.random()))
            if step:
                x += math.cos(heading) * actual_speed / hz
                y += math.sin(heading) * actual_speed / hz
                x, y = clamp(x, 0.04 * width, 0.96 * width), clamp(y, 0.04 * height, 0.96 * height)
                hunger = clamp(hunger + 0.002 - (0.004 if math.hypot(x - goal_x, y - goal_y) < 0.12 else 0), 0, 1)
            rows.append({"step": step, "time": f"{time:.6f}", "rat": rat, "x": f"{x:.6f}", "y": f"{y:.6f}", "heading": f"{heading:.6f}", "speed": f"{actual_speed:.6f}", "hunger": f"{hunger:.6f}", "eaten": 0})
    with output.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    return {"rows": len(rows), "rats": rats, "duration_s": duration, "sample_hz": hz, "source": "synthetic", "preset": plan["_preset"]}


ALIASES = {"frame": "step", "timestamp": "time", "x_px": "x", "y_px": "y", "animal": "rat", "animal_id": "rat"}


def import_tracking(input_path: Path, output: Path, pixels_per_unit: float = 1.0, frame_rate: float = 30.0) -> dict:
    with input_path.open(newline="") as handle:
        reader = csv.DictReader(handle)
        fields = {name.strip().lower(): name for name in (reader.fieldnames or [])}
        def field(name: str) -> str | None:
            return fields.get(name) or fields.get(next((a for a, b in ALIASES.items() if b == name), ""))
        x_key, y_key = field("x"), field("y")
        if not x_key or not y_key:
            raise ValueError("tracker CSV needs x/y columns (or x_px/y_px)")
        time_key, step_key, rat_key = field("time"), field("step"), field("rat")
        rows = []
        for index, row in enumerate(reader):
            x, y = float(row[x_key]) / pixels_per_unit, float(row[y_key]) / pixels_per_unit
            step = int(float(row[step_key])) if step_key and row[step_key] else index
            time = float(row[time_key]) if time_key and row[time_key] else step / frame_rate
            rat = int(float(row[rat_key])) if rat_key and row[rat_key] else 0
            rows.append({"step": step, "time": f"{time:.6f}", "rat": rat, "x": f"{x:.6f}", "y": f"{y:.6f}"})
    if not rows:
        raise ValueError("tracker CSV contained no rows")
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0]))
        writer.writeheader(); writer.writerows(rows)
    return {"rows": len(rows), "rats": len({r["rat"] for r in rows}), "source": "tracked_csv", "output": str(output)}


def track_video(input_path: Path, output: Path, frame_rate: float = 30.0,
                min_area: int = 80, max_area: int = 10000) -> dict:
    """Extract foreground centroids from a fixed-camera video.

    This is a transparent baseline for quick inspection, not a replacement
    for pose estimation. For serious data use DeepLabCut or SLEAP and feed
    their CSV export to import_tracking.
    """
    try:
        import cv2
    except ImportError as exc:
        raise RuntimeError("track-video needs OpenCV; use import-tracking for tracker CSV exports") from exc
    capture = cv2.VideoCapture(str(input_path))
    if not capture.isOpened():
        raise ValueError(f"could not open video: {input_path}")
    subtractor = cv2.createBackgroundSubtractorMOG2(history=300, varThreshold=32, detectShadows=False)
    rows, frame = [], 0
    while True:
        ok, image = capture.read()
        if not ok:
            break
        mask = subtractor.apply(image)
        mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (3, 3)))
        mask = cv2.dilate(mask, None, iterations=1)
        contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
        candidates = []
        for contour in contours:
            area = cv2.contourArea(contour)
            if min_area <= area <= max_area:
                moments = cv2.moments(contour)
                if moments["m00"]:
                    candidates.append((moments["m10"] / moments["m00"], moments["m01"] / moments["m00"], area))
        # The baseline emits each visible component as a track with a frame
        # local id. Identity-preserving multi-animal tracking belongs in the
        # dedicated tracker, where crossings can be handled explicitly.
        for rat, (x, y, area) in enumerate(sorted(candidates, key=lambda c: c[0])):
            rows.append({"step": frame, "time": f"{frame / frame_rate:.6f}", "rat": rat,
                         "x": f"{x:.6f}", "y": f"{y:.6f}", "confidence": f"{min(1.0, area / max_area):.6f}"})
        frame += 1
    capture.release()
    if not rows:
        raise ValueError("no foreground components detected; adjust min/max area or use a tracker export")
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0])); writer.writeheader(); writer.writerows(rows)
    return {"frames": frame, "rows": len(rows), "source": "opencv_foreground_centroids", "output": str(output)}


FLOW_IMPORTS = '''import "src/core/mem.flow"
import "src/core/rng.flow"
import "src/core/clock.flow"
import "src/core/profile.flow"
import "src/env/geometry.flow"
import "src/env/environment.flow"
import "src/env/queries.flow"
import "src/env/presets.flow"
import "src/sim/agents.flow"
import "src/sim/integrate.flow"
import "src/sim/behaviour.flow"
import "src/sim/memory.flow"
import "src/sim/spatial.flow"
import "src/sim/novelty.flow"
import "src/sim/motion.flow"
import "src/neural/population.flow"
import "src/neural/place.flow"
import "src/neural/head_direction.flow"
import "src/neural/velocity.flow"
import "src/neural/grid.flow"
import "src/neural/boundary.flow"
import "src/neural/attractor.flow"
import "src/neural/circuit.flow"
import "src/sim/simulation.flow"
import "src/analysis/ratemap.flow"
import "src/analysis/scores.flow"
import "src/analysis/session.flow"
import "src/io/record.flow"
'''


def flow_literal(value):
    if isinstance(value, bool): return "true" if value else "false"
    if isinstance(value, int): return str(value)
    return f"{float(value):.12g}"


def flow_batch_source(plan: dict) -> str:
    exp, sim = plan["experiment"], plan.get("simulation", {})
    motion, behaviour, memory = plan.get("motion", {}), plan.get("behaviour", plan.get("behavior", {})), plan.get("memory", {})
    neural = plan.get("neural", {})
    assignments = [f"s.dt = {flow_literal(sim.get('dt', 1.0 / exp['sample_hz']))}",
                   f"s.steps_per_frame = {flow_literal(sim.get('steps_per_frame', 1))}",
                   f"s.require_sight = {flow_literal(sim.get('require_sight', True))}",
                   f"s.spiking = {flow_literal(sim.get('spiking', False))}",
                   f"s.can_enabled = {flow_literal(sim.get('continuous_attractors', sim.get('can_enabled', True)))}"]
    for section, prefix, allowed in ((motion, "s.motion", ("speed_mean", "speed_sigma", "speed_tau", "speed_max", "turn_sigma", "turn_tau", "turn_max", "wall_range", "wall_gain", "thigmotaxis", "cue_gain", "rest_rate", "margin", "metabolism", "thirst_rate", "eat_rate", "sate_per_unit", "slake_per_unit", "social_range", "social_push", "follow_gain", "crowd_share", "eat_reach", "bite_seconds", "forage_gain", "eat_threshold", "hoard", "carry_capacity", "head_tau", "head_sigma", "head_max")),
                                  (behaviour, "s.behaviour", ("enabled", "groom_rate", "rear_rate", "rest_rate", "groom_min", "groom_max", "rear_min", "rear_max", "rest_min", "rest_max", "nest_rest_min", "nest_rest_max", "drive_hysteresis", "move_min", "vte_enabled", "junction_open", "scan_min", "scan_max", "scan_cooldown", "scan_hz", "scan_extent")),
                                  (memory, "s.memory", ("enabled", "decay", "disappointment", "usable", "home_drift", "home_sense"))):
        for key in allowed:
            if key in section: assignments.append(f"{prefix}.{key} = {flow_literal(section[key])}")
    neural_fields = (("grid_modules", "s.grid_p.n_modules"), ("grid_spacing", "s.grid_p.base_spacing"),
                     ("grid_spacing_ratio", "s.grid_p.spacing_ratio"), ("grid_orientation", "s.grid_p.base_orientation"),
                     ("grid_peak_rate", "s.grid_p.peak_rate"), ("grid_sharpness", "s.grid_p.sharpness"),
                     ("place_sigma", "s.place_p.sigma"), ("place_peak_rate", "s.place_p.peak_rate"),
                     ("hd_kappa", "s.hd_p.kappa"), ("hd_peak_rate", "s.hd_p.peak_rate"),
                     ("bvc_max_distance", "s.bvc_p.max_distance"), ("bvc_sigma", "s.bvc_p.sigma0"),
                     ("bvc_peak_rate", "s.bvc_p.peak_rate"))
    for key, target in neural_fields:
        if key in neural: assignments.append(f"{target} = {flow_literal(neural[key])}")
    if "can_substeps" in neural: assignments.append(f"s.can_substeps = {flow_literal(neural['can_substeps'])}")
    if "anchor_attractors" in neural: assignments.append(f"s.can_anchor = {flow_literal(neural['anchor_attractors'])}")
    dt = float(sim.get("dt", 1.0 / exp["sample_hz"]))
    steps = max(1, int(round(float(exp["duration_s"]) / dt)))
    preset_id = PRESET_IDS.get(exp.get("flow_preset", exp.get("preset", "open_field")), 0)
    return FLOW_IMPORTS + f'''\nfunction main() -> i32 {{
    let mut s: Sim = sim_create({int(exp["rats"])}, {preset_id}, {int(exp["seed"])} as u32)
    let mut r: Recorder = rec_new()
    {chr(10).join("    " + line for line in assignments)}
    sim_configure_populations(&s)
    sim_reset(&s, {int(exp["rats"])})
    r.stride = {int(plan.get("recording", {}).get("stride", 1))}
    r.max_rats = {int(plan.get("recording", {}).get("max_rats", min(int(exp["rats"]), 16)))}
    r.cell_stride = {int(plan.get("recording", {}).get("cell_stride", 1))}
    if !rec_start(&r, &s) {{ return 2 }}
    for i in 0 to {steps} {{
        sim_step(&s)
        rec_step(&r, &s)
    }}
    rec_stop(&r)
    export_occupancy(&s, "data/out/occupancy.csv", 32)
    export_ratemap(&s, 0, 0, "data/out/ratemap.csv")
    sim_destroy(&s)
    return 0
}}
'''


def run_flow(plan: dict, output_dir: Path) -> dict:
    output_dir.mkdir(parents=True, exist_ok=True)
    source = ROOT / f".flowrat_batch_{os.getpid()}.flow"
    source.write_text(flow_batch_source(plan))
    try:
        env = dict(os.environ); env.setdefault("FLOW_HOST", "python")
        result = subprocess.run([str(Path(env.get("FLOW_HOME", Path.home() / "flow")) / "flow"), "run", str(source)], cwd=ROOT, env=env, text=True, capture_output=True)
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)
        copied = []
        for name in ("trajectory.csv", "neural.csv", "recurrent.csv", "occupancy.csv", "ratemap.csv"):
            candidate = ROOT / "data" / "out" / name
            if candidate.exists():
                target = output_dir / name; shutil.copy2(candidate, target); copied.append(name)
        return {"returncode": result.returncode, "outputs": copied, "stdout_tail": result.stdout[-1000:]}
    finally:
        source.unlink(missing_ok=True)


def movement_metrics(path: Path) -> dict[str, float]:
    by_rat: dict[int, list[dict]] = {}
    with path.open(newline="") as handle:
        for row in csv.DictReader(handle):
            try:
                by_rat.setdefault(int(float(row.get("rat", 0))), []).append(row)
            except (TypeError, ValueError):
                continue
    distances, speeds, turns, durations = [], [], [], []
    occupancy: dict[tuple[int, int], int] = {}
    wall_samples, pause_samples, persistence = 0, 0, []
    all_x = [float(row["x"]) for rows in by_rat.values() for row in rows]
    all_y = [float(row["y"]) for rows in by_rat.values() for row in rows]
    x0, x1 = (min(all_x), max(all_x)) if all_x else (0.0, 1.0)
    y0, y1 = (min(all_y), max(all_y)) if all_y else (0.0, 1.0)
    x_span, y_span = max(x1 - x0, 1e-9), max(y1 - y0, 1e-9)
    for rows in by_rat.values():
        rows.sort(key=lambda r: float(r.get("time", r.get("step", 0))))
        total, local_speeds, local_turns = 0.0, [], []
        prev_heading = None
        for a, b in zip(rows, rows[1:]):
            dx, dy = float(b["x"]) - float(a["x"]), float(b["y"]) - float(a["y"])
            dt = max(1e-9, float(b.get("time", 0)) - float(a.get("time", 0)))
            ax, ay = float(a["x"]), float(a["y"])
            nx, ny = (ax - x0) / x_span, (ay - y0) / y_span
            bin_key = (min(15, int(nx * 16)), min(15, int(ny * 16))); occupancy[bin_key] = occupancy.get(bin_key, 0) + 1
            dist = math.hypot(dx, dy); velocity = dist / dt; total += dist; local_speeds.append(velocity)
            pause_samples += velocity < 0.03
            wall_samples += min(nx, ny, 1.0 - nx, 1.0 - ny) < 0.05
            heading = math.atan2(dy, dx)
            if prev_heading is not None:
                angle = (heading - prev_heading + math.pi) % (2 * math.pi) - math.pi
                local_turns.append(abs(angle) / dt); persistence.append(math.cos(angle))
            prev_heading = heading
        if rows:
            durations.append(float(rows[-1].get("time", 0)) - float(rows[0].get("time", 0)))
        distances += [total]; speeds += local_speeds; turns += local_turns
    total_samples = sum(occupancy.values()) or 1
    occupancy_entropy = -sum((count / total_samples) * math.log(count / total_samples) for count in occupancy.values())
    return {"rats": float(len(by_rat)), "path_length_mean": statistics.fmean(distances) if distances else 0.0,
            "path_length_sd": statistics.pstdev(distances) if len(distances) > 1 else 0.0,
            "speed_mean": statistics.fmean(speeds) if speeds else 0.0,
            "speed_p95": sorted(speeds)[int(.95 * (len(speeds) - 1))] if speeds else 0.0,
            "turn_rate_mean": statistics.fmean(turns) if turns else 0.0,
            "duration_mean": statistics.fmean(durations) if durations else 0.0,
            "occupancy_entropy_16x16": occupancy_entropy,
            "wall_fraction": wall_samples / total_samples,
            "pause_fraction": pause_samples / total_samples,
            "directional_persistence": statistics.fmean(persistence) if persistence else 0.0}


def write_json(data: dict, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2) + "\n")


def command_validate(args: argparse.Namespace) -> int:
    plan = load_plan(Path(args.plan)); errors = validate(plan)
    if errors:
        for error in errors: print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print(json.dumps({"ok": True, "name": plan["experiment"]["name"], "preset": plan["_preset"]}, indent=2)); return 0


def command_generate(args: argparse.Namespace) -> int:
    plan = load_plan(Path(args.plan)); errors = validate(plan)
    if errors: return command_validate(args)
    out = Path(args.output); summary = synthetic(plan, out); write_json({"plan": plan, "summary": summary}, out.with_suffix(".manifest.json")); print(json.dumps(summary, indent=2)); return 0


def command_run(args: argparse.Namespace) -> int:
    plan = load_plan(Path(args.plan)); errors = validate(plan)
    if errors: return command_validate(args)
    result = run_flow(plan, Path(args.output_dir))
    write_json({"plan": plan, "run": result}, Path(args.output_dir) / "flowrat-run.manifest.json")
    print(json.dumps(result, indent=2)); return 0


def command_import(args: argparse.Namespace) -> int:
    summary = import_tracking(Path(args.input), Path(args.output), args.pixels_per_unit, args.frame_rate); print(json.dumps(summary, indent=2)); return 0


def command_analyze(args: argparse.Namespace) -> int:
    metrics = movement_metrics(Path(args.input)); write_json(metrics, Path(args.output)); print(json.dumps(metrics, indent=2)); return 0


def command_compare(args: argparse.Namespace) -> int:
    real, synth = movement_metrics(Path(args.real)), movement_metrics(Path(args.synthetic))
    keys = sorted(set(real) | set(synth)); result = {key: {"real": real.get(key, 0), "synthetic": synth.get(key, 0), "difference": synth.get(key, 0) - real.get(key, 0)} for key in keys}
    write_json(result, Path(args.output)); print(json.dumps(result, indent=2)); return 0


def command_report(args: argparse.Namespace) -> int:
    metrics = json.loads(Path(args.input).read_text())
    lines = [f"# FlowRat movement report\n", f"Source: `{args.input}`\n", "| Feature | Value |", "|---|---:|"]
    for key, value in metrics.items():
        if isinstance(value, (int, float)): lines.append(f"| `{key}` | {value:.6g} |")
    lines += ["", "## Interpretation", "", "These are movement descriptors, not biological validation. Compare them across protocols or against a tracked animal recorded under the same arena and sampling conditions."]
    Path(args.output).write_text("\n".join(lines) + "\n"); print(args.output); return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(required=True)
    p = sub.add_parser("validate"); p.add_argument("plan"); p.set_defaults(func=command_validate)
    p = sub.add_parser("generate"); p.add_argument("plan"); p.add_argument("-o", "--output", required=True); p.set_defaults(func=command_generate)
    p = sub.add_parser("run"); p.add_argument("plan"); p.add_argument("--output-dir", required=True); p.set_defaults(func=command_run)
    p = sub.add_parser("import-tracking"); p.add_argument("input"); p.add_argument("-o", "--output", required=True); p.add_argument("--pixels-per-unit", type=float, default=1.0); p.add_argument("--frame-rate", type=float, default=30.0); p.set_defaults(func=command_import)
    p = sub.add_parser("track-video"); p.add_argument("input"); p.add_argument("-o", "--output", required=True); p.add_argument("--frame-rate", type=float, default=30.0); p.add_argument("--min-area", type=int, default=80); p.add_argument("--max-area", type=int, default=10000); p.set_defaults(func=lambda a: (print(json.dumps(track_video(Path(a.input), Path(a.output), a.frame_rate, a.min_area, a.max_area), indent=2)) or 0))
    p = sub.add_parser("analyze"); p.add_argument("input"); p.add_argument("-o", "--output", required=True); p.set_defaults(func=command_analyze)
    p = sub.add_parser("compare"); p.add_argument("--real", required=True); p.add_argument("--synthetic", required=True); p.add_argument("-o", "--output", required=True); p.set_defaults(func=command_compare)
    p = sub.add_parser("report"); p.add_argument("input"); p.add_argument("-o", "--output", required=True); p.set_defaults(func=command_report)
    args = parser.parse_args(); return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
