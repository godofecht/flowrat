# Extending FlowRat

Three things are meant to be added often: arenas, neural populations, and
panels. Each has one place to touch and a short list of what else notices.

Before starting, two Flow constraints shape everything here:

- **Imports resolve relative to the importing file and `..` is rejected.**
  Modules import only their siblings. A cross-directory dependency is
  satisfied by the entry point's import list, and there are four entry points
  to keep in step: `flowrat.flow`, `validate.flow`, `bench.flow` and
  `mkconfig.flow`.
- **A struct literal for a type from another module does not parse.** Every
  exported struct needs a constructor in its defining module. Mutation
  through `ptr<T>` works across modules normally.

---

## A new arena

Everything a preset does, the mouse can also do, because presets call the
same editing API. There is no separate preset format.

Write the builder in `src/env/presets.flow`:

```flow
export function preset_ring_track(e: ptr<Env>) -> void {
    env_set_circle(e, 1.0, 1.0, 1.0)
    # An inner wall makes it an annulus. A ring of segments rather than a
    # box, so it has no corners for a rat to get stuck in.
    let step: f64 = TAU / 48.0
    for i in 0 to 48 {
        let a0: f64 = (i as f64) * step
        let a1: f64 = ((i + 1) as f64) * step
        let idx: i32 = env_add_wall(e,
            1.0 + 0.45 * cos(a0), 1.0 + 0.45 * sin(a0),
            1.0 + 0.45 * cos(a1), 1.0 + 0.45 * sin(a1))
    }
    # The inner disc is solid, so nothing is placed or spawned inside it.
    env_add_solid(e, 0.55, 0.55, 0.9, 0.9)
    let c: i32 = env_add_cue(e, 1.0, 1.9, 1.0)
    let s: i32 = env_add_zone(e, ZONE_START, SHAPE_CIRCLE, 1.0, 0.28, 0.1, 0.0)
    e.preset = PRESET_RING_TRACK
}
```

Then:

1. Add `PRESET_RING_TRACK` and bump `PRESET_COUNT`.
2. Add a branch to `env_preset_apply` and a name to `env_preset_name`.
3. Add a short label to `preset_short` in `src/ui/view_sys.flow`, which is
   what the buttons show.

That is all. The preset buttons, the number keys, the validation sweep over
every arena and the benchmark's query table all iterate to `PRESET_COUNT`.

### What an arena has to satisfy

`validate.flow` will hold the new one to the same bar as the rest:

- **Closed.** Sixty-four rays from a point in free space must all hit
  something. A gap in the shell leaks rats.
- **Sampleable.** `env_sample_free` must find free space within sixty-four
  rejection tries, or place fields and spawn points fall back to the centre.
- **Solid regions declared.** Anything a rat should not stand inside needs an
  `env_add_solid` record as well as its segments. Segments alone stop
  movement and sight but do not stop containment, sampling or spawning.

### A genuinely new arena shape

If the outer boundary is neither a rectangle nor a circle, set
`e.kind = ENV_POLY`, build the shell out of segments, and call
`env_seal_boundary` to freeze them as undeletable. Then add a branch to
`env_in_shell` in `src/env/queries.flow`, which is the only place the shell's
shape is used analytically. Everything else already works from the segments.

---

## A new population

A population is N cells whose rates are a function of the batched rat state.
The framework in `src/neural/population.flow` gives every one of them the
same shape: a rate array laid out `rat * n + cell`, five per-cell property
arrays whose meaning the population chooses, optional Poisson spikes, and an
optional history ring.

Five untyped property arrays is a deliberate trade. Giving each type its own
struct would mean a separate allocation path, a separate serialiser and a
separate inspector for each; this way adding a population is a configure
function and an update function. The cost is that the arrays are not
self-describing, which `pop_prop_name` repays.

Write `src/neural/my_cells.flow`:

```flow
# Whatever the cells encode, and what each property array holds.
#
#   p0  preferred something
#   p1  tuning width
#   p2  peak rate
#   p3  unused
#   p4  unused

extern { function exp(x: f64) -> f64 }

export struct MyParams {
    width: f64,
    peak_rate: f64,
}

export function my_params_default() -> MyParams {
    return MyParams { width: 0.2, peak_rate: 18.0 }
}

export function my_configure(p: ptr<Pop>, mp: ptr<MyParams>,
                             seed: u32) -> void {
    for c in 0 to p.n {
        p.p0[c] = ...
        p.p1[c] = mp.width
        p.p2[c] = mp.peak_rate
    }
    p.revision = p.revision + 1
}

# Rate at an arbitrary state, used by the update, by any tuning preview, and
# by the validation check. Having one is what lets a test assert the tuning
# rather than assert the update against itself.
export function my_rate_at(p: ptr<Pop>, cell: i32, x: f64) -> f64 {
    ...
}

export function my_update(p: ptr<Pop>, a: ptr<Agents>,
                          mp: ptr<MyParams>) -> void {
    if !p.enabled { return }
    parallel for r in 0 to a.n {
        let base: i32 = r * p.n
        for c in 0 to p.n {
            p.rates[base + c] = ...
        }
    }
}
```

The update must be parallel over rats with rat `r` writing only its own slice
and reading only its own state plus read-only shared data. That is what makes
`parallel for` legal here, and it is the property to preserve.

Then in `src/sim/simulation.flow`:

1. Add `POP_MY_CELLS` in `population.flow` and bump `POP_KINDS`, and add
   entries to `pop_kind_name`, `pop_short_name` and `pop_prop_name`.
2. Add `my: Pop` and `my_p: MyParams` to `Sim`, create them in `sim_create`,
   destroy them in `sim_destroy`.
3. Call `my_configure` from `sim_configure_populations`.
4. Call `my_update` from `sim_step`, wrapped in a profiler slot.
5. Add a slot in `src/core/profile.flow` and bump `PROF_SLOTS`.
6. Bump `SIM_POP_COUNT` and add branches to `sim_pop` and `sim_pop_slot`.
7. Add the import line to all four entry points.

The population panel, the enable toggles, the raster, the recorder and the
configuration file all iterate over `SIM_POP_COUNT` and need nothing further.

### What to check

The pattern the existing checks follow is to assert the tuning analytically
and the decode empirically:

```flow
# The shape of the tuning curve, against the closed form it was written from.
let at_peak: f64 = my_rate_at(&s.my, 0, s.my.p0[0])
check(fabs(at_peak - s.my.p2[0]) < 0.0001, ...)

# And that the population as a whole recovers what it encodes.
for k in 0 to 600 { sim_step(&s) }
check(worst_decode_error < tolerance, ...)
```

`bench_population` in `bench.flow` takes the population index and sweeps rats
against cells, so a new population joins the scaling table with one call.

---

## A new panel

Panels draw into the shared `Canvas` and read the simulation through
`Sim`. They hold no state; anything a panel needs to remember lives in
`Editor`, which is the interface's state despite the name.

1. Add the rectangle to `Layout` in `src/ui/layout.flow` and compute it in
   `layout_build`. Every panel's position is computed once per frame and both
   drawing and hit testing read from it, so a control can never be drawn in
   one place and be clickable in another. A panel that belongs in row two
   needs no rectangle of its own: the tabbed panels all share one, and adding
   `net_x` and friends alongside the existing names is enough.
2. Write `view_thing_draw(c, u, s, ed, lay)` in a `src/ui/view_*.flow`.
   Start with `ui_panel` for the frame and title, then `canvas_clip` if
   anything might overrun. Use fixed-width columns rather than one stretched
   to the panel: row two is full width, and a key-value row spanning fourteen
   hundred pixels puts the label and its number a hand's width apart.
3. For a tabbed panel, add a `TAB_` constant, bump `TAB_COUNT`, and add its
   name to `tab_name`.
4. Call it from `flowrat.flow`, and from `test_ui` in `validate.flow` and
   `draw_all` in `bench.flow`.

Draw order matters for input. Panels that own controls are drawn before the
environment view, so a click landing on a control sets `u.consumed` and the
view underneath does not also act on it.

### Widgets

```flow
if ui_button(u, c, x, y, w, 16, "label") { ... }
if ui_toggle(u, c, x, y, w, 16, "label", flag) { flag = !flag }
if ui_slider(u, c, x, y, w, 14, "label", &params.value, lo, hi, def, 2) {
    # returns true only when the value actually changed, so this is where
    # anything derived from it gets rebuilt
}
if ui_slider_int(u, c, x, y, w, 14, "label", &n, lo, hi, def) { ... }
if ui_slider_exp(u, c, x, y, w, 14, "label", &n, 1, 4096, def) { ... }
if ui_tab(u, c, x, y, w, h, "label", active) { ... }
```

Every slider takes a default. Double clicking it restores that value, and a
notch is drawn on the track where it sits. Pass the default from the
`Defaults` record rather than writing the number out again: `Defaults` is
built once at startup from the same `*_params_default` functions the
simulation is built from, so a default cannot drift from the model.

Sliders write through a pointer into the parameter struct, so there is never
a copy of a parameter in the interface that can drift from the simulation's.
The return value is the hook for rebuilding: changing a kernel width has to
rebuild the kernel and recalibrate, and that belongs inside the `if`.

For plots, `ui_bars` draws a population vector against a fixed ceiling and
`ui_sparkline` draws a series. Bars are scaled against a configured maximum
rather than a running one, because an autoscaling axis makes a silent
population look busy.

---

## A new recorded quantity

`src/io/record.flow` writes through one `fprintf` declared with eight `f64`
arguments, against format strings that consume exactly eight, with integers
going through as `%.0f`. One declaration and one call shape means a format
and an argument list cannot drift apart. Add a column by extending the header
in `rec_start` and the matching format in `rec_step`.

Adding a field to a saved configuration means adding one `put` in
`config_save` and one `get` in the same position in `config_load`, and
bumping `CONFIG_VERSION`. The two functions are the same sequence of calls in
the same order, which is what keeps them in step; a file whose version is
outside the accepted range is refused rather than half applied.

---

## A new behaviour

Behaviours live in `src/sim/behaviour.flow` as states in one machine, and the
order of the checks inside `behaviour_tick` is the priority order. A new state
needs a constant, a name in `state_name` and a short one in `state_short`, an
entry in `state_is_still` if it does not move, a colour in `state_colour`, and
an entry condition placed where its urgency belongs.

Two things about that file are easy to get wrong.

The maintenance roll is charged for the whole interval since the last one,
not for one step. Any state that carries a timer stops the machine reaching
the roll while it runs, so a per-step probability there is silently divided by
however much of the run the colony spends in timed states. That was a real bug
and it moved the time budget every time a behaviour was added; the fix and its
consequences are in [validation.md](validation.md).

Anything that mutates state shared between rats has to happen in a serial pass
after the parallel one. `sim_feed` and `ethogram_fold` are the pattern. The
parallel pass may read shared state freely, provided nothing in the same pass
writes it: the spatial grid keeps its own copy of the positions for exactly
this reason.

## A new drive

`hunger` and `thirst` are the two, and they compete in `choose_drive`. A third
means: a column in `Agents`, a rate in `MotionParams`, a zone kind that
`zone_is_consumable` accepts, a branch in `choose_drive` with a margin so the
animal does not oscillate at the crossover, a consuming state, and a case in
`sim_feed`.

Set the rate against how long it takes to cross the arena rather than in the
abstract. A drive that saturates faster than the animal can walk to what
satisfies it leaves no leisure at all, and the symptom appears in the time
budget rather than anywhere near the drive.

## A new measurement

`src/analysis/` imports the simulation and nothing in the simulation imports
it. Keep it that way. A score that consults the model's parameters is a score
that cannot disagree with them, and the value of everything in that directory
is that it can.

A new score takes a finished `RateMap` and returns a number. Skip bins where
`ratemap_visited` is false: a bin the animal never entered has no rate, and
treating it as silence inflates every concentration measure there is. Add the
score to `analysis_export` in the same place in both the header and the row.
