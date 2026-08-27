# Validation and benchmarks

```bash
./validate.sh     # functional checks
./bench.sh        # performance
```

Both run headless. `validate.sh` returns 0 when everything passes and a
distinct non-zero code per failing check, so a script can tell which one
broke without parsing the output. It takes several minutes: the measurement
section alone runs five recordings of a thousand simulated seconds each,
because a rate map from a short run is not a rate map. Every check prints what it measured, not
just whether it passed, because a number drifting toward its tolerance is
worth seeing before it crosses.

---

## What is checked

190 checks. They compare the model against something independent: an
integrator against its own closed-form solution, the structured connectivity
against a dense matrix, the spatial grid against a brute-force sweep, a
decoded position against the position it was decoded from. A check that only
compares the code to itself would pass forever.

The strongest of them are in *Measuring the run rather than the model*, at the
end. Everything else establishes that the code does what it says; those
establish that what it says resembles a rat, by measuring a recording the way
an experiment would and getting back the parameters the model was built with.

### Geometry

Ray against a segment at a known range, and misses for a ray pointing away
and a ray parallel to it. Point-to-segment distance with the foot of the
perpendicular inside the segment and outside it. Angle wrapping at the seam.

### Environment

Every one of the eight presets is a closed arena: sixty-four rays from a
point in free space all hit something. Four thousand rejection samples all
land in free space. A point inside a pillar is pushed out of it. Wall
distance in a plain box matches the analytic answer to 1e-6. A barrier blocks
line of sight and removing it restores it. Boundary segments refuse deletion.

### Integrators

One step of a hard turn, against the closed-form arc:

```
one step at dt=0.020, v=0.30, omega=2.00
euler 1.200e-04   semi 1.200e-04   rk4 5.333e-12
euler error ratio on halving dt: 4.000 (expect ~4)
```

Semi-implicit beats Euler, RK4 beats both by eight orders of magnitude, and
Euler's error falls by exactly four when the step is halved, which is the
second-order convergence its derivation promises.

### Motion

Sixty-four rats for nine hundred steps in every arena, requiring that none
leave free space and that they actually move:

```
open field     escaped  0 / 64, mean path 2.4225 m, near wall  0
circle         escaped  0 / 64, mean path 2.4218 m, near wall  0
two rooms      escaped  0 / 64, mean path 2.4225 m, near wall  0
four rooms     escaped  0 / 64, mean path 2.4225 m, near wall  0
t maze         escaped  0 / 64, mean path 2.4213 m, near wall  1
linear track   escaped  0 / 64, mean path 2.4163 m, near wall  0
obstacles      escaped  0 / 64, mean path 2.4225 m, near wall  1
plus maze      escaped  0 / 64, mean path 2.4215 m, near wall  0
```

The path lengths are close because collisions are rare: the wall-avoidance
term turns the rat away before it arrives, and only a collision costs speed.
The narrower arenas are measurably shorter, which is the collisions showing
up.

### Determinism

```
128 rats, 400 steps, largest divergence: 0.000e+00 m
rat 0 in a batch of 128 vs alone:       0.000e+00 m
different seed moves rat 0 by:          0.062 m
```

Two runs of one seed are identical to the bit, under `parallel for` with
fourteen threads. Rat zero's path does not depend on how many rats ran
alongside it, which is the property that would break first if the noise
stream were indexed by anything other than the rat.

### Populations

```
place cell 0: peak 20.000, one sigma out 12.131, ratio 0.6065
hd cell 3: at preferred 25.000, opposite 0.00839
over 600 steps, worst place decode error 0.0594 m
over 600 steps, worst head decode error 0.0000 rad
grid cell 0 at r: 2.9039
one lattice vector along: 2.9039, next vector: 2.9039
half a lattice vector along: 0.6510
boundary peak: arena centre 0.002, against a wall 14.142
```

A place field falls to exp(-1/2) of its peak at one sigma, to four decimal
places. No field centre lands in a wall. A grid field repeats on both lattice
vectors and does not repeat at half of one.

The lattice check is worth a note. The lattice translation vectors are not
along the three wave vectors; they sit thirty degrees off them. With wave
vectors at theta, theta+60 and theta+120, a shift of one spacing along
theta+30 gives phases of 2pi, 2pi and 0, so every term returns to where it
started. The first version of this check shifted along theta and failed, and
the code was right.

### Recurrent networks

```
sheet: lambda_bump 1.900, lambda_2nd 0.902, w_global 4.800
after settling: peak 1.515, mean 0.334, strength 0.592
structured vs dense over 40 steps: max diff 1.885e-14
driven at 3.0 cells/s for 4.0 s: moved 11.87, want 12.00
ring: lambda_2nd 0.032, strength 0.717
ring driven at 1.0 rad/s: turned 3.972, want 4.000
```

The structured kernel and the dense matrix agree to 2e-14 over forty steps,
which is accumulated floating-point noise and nothing else. Both networks
track their drive to within one per cent.

### Place cells driven by their inputs

```
mean inputs per cell over 16 cells: 16.0 of 16
worst field offset from its wiring centre: 0.059 m
worst peak rate error against the configured peak: 26.4%
a wall beside cell 0: field moved 0.000 m, peak 20.4 -> 22.2
```

With the circuit on, a place cell has no access to position, so the check is
that a field forms where the cell was wired and reaches roughly the peak rate
it was solved for. Adding a barrier beside a cell changes its response, which
is the property the whole arrangement exists to have.

The field did not move in that particular case; its peak rose by two hertz
instead. Both count, and the check accepts either: a wall added to one side
of a field can strengthen it without displacing its centre, depending on
which of the cell's inputs the new surface falls in front of.

Measured separately, over six hundred steps of foraging:

```
circuit driving: mean decode error 0.2162 m, worst 0.7625 m
analytic:        mean decode error 0.0444 m, worst 0.0594 m
```

The input-driven code is five times less precise. Sweeping single cells over
the arena shows why: most have one field, but some have three. In a symmetric
room two different places present the same arrangement of walls, so a cell
built from boundary input fires in both and the population vector is pulled
between them. That is a known property of this model class rather than a
defect in the implementation, and the connectome tab is where it can be seen.

### End to end

```
after 10.0 s unanchored, sheet is 0.0034 m from the truth
rat 0 wall distance before the edit 0.3193, after 0.1486
adding a barrier moved endpoints by up to 0.830 m
```

Path integration with the anchor off holds to three millimetres over ten
seconds of foraging. An environment edit changes what the rats sense on the
next step and changes where they end up.

### Recording, configuration and the interface

Row counts are checked against what the stride implies rather than for being
non-zero. A configuration round trip saves an edited arena, switches to a
different preset with different parameters, reloads, and requires that the
walls, cues, solids and every parameter came back. A missing file is refused
rather than half applied.

Every panel is drawn in every arena with each population selected in turn,
into an offscreen canvas. A batch of zero rats is drawn too, since the rat
count slider can reach it. The editor is driven the way a mouse drives it:

```
drag a box: solids 0 -> 1, walls 4 -> 8
erase: solids 0, walls 4
```

A drag commits a block on release, the erase tool removes the block and all
four of its segments, and a click that never moved leaves no zero-length wall
behind.

### Behavioural states

```
well fed, two rats, 200 s
explore      50.4%
forage       13.2%
eat           5.7%
groom         5.0%
rear          6.5%
rest         19.2%
locomotion 63.6%, maintenance 30.7%
```

The time budget is the one figure here that can be compared against a
published measurement, so its check is a wide band rather than a number tuned
to whatever the model currently produces: a fed rat in a familiar arena spends
between a third and three quarters of its time moving, and between a fifth and
three fifths on upkeep.

Two bugs surfaced from writing the panel that draws this.

**Hunger blocked every maintenance behaviour.** The first machine tested
hunger and returned before rolling for grooming, rearing or resting, so any
rat over the threshold never did any of them. In an arena with real
competition for food that is nearly always, and the budget came out at 93 per
cent locomotion. Motivation in an animal is graded, so the rates are now
scaled by one minus hunger.

**Rats at an exhausted patch churned.** With several rats sharing a patch that
regrows slower than they eat, all but the first got nothing each step, aborted
the mouthful and immediately tried again: 66,196 exploring bouts averaging two
hundredths of a second, and a budget reading three quarters eating while
nothing was eaten. A rat that gets nothing now drops the patch for a second
and a half, and does not abort the mouthful it is already taking. A check
fails if any state accumulates bouts shorter than a tenth of a second, because
that is the signature of two states swapping at a threshold.

Also checked: every rat is in exactly one state at every step, verified by
summing the budget against elapsed time times the batch size; every completed
bout lands in the histogram; a rat that is grooming or resting is not moving;
and two runs of one seed produce an identical ethogram.

### The head

```
largest head offset from the body: 1.750 rad, limit 1.750
decode against the head 0.00000 rad, against the body 1.570 rad
scans in 100 s: open field 0, plus maze 33
mean scan bout 1.12 s
```

The second line is the one that matters. The head-direction population
recovers the head exactly, because the encoding has no noise in it and a
noiseless code is exactly invertible. What changed is which variable it
encodes: the same decode is now up to 1.57 radians away from the body's
heading, where before the two were one number and the difference was zero by
construction.

Worth correcting a claim made while planning this: the old error of zero was
never an artefact of using the body's heading. It was, and still is, a
consequence of noiseless encoding. The fix was to encode the right variable.
Making the number look worse was never the point.

Vicarious trial and error is checked by where it happens rather than that it
happens: dozens of scans in a plus maze and none at all in an empty box, since
an open field has one open sector and a fork has four.

### Food, hunger and eating

```
after 10 s: hunger 0.350, eaten 0.00, food left 12.00
after 50 s: hunger 0.551, eaten 12.00, food left 0.00
food taken 12.0000, held by rats 12.0000, unaccounted 0.000000
16 rats: 12.00 eaten, 0.00 left, 5 of 16 got any
eaten without a foraging drive 0.00, with one 12.00
no food for 20 s: hunger 0.700, eaten 0.00
with regrowth: 36.18 eaten from a 12 unit patch
two runs of one seed, largest difference in eaten: 0.000e+00
```

The conservation check is the important one: everything removed from a patch
is inside a rat, to six decimal places. Feeding is the only thing that takes
food, and it runs as a serial pass after the parallel motion step precisely
so that several rats at one patch cannot race on its amount.

The foraging comparison is the one that says the behaviour is behaviour. Two
runs of the same seed, one with the food-seeking term switched off: the
wandering rats ate **nothing** in fifty seconds, the seeking ones cleared the
arena. A random walk essentially never finds a patch that small.

Sixteen rats on one patch empties it and leaves eleven of them with nothing,
which is what a limited resource is for. Regrowth turns the same patch into
something that feeds three times its own capacity over a minute.

### Memory and dead reckoning

Six checks, and the first two exist to establish that the task is a task.

The presets are no use for this. The two-room arena puts its doorway on the
line between the nest and the food, so a rat standing at the nest sees
straight through to the patch and never needs to remember anything. The first
version of this test measured that and reported no difference, correctly. The
arena is now built inside the test: two rooms, the doorway high, the larder
low, so the line from the nest to the food meets wall. The test checks the
occlusion in both directions before it draws any conclusion from the run.

The comparison is a hoarding task, because eating where you stand is not a
memory task. A rat that eats at the patch walks there once and camps, so it
only has to find the place a single time and remembering it buys almost
nothing: the measured difference was 0.4 per cent. A hoarder fills up, carries
the load to a nest that cannot see the larder, eats it there, and has to make
the trip again. Over two hundred seconds with six rats:

| memory | carried off the larder |
|---|---|
| off | 83.2 |
| on | 332.8 |

Confidence decay is checked by taking the food away: a rat holds notes while
the patch is there and holds none once it has gone.

Dead reckoning is checked three ways. The error grows with the path walked, at
2 metres and again at 10. It stays bounded over a long run, because arriving
at the nest is a fix that re-zeroes it. And with the drift set to zero the
error falls to whatever the re-zeroing distance allows, which is the whole
error accounted for.

#### Two radii, not one

The first version used a single distance for both smelling the nest and
having arrived at it, and the rats never got home. Steering by the reckoning
the whole way in cannot work: near the nest the reckoned vector is as short as
its own error, so the bearing is noise and the animal circles the spot it
believes is home. With one radius, closest approach over a five-minute run was
0.166 m against a threshold of 0.17, twenty-seven trips home produced almost
no arrivals, and the time budget showed the colony spending three times longer
walking home than resting once it got there.

Splitting the two fixed it. Beyond smelling range the rat steers by the
reckoning; within it, it walks at the nest itself; it has arrived when it is
inside the nest. Closest approach became 0.156 m, inside the 0.16 m nest, home
trips fell from 8.97 s to 4.87 s, and resting rose from 4.2 to 10.4 per cent
of the budget.

#### Heading home is locomotion

Adding a walk home to the state machine put a tenth of the time budget in a
state that the budget test counted as neither locomotion nor upkeep, which
made upkeep look low for a reason that had nothing to do with upkeep. Walking
home is locomotion and is now summed as such.

### Thirst, and two drives that compete

Nine checks. Water is conserved the way food is: everything drawn from a
puddle ends up inside a rat, to six decimal places, and no puddle goes
negative. A colony with both eats and drinks, and neither need is left
permanently unmet.

Deprivation is checked one drive at a time. Remove the water and thirst
reaches 1.000; remove the food and hunger reaches 1.000. The animal keeps
looking, because nothing in FlowRat dies.

The margin between the drives is measured rather than asserted. With no
margin a rat takes whichever level is larger, and at the crossover the two sit
within a hair of each other:

| drive margin | changes of mind over 400 s |
|---|---|
| 0.00 | 215 |
| 0.12 | 160 |

It still alternates with the margin on, which is the other half of the check:
a margin large enough to stop the oscillation would also stop the rat ever
switching, and that would starve one drive.

#### The second drive required rescaling the first

Adding thirst broke four existing checks, and the interesting one was the time
budget. A rat crosses the arena in about twenty seconds. At a metabolism of
0.035 it went from fed to starving in twenty-eight, so it could never get
ahead of its own stomach. That passed while hunger was the only drive, because
a rat could stand on a patch and eat as fast as the patch emptied. Putting the
water in another corner made camping impossible and the failure showed:

| | locomotion | upkeep | consuming |
|---|---|---|---|
| hunger only, metabolism 0.035 | 69.3% | 25.0% | 5.7% |
| both drives, 0.035 and 0.045 | 93.2% | 1.8% | 4.9% |
| both drives, 0.012 and 0.010 | 71.8% | 25.3% | 2.9% |

The middle row is an animal with no leisure at all. Note that consumption
barely moved between the first two rows: the rats were not failing to eat,
they were failing to ever be satisfied on both counts at once, so every roll
for grooming or resting was scaled to nothing and every idle moment became a
walk somewhere. Both rates are now set against the traverse.

Two other checks failed because the runs were calibrated to the old rate and
were simply too short to show their effect: twenty seconds of deprivation is
now a quarter of the way to hunger rather than most of it, and eating past a
patch's own capacity takes three minutes rather than one. Both were
lengthened. The fourth, competition for a single patch, now turns thirst off,
because sixteen rats deciding between two resources does not test what that
check is for.

### The spatial grid, and rats noticing each other

Five checks. The grid has to agree with the obvious quadratic answer exactly,
in every arena, at a batch big enough that cells hold more than one rat.
Exactly rather than approximately: an off-by-one on a cell boundary shows up
as a handful of disagreements out of thousands, which is the kind of thing a
tolerance hides. Over 2048 queries in eight arenas, nearest neighbour and
neighbour count both match with zero disagreements.

The build is checked for linearity. Sixteen times the rats costs 3.9 times the
time, which is sub-linear because clearing the cells is a fixed cost that does
not scale with the batch at all.

Personal space is measured rather than asserted: how often a rat has another
inside one body length falls from 0.7793 to 0.7453 when the repulsion is
switched on. The effect is small because the rats cluster at patches whatever
they do about each other, and the number is reported as measured.

#### The race the grid nearly introduced

The grid holds indices. The obvious way to answer "how far is rat j" is to
read `a.x[j]`, and that is exactly what the parallel motion pass is writing.
Rat i saw rat j before or after j moved depending on which thread got there
first, and two runs of one seed diverged by 0.79 m over four hundred steps,
with the divergence itself varying run to run.

The fix is a snapshot: the build copies the positions, headings and speeds it
binned, and the queries read the copy. `grid_nearest` and `grid_neighbours`
now take no `Agents` pointer at all, because the surest way not to read live
state by accident is not to have the pointer. Four doubles per rat, 128 KB at
the maximum batch.

#### One guarantee had to be split

A rat's path used to be independent of the batch size. It cannot stay that way
once rats steer around each other, and it should not: that is the feature. The
check now measures both arms of it. With the social term off, rat zero in a
batch of 128 and rat zero alone agree to the bit. With it on they differ by
0.21 m, which is the evidence that the term does anything.

#### A silent heap overflow, three sections away

Adding a profiling slot for the grid build turned the run into an abort inside
`malloc`, reported from the interface section, several sections after the
actual fault. Flow will not take a constant as an array size, so the four
arrays behind the profiler are written out with a literal length while
`PROF_SLOTS` is a separate constant. Widening one without the other writes one
past the end of four statics.

There is now a check that writes and reads back every profiling slot, which
catches this at the point of the mistake instead of wherever the corrupted
allocator next notices. The literal and the constant still have to be kept in
step by hand, and the comment above them says so.

### Novelty, and thigmotaxis that fades

Seven checks, measured the way the open-field test is measured: an empty
arena, an animal that has never seen it, and how much of its time it spends
near a wall. No food and no water, so nothing competes with exploring.

| | first minute | sixth minute | fall |
|---|---|---|---|
| with a map | 46.1% | 27.2% | 19.0 points |
| with no map | 24.8% | 13.6% | 11.1 points |

The control matters. Both fall, so some of the drop is the motion model
settling rather than the animal learning, and the check is split into the two
halves of what the map actually contributes: a naive rat starts far more
wall-bound, and comes down further.

Heading for the least known cell gets a rat 0.24 of the arena in five minutes
against 0.12 without. A reset returns familiarity to exactly zero, without
which the same animal cannot be run on a fresh room twice. A landmark is worth
1.00 when new and 0.20 once its corner is thoroughly known.

#### The bug that had moved the time budget in every phase

Maintenance behaviours are rolled for with a per-step probability. The roll is
only reached on a step where no timed bout is running, and a locomotion bout
carries a half-second timer, so a foraging rat got there about once every
thirty steps and was charged one step's worth of probability each time. The
grooming rate was therefore divided by however much of the run the colony
spent in timed states, which is a number that changed every time a behaviour
was added.

That is why every phase of this project perturbed the time budget and had to
retune something. The roll now charges the whole interval since the last one,
as a constant hazard over that interval, which cannot exceed one however long
it is. `groom rate /s` now means once per second whatever the animal was doing
in between.

The rates had to come down by roughly a factor of three once they meant what
they said. With them corrected the budget reads: locomotion 70.1 per cent,
grooming 11.7, rearing 5.0, resting 9.9.

#### Habituation before recording

The budget test claimed to measure a familiar arena while running a colony
that had just been put down. It now habituates for five minutes, clears the
ethogram and records the next five, which is what an experimenter does.

#### One byte a cell

The map was 256 doubles a rat, 8 MB across the maximum batch, and touching one
scattered cell per rat per step cost more than the rest of motion: bare
stepping of 4096 rats went from 1.37 ms to 2.10. As bytes it is 1 MB and
1.76 ms.

The conversion introduced and then removed a bug worth recording. Rounding to
whole levels means the increment can round to the level the cell is already
at, so a first attempt forced it up by one level a step. That replaced the
asymptotic approach to full with a straight line to it, and halved the
measured wall hugging of a naive rat, from a 19-point fall to a 1.9-point one.
The cell is now allowed to stick, which it does at about 0.94, and 0.94 is as
known as anything here needs.

#### A check that had been passing at random

The dead-reckoning drift check read the error off at the single instant the
path length crossed a mark. The reckoning is re-zeroed whenever a rat reaches
the nest, so that sample landed wherever it happened to fall relative to the
last homecoming, and the check failed and passed at random across three
phases. It now averages over every rat and every sample in each band: 0.1131 m
over the first 2 metres walked, 0.1413 m between 8 and 16, over 27,000
samples.

### Measuring the run rather than the model

Twenty checks, and the only ones in this project that are not the code
checking itself. The analysis bins spikes and occupancy from a recording and
scores the result without reference to the parameters that produced it, so
agreement between the two is evidence.

A thousand seconds in an open field with the drives switched off, so the
animal explores instead of commuting between two corners and the map has
coverage to work with. Thirty-two bins across two metres.

| | measured | model |
|---|---|---|
| place field centre | 0.032 m away | the configured centre |
| place field area | 0.0234 m² | 0.0430 m² from sigma 0.086 |
| head-direction preference | 0.013 rad | 0.000 rad |
| lattice spacing | 0.312 m | 0.350 m |

The negative controls matter as much. A velocity cell scores 1.35 bits per
spike against a place cell's 6.15. A place cell scores -0.000 for gridness
against a grid cell's 0.165, and has one field against the grid cell's 21. A
place cell scores a head-direction vector length of 0.328 against the head
cell's 0.861, on the same test.

#### An annulus in the wrong place

Gridness is computed over an annulus of the autocorrelogram that has to
contain the first ring of off-centre peaks. The first version used a fixed
fraction of the correlogram's size, which for a 0.35 m lattice in a 2 m arena
put the inner edge of the annulus outside the very peaks it was meant to be
looking at. Every grid cell scored about zero.

The ring is now found from the correlogram: the correlation falls away from
the centre and rises again at the first ring, so the ring is the first peak
after the trough. That number is also the measured lattice spacing, which is
what the table above compares against the configured one.

#### Not enough spikes to see anything

A lattice is spread over the whole arena rather than concentrated in one spot,
so at the default rate a thousand seconds put about eight spikes in each bin:
2424 spikes over three hundred bins, no visible structure, gridness 0.06. The
check now winds the grid population up before recording it. Recording a cell
that fires is not cheating; it is what an experimenter does when choosing
which cell to record.

#### The export, checked by reading it back

The panel writes every score, every bin of the map visited or not, every
heading bin and every behavioural transition to one CSV. The check opens the
file afterwards and counts the rows of each kind, because a claim in a README
that a panel writes a file is worth exactly as much as a check that opens it.

Writing that check found nothing wrong with the export and something wrong
with the format: the section headers were indistinguishable from data by their
first field, so a reader counting rows counted them too. They now start with a
hash, which is one test for a reader to drop them rather than knowledge of
where each section begins.

#### A check script that hid a link error

`tools/check.sh` reports the gfx entry point as OK, because `flow compile`
cannot link the window runtime and the missing `_flow_gfx_*` symbols are
expected. It did that by dropping the whole linker report, which also hid a
genuine undefined symbol: a panel function the file had forgotten to import.
It now inspects the undefined symbols and passes only when every one of them
is the graphics runtime.

### Adversarial parameters and damaged files

Every value below is reachable from the controls or from a configuration
file, and each is required to leave the batch contained and finite:

```
dt 0.5 s with rats at 8 m/s             broken   0, non-finite     0
dt of zero                              broken   0, non-finite     0
negative speed and zero relaxation time broken   0, non-finite     0
recurrent gain at its maximum           broken   0, non-finite     0
an arena eight centimetres across       broken   0, non-finite     0
wall table: 512 of 512 used, 54 refused
an arena stuffed to the wall limit      broken   0, non-finite     0
a single rat                            broken   0, non-finite     0
the largest batch the controls allow    broken   0, non-finite     0
truncated file: accepted 0, arena now 10 walls, 2.00 m wide
```

Four of these failed the first time the section ran.

**A truncated configuration loaded as a success.** Reading returned zero past
the end of the file, which is indistinguishable from a zero that was written,
so a file cut anywhere produced an arena of zero extent with no boundary
walls, and the rats left through the gap. The file now carries a trailer
holding its own length, computed by the writer, and a file whose length does
not match its trailer is refused before anything is applied. An earlier fix
counted the fixed header by hand and skipped it; that number was wrong by two
within a day, because the schema grew and the count did not. A length the
writer computes cannot drift from the writer.

**A relaxation time of zero divided to a non-number**, which spread from the
speed into the position and from there into every population that reads it.
The Ornstein-Uhlenbeck times are floored, and a rat whose state stops being a
number is returned to where it started that step rather than carrying the
value forward.

**The recurrent networks diverged at large timesteps.** The substep count was
a fixed setting, so at `dt = 0.5 s` the ratio `dt / tau` reached sixteen and
explicit Euler ran away within a few hundred steps. The requested count is
now a floor: whatever is needed to hold `dt / tau` under a half is used when
that is more.

**Allocation was never checked.** Sixty-one call sites used the result of
`malloc` without looking at it, so exhausting memory crashed somewhere
unrelated to the allocation that failed. Every allocation now passes through
a checked helper that names the buffer and stops, and the same helper keeps
the running total the performance tab reports.

Construction was also two seconds per simulation, all of it velocity
calibration. The result is a pure function of the kernel's shape, the time
constant and the timestep, so it is now remembered across networks built from
the same parameters. Twelve create-step-destroy cycles went from 23.8 s to
3.3 s.

---

## Benchmarks

Apple M4 Max, macOS 25.2.0, Apple clang 17.0.0, Flow 1.0.0 on the Python
host, C backend, OpenMP enabled through Homebrew's libomp. Wall-clock on the
monotonic clock, after a warm-up pass, over enough repetitions that the
clock's resolution stops mattering. Single run; no spread is reported.

Without OpenMP the same code is correct and serial. On this machine, enabling
it took a full step at eight rats from 2.26 ms to 0.98 ms.

### Agent stepping

Motion plus the full sensory sweep, populations off:

```
  rats     ms/step        us/rat     steps/s
     1      0.0973       97.2575       10282
    16      0.0984        6.1511       10161
    64      0.1062        1.6588        9420
   256      0.1247        0.4870        8021
  1024      0.2159        0.2109        4631
  2048      0.3539        0.1728        2825
  4096      0.5997        0.1464        1668
```

Below about two hundred and fifty rats the step is dominated by fixed cost:
sixteen rats cost almost exactly what one does. Past that it is linear, and
the per-rat cost keeps falling as the threads fill up.

### Population updates

Nanoseconds per cell per rat, at the largest size measured:

| population | ns/cell-rat | why |
|---|---|---|
| place | 0.22 | a squared distance and one `exp`, with a three-sigma cutoff that skips most cells |
| boundary | 6.6 | sixteen ray samples per cell, two `exp` each |
| grid | 9.8 | three `cos` per cell, no cutoff available |

Grid cells are the most expensive population by an order of magnitude, and
the reason is three transcendentals per cell with no early exit. Place cells
are the cheapest because the three-sigma cutoff removes the `exp` for the
majority of cells at any moment.

### Environment queries

```
         arena   walls      us/ray-fan  us/nearest-wall
    open field       4          0.1338          0.0435
        circle      64          1.5263          0.2042
     two rooms       6          0.1872          0.0517
    four rooms      10          0.2903          0.0715
        t maze      12          0.3493          0.0882
  linear track       4          0.1330          0.0302
     obstacles      24          0.6508          0.1092
     plus maze      20          0.5490          0.1360
```

Both queries are linear in wall count, as a sweep over every segment should
be. The circular arena is the expensive one because its boundary is
sixty-four segments; an analytic circle test would be one comparison, and the
uniform segment representation was chosen over that so every arena type takes
one code path.

### The recurrent network

Two regimes, because they answer different questions.

**Position regime**, sigma = n/5, one bump:

```
    sheet   cells    taps  lam 2nd  structured ms      dense ms   speedup
  16x16       256     225    0.912        0.0547        0.0512      0.9x
  24x24       576     529    0.905        0.0797        0.0850      1.1x
  32x32      1024     961    0.902        0.2267        0.1979      0.9x
  48x48      2304    2025    0.913        0.7761    over limit         -
  64x64      4096    3481    0.919        2.0893    over limit         -
```

**Lattice regime**, sigma = n/16, several bumps:

```
    sheet   cells    taps  lam 2nd  structured ms      dense ms   speedup
  16x16       256      49    1.759        0.0405        0.0434      1.1x
  24x24       576      81    1.762        0.0408        0.0708      1.7x
  32x32      1024     121    1.765        0.0436        0.1724      4.0x
  48x48      2304     225    1.770        0.1057    over limit         -
  64x64      4096     361    1.774        0.2673    over limit         -
```

This is the honest picture, and it is more interesting than "structured is
faster". A single-bump sheet needs an excitatory width near a fifth of its
own size, so the kernel covers most of the sheet and there is little
arithmetic to save: the structured form runs at roughly dense speed. In the
lattice regime the kernel is genuinely local, taps stay small as the sheet
grows, and the structured form is four times faster at 32 by 32 and pulling
away.

What the structured form wins in both regimes is memory, and with it the
ability to run at all:

```
    sheet   cells    kernel bytes     dense bytes
  16x16       256            7200          524288
  24x24       576           16928         2654208
  32x32      1024           30752         8388608
  48x48      2304           64800        42467328
  64x64      4096          111392       134217728
```

A 64 by 64 sheet is 111 KB of kernel against 134 MB of matrix, a factor of
twelve hundred, and the dense reference refuses to build past 2048 cells for
that reason. `lam 2nd` in both tables is the second eigenvalue: below one in
the position regime, above one in the lattice regime, which is what puts each
one where it is.

### Integrators

```
integrator         ms/step  one-step error
euler               0.1265       8.333e-05
semi-implicit       0.1395       8.333e-05
rk4                 0.1442       2.143e-12
exact arc           0.1385       0.000e+00
```

At 1024 rats the four are within fifteen per cent of each other and the
ordering between runs is not stable, because the step is dominated by the
sensory sweep rather than by the integration. RK4 costs four derivative
evaluations and buys eight orders of magnitude of accuracy for no measurable
time here, which makes the accuracy argument the only one that matters.

### Full workloads

Everything on: all five populations, both recurrent networks, at sixty
simulated hertz.

```
workload          rats   cells  mode         ms/frame   frames/s
small                8     420  sim only        0.873     1145.0
small                8     420  sim + ui        3.060      326.7
medium             128     420  sim only        0.952     1050.6
medium             128     420  sim + ui        3.231      309.5
large             1024     420  sim only        1.567      638.2
large             1024     420  sim + ui        4.363      229.2
huge              4096     420  sim only        3.767      265.5
huge              4096     420  sim + ui        8.706      114.9
```

The interface costs a roughly constant 2.2 to 4.9 ms a frame, because it
draws the same panels whatever the batch size and only ever plots the
selected rat. Four thousand rats with the full cockpit still leaves a third
of a 60 Hz budget spare.

Frame times shown inside the running application are higher than these,
because the profiler's frame slot wraps `gfx_present`, and under the headless
recorder that call writes a PPM to disk. The `sim total` and `render` rows in
the performance panel are the ones to read.

---

## Reproducing

```bash
./validate.sh
./bench.sh
./tools/uidemo.sh            # scripted session, frames to data/out/uidemo
```

The scripted session switches arena from the keyboard, clicks a tool in the
editor panel, drags a block into the arena, then switches tool and clicks
again. It is the interactive path the headless checks cannot reach.
