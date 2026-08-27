# Architecture

## The shape of a frame

```
input        mouse and keyboard, edge-detected
simulate     steps_per_frame iterations of sim_step
draw         every panel into one RGB framebuffer
present      one blit
```

Simulation and rendering are separate stages with separate profiler slots.
`steps_per_frame` decouples their rates, so the display stays at sixty while
the simulation runs as many steps per frame as asked for.

One `sim_step` is:

1. **motion**, using the sensory cache filled at the end of the previous step
2. **sense**, at the new positions
3. **populations**, from the new positions and the fresh cache
4. **recurrent networks**

Everything a panel displays after a step is therefore the state at one
instant. Only the motion model's input is one step old, which is a fair
description of an animal reacting to what it just saw rather than to where it
already is. Reset primes the cache so the first step is not blind.

---

## Data layout

Every batched quantity is its own allocation. Rat `i` is the `i`-th entry of
every array, and there is no Rat object anywhere in the program:

```flow
struct Agents {
    n: i32,
    cap: i32,
    x: ptr<f64>,
    y: ptr<f64>,
    heading: ptr<f64>,
    speed: ptr<f64>,
    ...
}
```

Three reasons.

**Streaming.** Every kernel walks one or two of these arrays end to end, so
each is a unit-stride read. A motion step touches position, heading, speed
and angular velocity and nothing else; with an array of structs it would pull
the sensory cache and the trail pointers into cache alongside them and use
none of it.

**Cheap to extend.** Adding a field costs nothing to the kernels that do not
read it. The sensory cache grew twice during development without changing a
line of the motion kernel.

**Portable to a device.** Each array maps to one device buffer and each
kernel indexes by global thread id. Nothing holds a pointer into another
rat's data, so there is no pointer chasing to unpick later.

The same reasoning runs through the environment, where walls are four
parallel coordinate arrays, and through the populations, where rates are one
flat array indexed `rat * n + cell`. Rat-major puts a single rat's population
vector contiguously, which is what both the update loop and every panel that
draws one rat want.

### The sensory cache

Wall distance, the wall normal, the ray fan, the nearest visible cue and the
current zone are filled once per step by `agents_sense` and then read by the
motion model, the boundary population and the inspector. A ray fan is the
most expensive thing in a step, and three consumers would otherwise each pay
for it.

---

## Determinism under parallelism

Agent and cell updates run inside `parallel for`. A single mutable generator
state would make the noise stream depend on which thread reached which index
first, so two runs of the same seed would diverge.

Instead every draw is a pure function of `(seed, stream, counter)`:

```flow
rng_u01(seed, STREAM_SPEED + rat, step_index)
```

The mixer is MurmurHash3's finaliser. Index `i` gets the same number whatever
order the loop ran in, and a one-rat run and a thousand-rat run agree on rat
zero. Both properties are checked in `validate.flow`, to the bit.

---

## Modules

| path | holds |
|---|---|
| `src/core/mem.flow` | checked allocation and the memory total |
| `src/core/rng.flow` | counter-based random numbers |
| `src/core/clock.flow` | the monotonic clock |
| `src/core/profile.flow` | fixed-slot profiler |
| `src/env/geometry.flow` | pure plane geometry, safe inside a parallel loop |
| `src/env/environment.flow` | the arena and its editing API |
| `src/env/queries.flow` | containment, wall distance, ray casts, visibility |
| `src/env/presets.flow` | the eight built-in arenas |
| `src/sim/agents.flow` | batched state, the sensory cache, trails |
| `src/sim/integrate.flow` | four integrators over the kinematics |
| `src/sim/behaviour.flow` | the state machine, bouts and the ethogram |
| `src/sim/memory.flow` | where food was, and the way home by dead reckoning |
| `src/sim/spatial.flow` | the uniform grid, so a rat can find its neighbours |
| `src/sim/novelty.flow` | the coarse map of where a rat has already been |
| `src/sim/motion.flow` | how each state moves, and wall handling |
| `src/sim/simulation.flow` | the owned simulation and run control |
| `src/neural/population.flow` | the framework every population shares |
| `src/neural/*.flow` | place, head direction, velocity, grid, boundary |
| `src/neural/attractor.flow` | the continuous attractor network |
| `src/neural/circuit.flow` | place fields built from boundary and grid input |
| `src/analysis/ratemap.flow` | spikes and occupancy binned over the arena |
| `src/analysis/scores.flow` | information, fields, gridness, circular tuning |
| `src/analysis/session.flow` | a recording, and the CSV of everything in it |
| `src/ui/draw.flow` | framebuffer primitives and text |
| `src/ui/widgets.flow` | theme and immediate-mode controls |
| `src/ui/layout.flow` | panel rectangles and the world transform |
| `src/ui/view_*.flow` | the panels, one tab each in row two |
| `src/io/record.flow` | CSV recording and exports |
| `src/io/config.flow` | saving and loading a whole setup |

### The import rule

Flow resolves an import relative to the importing file and rejects `..` as an
unsafe path. A module in `src/neural` therefore cannot name one in `src/env`.

Modules import only their siblings. Cross-directory dependencies are
satisfied by the entry point's import list, which names every module in
dependency order; Flow merges them into one namespace, so the call resolves.
Where a module uses a symbol it cannot import, a comment at the top says
where the symbol comes from.

The consequence for the layout is that entry points live at the repository
root. `flowrat.flow`, `validate.flow`, `bench.flow` and `mkconfig.flow` are
the only Flow files there, and each begins with the same import block.

### Constructors, not literals

A struct literal for a type declared in another module does not parse. Every
exported struct therefore has a constructor in its defining module, and
nothing outside that module writes `Thing { ... }`. Mutation through
`ptr<Thing>` works across modules normally, so this costs one function per
type and nothing else.

---

## The environment

The arena boundary lives in the same arrays as the internal walls, in the
first `n_boundary` slots. One loop answers "distance to any wall" without
special-casing the boundary, and a circular arena is sixty-four short
segments rather than a second code path. Containment still uses the analytic
shape, where a rectangle is two comparisons.

Obstacles are recorded twice: as four segments, which is what wall distance
and ray casting need, and as one entry in a list of solid rectangles, which
is what containment needs. A free-standing barrier gets segments only, so it
blocks movement and sight without enclosing anything. Parity tests over loose
segments cannot make that distinction, which is why the solids list exists.

`env_remove_wall` refuses to delete a boundary segment. Deleting one would
open the arena and let rats leave through the gap.

---

## Walls are enforced twice

Turning away from a wall is a soft term in the motion model and can fail. The
hard guarantee is applied after integration: any rat that ended up outside
free space is pushed back to the nearest legal point and its heading is
reflected off the wall it crossed, and it loses half its forward speed on
impact.

Without that, a fast rat at a large timestep tunnels out of the arena, and
every spatial population downstream reads positions that do not exist. The
validation suite runs sixty-four rats for nine hundred steps in all eight
arenas and requires that none of them leave.

---

## The continuous attractor network

The dynamics are

```
tau dr/dt = -r + phi(W r + I)
```

integrated by explicit Euler into a second buffer, so every cell sees the
same pre-step state and the result cannot depend on visit order.

### Connectivity

`W` is never stored. A dense `W` for a 64 by 64 sheet is 4096 by 4096
doubles, 134 MB, and 16.7 million multiply-adds per step. On a torus it is
also entirely redundant: the weight between two cells depends only on the
vector between them.

The excitatory half is a Gaussian kernel over that vector, evaluated once at
build time. The inhibitory half is uniform, and a uniform term needs no
kernel at all: subtracting `w_global` times the mean rate is one reduction
per step and is exact.

That split matters for more than speed. The first version put both halves
into the local kernel as a difference of Gaussians, and the broad inhibitory
Gaussian was cut off by the kernel radius. The truncated surround left the
lattice modes unstable, the sheet filled with ripple instead of a bump, and
no amount of gain tuning fixed it.

### Stability is computed, not tuned

With a rectifying nonlinearity the dynamics are linear wherever activity is
positive, so the spectrum of the recurrent operator decides everything. Above
one, activity grows without bound; the first working version reached 1e61 in
two hundred steps. Below one, any bump decays and the network forgets.

A translation-invariant kernel on a torus makes the operator circulant, and
the eigenvalues of a circulant matrix are exactly the discrete Fourier
transform of its kernel. `can_normalise_kernel` computes that transform and
scales the kernel so the largest non-uniform eigenvalue lands on
`gain_target`. `w_global` is then solved for so the uniform eigenvalue lands
on `dc_gain`. Neither number is fitted.

### Velocity is calibrated, not derived

How fast the bump moves for a given drive depends on the kernel width, the
gain, the time constant and the nonlinearity, all of which the control panel
can change. Rather than derive that relationship and get it wrong,
`can_calibrate_sheet` measures it: drive the network at a known rate, see how
far the bump actually travelled after a warm-up, and scale the gain by the
ratio. Path integration is then metrically correct by construction, and a
drift in the decoded position is the network's own rather than a units error.

### Two regimes

`sigma_excite` decides how many bumps fit. Wide enough and only the lowest
spatial frequency is unstable, giving one bump whose position codes the rat's
position. Narrow it and higher frequencies go unstable too, the sheet breaks
into a lattice, and the network is in the grid-cell regime. Both are reachable
from the control panel, and `lambda 2nd` in the attractor panel says which one
the network is in.

The regime also decides what the structured connectivity buys. A single-bump
sheet needs sigma near a fifth of its width, so its kernel covers most of the
sheet and the saving is memory rather than arithmetic. In the lattice regime
the kernel is genuinely local and the arithmetic saving arrives as well. Both
are measured in [validation.md](validation.md).

### The inner loop

The obvious gather reads, per tap, a wrapped source index and that source's
preferred direction. Written directly that is a modulo for the wrap and,
inside the direction lookup, a divide and two more modulos: three integer
divisions per multiply-add on the innermost loop of the program. Measured
against the dense matrix it was *slower*, despite doing a fifth of the
arithmetic.

Two observations remove all of it, in `can_build_tables`:

- The wrapped index depends only on the target's row or column and the tap
  offset, so the whole table is built once.
- A source cell's preferred direction depends only on the parity of its row
  and column, and the source's parity is the target's parity flipped by the
  tap offset's parity. So the four direction kernels merge into four parity
  kernels: the loop picks one by the target's parity and reads it straight
  through.

What is left in the inner loop is two table loads and a multiply-add. The
change made the structured path 1.5 times faster at 32 by 32 and did not move
its output by more than 2e-14 against the dense reference.

---

## The circuit

With `circuit.enabled` off, every population reads the rat's state directly
and feeds nothing else. That is five encoders in parallel, and a diagram of
it would be a diagram of connections that do not exist.

With it on, a place cell has no access to position at all:

```
drive_c = sum over its inputs of w * r_source
rate_c  = gain_c * max(0, drive_c - theta_c)
```

Inputs come from the boundary and grid populations only. Each place cell is
connected to the `fan_in` input cells that respond most strongly at its own
centre, with weights proportional to those responses and normalised to sum to
one. Threshold and gain are then solved per cell so the drive at that centre
lands on the configured peak rate, which keeps a cell in a corner, whose
inputs are weaker, as loud as one in the middle.

That is the Barry and Burgess account of a place field as a thresholded sum
of boundary-vector inputs, with grid cells added to the pool.

**Why it is worth having.** An analytic place cell is a Gaussian pinned to a
point in the room, and moving a wall does not affect it. This one is pinned
to a set of boundary relationships, so moving a wall moves the field. It also
makes the connectome view honest: the edges it draws are the ones the update
reads.

**What it costs.** The decode is less precise, 0.22 m mean error against
0.04 m for the analytic fields. Most of that is duplicate fields: in a
symmetric room two different places present the same arrangement of walls, so
a boundary-driven cell fires in both and the population vector is pulled
between them. Measured, not assumed; the numbers are in
[validation.md](validation.md).

**Ordering.** `sim_step` runs place last, after boundary and grid, because in
circuit mode it reads the rates those produced this step. The analytic path
does not care about the order, and having one order rather than two is worth
more than the nothing it costs.

**Rewiring.** The connections are built from the arena's geometry, so an
environment edit invalidates them. `sim_env_changed` rewires, which is the
mechanism behind a wall moving a field.

---

## Rendering

The gfx backend offers a clear, a filled rectangle and a raw RGB blit. A
cockpit needs lines, discs, heat maps, alpha and per-panel clipping, and
building those out of one `fill_rect` call per pixel means a backend call per
pixel. The heat maps alone are a hundred thousand pixels a frame.

So the whole window is one buffer FlowRat owns, every primitive is a write
into it, and the frame reaches the screen as a single blit. Text is drawn the
same way, reading glyph bits from `stdlib/font.flow`, which keeps everything
in one pass; drawing text through the backend would force a second pass after
the blit and split every panel's code in two.

Owning the text renderer also allowed one fix worth naming. In that font,
lowercase `p` is uppercase `P` shifted down one row and nothing else, so at
scale 1 the two are indistinguishable and "population" renders as
"PoPulation". `dr_char` drops the five descender glyphs one more pixel, which
gives the descender somewhere to go below the baseline and separates the
pairs.

The bottom row is a single tabbed area rather than four narrow panels. One
panel at a time gets the full width, which is what makes room for a readable
network diagram and stops the inspector and the profiler from each being a
column too narrow for a label and its number. The per-panel rectangles in
`Layout` are all the same rectangle, so the panels were written against their
own names and did not have to change when the tabs arrived.

The window is resizable and can go full screen. Every frame the application
compares the window's size against its framebuffer and, when they differ,
rebuilds the framebuffer, the canvas and the layout before drawing. Sizes are
in points rather than backing pixels: on a retina display the backing is
twice the points, and laying out to the backing would draw text at half its
intended physical size.

Widgets are immediate mode and hold no state of their own. A slider writes
straight through a pointer into the parameter struct it is editing, so there
is never a copy of a parameter in the interface that can drift from the
simulation's copy. The retained state is which control the mouse captured
on press, without which dragging a slider past another one would hand the
drag over, and the position and time of the last press, which is what turns
a second press into a double click. A double click restores a default
everywhere: on a slider the value the model was built with, on empty floor
in the arena view a refit.

Defaults are captured once at startup from the same `*_params_default`
functions the simulation is built from, rather than written out again as
literals in the interface. A default that lives in two places is a default
that will eventually disagree with itself.

---

## Food is a shared resource, so feeding is serial

Motion runs `parallel for` over rats. A food patch is one number that several
rats may be removing from at once, and doing that inside the parallel pass
would be a race on it: the batch would stop being reproducible, and two runs
of one seed would disagree about who ate what.

So the parallel pass decides only what each rat *wants*, writing it to its
own slot, and a serial pass afterwards hands out what the patches actually
hold, in rat order. That is race-free, deterministic, and models the
competition correctly: when a patch runs low, whoever comes first in the
batch gets the last of it. The tie-break is arbitrary but it is stated, and
the alternative is a tie-break that changes with the thread schedule.

The same pattern applies to anything else shared that gets added later.

---

## Failing loudly

Three rules, each of which exists because the opposite happened.

**An allocation that fails stops the program**, naming the buffer, rather
than returning a null pointer that is written to immediately. A simulator
that cannot allocate its state has nothing to degrade to, and a crash at an
unrelated address says nothing about what ran out.

**A file that is not intact is not applied.** Configurations carry a trailer
holding their own length, so truncation is detected before any of the file
has been read into the simulation. Half a configuration is worse than none:
the arena would come from one run and the parameters from another.

**A value that stops being a number is caught where it appears.** The
Ornstein-Uhlenbeck relaxation times are floored rather than trusted, the
recurrent substep count is derived from `dt / tau` rather than set, and a rat
whose state is not finite after a step is returned to where it started rather
than carrying the value into every population that reads its position. What
survives all that is reported by `sim_health`, which the performance tab
prints as a `state` line.

---

## Food is objects, not an amount

A patch used to hold a number. `zone_amount` went down as rats ate and the
pellets drawn inside it were decoration, regenerated from a seed each frame,
so the picture did not change when the number did. You could watch a rat feed
for ten seconds and see the same pellets in the same places throughout.
Nothing an animal did to the world was legible from looking at it.

Items are now the unit. `Env` carries four parallel arrays of position, patch
and kind; `zone_amount` is derived, holding however many live items belong to
that patch; and a mouthful takes exactly one item, the one nearest the rat's
nose. Regrowth banks a fraction per patch and spawns a whole item when it is
owed one, because a patch growing at 1.6 a second cannot deliver 0.027 of a
pellet per step.

Two consequences worth knowing about. Crowding stopped being a smaller
mouthful and became a longer one, which is what jostling actually costs. And
`env_remove_zone` swaps the last patch into the hole it leaves, so it now has
to delete that patch's items and renumber the moved patch's: without both, the
arena keeps pellets that belong to nothing, or worse, pellets that are eaten
out of a patch that never grew them.

## The analysis is not part of the model

`src/analysis/` imports the simulation and nothing in the simulation imports
it. That direction is deliberate and worth keeping.

Every other module in FlowRat can only be checked against itself: a place cell
fires a Gaussian because the code evaluates a Gaussian, and a test that reads
the rate back proves the arithmetic and nothing more. The analysis is written
without reference to the parameters, from binned spikes and occupancy, so when
its answer matches the configuration that produced it, two independent pieces
of code agreed. If the analysis were allowed to consult the model, that
agreement would evaporate into a tautology, and it would do so silently.

The same reason is why it counts spikes rather than reading rates. Binning a
rate and dividing by occupancy returns a smoothed copy of the rate. Putting a
sampling process in between means the measurement can disagree, which is what
makes agreement worth anything.

## The browser

`flow wasm` compiles the same source through C to WebAssembly and gives it a
canvas, so the whole interface runs in a tab: same arena, same panels, same
tabs. `tools/wasm.sh` builds and serves it.

The batch is single-threaded there. `parallel for` wants pthreads over
SharedArrayBuffer, which needs the cross-origin isolation headers, so the
browser build takes the serial path. At 1440 by 900 with the default two dozen
rats that is about 14 ms a frame against 4.6 native, which is the cost of
losing the threads rather than of the compile.

## The GPU path

Nothing here runs on a GPU today. Flow can emit Metal for data-parallel
kernels, and the code is shaped so that a port is mechanical rather than a
rewrite, but that port has not been done and the CPU path is what is
measured.

What is already in the right shape:

- **Every batched array is one contiguous allocation** that maps to one
  device buffer.
- **The per-agent kernels** (`motion_step_one`, `agents_sense`) read and
  write only their own index plus a read-only environment.
- **The population updates** are all `parallel for` over rats with an inner
  loop over cells, no cross-agent dependencies.
- **The recurrent step** is a local gather into a separate buffer, one thread
  per cell, which is the canonical stencil shape.

What would need work:

- The environment would have to be uploaded as flat arrays and re-uploaded on
  every edit. That is cheap at these sizes and is the obvious first thing to
  get wrong.
- `can_mean` is a reduction and would need a device-side one rather than the
  serial sweep it is now.
- The framebuffer would either stay on the host, which means reading rates
  back every frame, or the panels would have to be drawn on the device too.
  Reading back one population vector per frame is far cheaper than reading
  back everything, and the panels only ever draw the selected rat.

The kernels worth moving first, in order of arithmetic per byte transferred:
the recurrent step, then the boundary population, then the ray fan.
