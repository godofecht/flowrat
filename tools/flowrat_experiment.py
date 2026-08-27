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
import random
import statistics
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PRESET_DIR = ROOT / "experiments" / "presets"
DEFAULT_OUT = ROOT / "data" / "out" / "experiments"

PRESET_DEFAULTS = {
    "open_field": {"arena": {"width": 2.0, "height": 2.0, "goal_x": 1.0, "goal_y": 1.0}, "policy": "explore"},
    "t_maze": {"arena": {"width": 2.0, "height": 1.4, "goal_x": 1.0, "goal_y": 1.2}, "policy": "choice"},
    "obstacle_navigation": {"arena": {"width": 2.0, "height": 2.0, "goal_x": 1.8, "goal_y": 1.8}, "policy": "avoid"},
    "homing": {"arena": {"width": 2.0, "height": 2.0, "goal_x": 0.3, "goal_y": 0.3}, "policy": "home"},
    "cue_remapping": {"arena": {"width": 2.0, "height": 2.0, "goal_x": 1.7, "goal_y": 1.7}, "policy": "remap"},
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


def movement_metrics(path: Path) -> dict[str, float]:
    by_rat: dict[int, list[dict]] = {}
    with path.open(newline="") as handle:
        for row in csv.DictReader(handle):
            try:
                by_rat.setdefault(int(float(row.get("rat", 0))), []).append(row)
            except (TypeError, ValueError):
                continue
    distances, speeds, turns, durations = [], [], [], []
    for rows in by_rat.values():
        rows.sort(key=lambda r: float(r.get("time", r.get("step", 0))))
        total, local_speeds, local_turns = 0.0, [], []
        prev_heading = None
        for a, b in zip(rows, rows[1:]):
            dx, dy = float(b["x"]) - float(a["x"]), float(b["y"]) - float(a["y"])
            dt = max(1e-9, float(b.get("time", 0)) - float(a.get("time", 0)))
            dist = math.hypot(dx, dy); total += dist; local_speeds.append(dist / dt)
            heading = math.atan2(dy, dx)
            if prev_heading is not None:
                local_turns.append(abs((heading - prev_heading + math.pi) % (2 * math.pi) - math.pi) / dt)
            prev_heading = heading
        if rows:
            durations.append(float(rows[-1].get("time", 0)) - float(rows[0].get("time", 0)))
        distances += [total]; speeds += local_speeds; turns += local_turns
    return {"rats": float(len(by_rat)), "path_length_mean": statistics.fmean(distances) if distances else 0.0,
            "path_length_sd": statistics.pstdev(distances) if len(distances) > 1 else 0.0,
            "speed_mean": statistics.fmean(speeds) if speeds else 0.0,
            "speed_p95": sorted(speeds)[int(.95 * (len(speeds) - 1))] if speeds else 0.0,
            "turn_rate_mean": statistics.fmean(turns) if turns else 0.0,
            "duration_mean": statistics.fmean(durations) if durations else 0.0}


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


def command_import(args: argparse.Namespace) -> int:
    summary = import_tracking(Path(args.input), Path(args.output), args.pixels_per_unit, args.frame_rate); print(json.dumps(summary, indent=2)); return 0


def command_analyze(args: argparse.Namespace) -> int:
    metrics = movement_metrics(Path(args.input)); write_json(metrics, Path(args.output)); print(json.dumps(metrics, indent=2)); return 0


def command_compare(args: argparse.Namespace) -> int:
    real, synth = movement_metrics(Path(args.real)), movement_metrics(Path(args.synthetic))
    keys = sorted(set(real) | set(synth)); result = {key: {"real": real.get(key, 0), "synthetic": synth.get(key, 0), "difference": synth.get(key, 0) - real.get(key, 0)} for key in keys}
    write_json(result, Path(args.output)); print(json.dumps(result, indent=2)); return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(required=True)
    p = sub.add_parser("validate"); p.add_argument("plan"); p.set_defaults(func=command_validate)
    p = sub.add_parser("generate"); p.add_argument("plan"); p.add_argument("-o", "--output", required=True); p.set_defaults(func=command_generate)
    p = sub.add_parser("import-tracking"); p.add_argument("input"); p.add_argument("-o", "--output", required=True); p.add_argument("--pixels-per-unit", type=float, default=1.0); p.add_argument("--frame-rate", type=float, default=30.0); p.set_defaults(func=command_import)
    p = sub.add_parser("analyze"); p.add_argument("input"); p.add_argument("-o", "--output", required=True); p.set_defaults(func=command_analyze)
    p = sub.add_parser("compare"); p.add_argument("--real", required=True); p.add_argument("--synthetic", required=True); p.add_argument("-o", "--output", required=True); p.set_defaults(func=command_compare)
    args = parser.parse_args(); return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
