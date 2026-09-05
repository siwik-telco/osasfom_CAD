# osasfom_cad

A macOS CAD front-end for building antenna geometry and FDTD simulation setups.

Geometry is **parametric**: every dimension, position and rotation is an
expression, so a patch can be `0.49 * lambda / sqrt(4.3)` and follow its
variables. The model stores only the source text; numbers are derived.<br>
## References

This project is an open source project and uses existing solutions for EMF solving problems: 
- [openEMS](https://github.com/thliebig/openEMS) — reference implementation used for the FDTD solver.
- [CSXCAD](https://github.com/thliebig/CSXCAD) — geometry and mesh handling.


## Screenshots - notice there is a lot to do..
Main interface with halfwave dipole model
![interface.dipole](images/pov.png)

Dipole model with lumped port created
![port_lumped](images/Port.png)


Main interface of an app with model of patch antenna
![interface](images/Interface.png)


## Structure

```text
osasfom_cad
├── Package.swift
├── Sources
│   ├── osasfom_cadCore      # headless model layer — Foundation only
│   │   ├── Geometry/        # Vec3, Axis, Matrix3, BodyBounds
│   │   ├── Expressions/     # lexer, parser, evaluator, builtins
│   │   ├── Model/           # primitives, bodies, variables, materials, units
│   │   ├── Simulation/      # domain, boundaries, mesh, ports, monitors
│   │   ├── Resolve/         # expressions → geometry + diagnostics
│   │   ├── IO/              # project file, legacy import, solver export
│   │   └── Document/        # document + snapshot undo
│   ├── osasfom_cadRender    # SceneKit scene controller
│   ├── osasfom_cadSolver    # FDTD engine (openEMS port, GPLv3) + CAD bridge
│   └── osasfom_cad          # SwiftUI app
└── Tests
    ├── osasfom_cadCoreTests
    └── osasfom_cadSolverTests
```

Core imports neither AppKit nor SceneKit, so it can be driven from a
command-line mesher or solver harness and is fully unit-testable.

### Solver

`osasfom_cadSolver` is a real, buildable, tested target: a Swift port of
openEMS's Yee-grid `Engine`/`Operator` core, plus a bridge
(`GridMesher`, `CADMaterialProvider`, `SimulationRunner`) that meshes a
`ResolvedModel` and drives the engine. It is wired all the way into the app:
the inspector's **Run** tab starts and stops a simulation, shows live
progress and grid size, and plots the result.

It has one working, tested capability end to end: **return loss of a
lumped-port antenna** (`osasfom_cadSolverTests/DipoleReturnLossTests.swift`
builds a half-wave dipole purely through the public CAD model and asserts a
physically-valid resonance dip in the S11 sweep). Beyond that:

- The lumped port is resistively stamped (its reference impedance is added
  directly to the local Yee-edge conductance, not just a lossless soft
  source), and its current is read via curl(H) around the edge — not the
  edge's own-direction H component, which vanishes by symmetry on an axis
  like a dipole's centerline.
- Boundaries: `.electric`/`.magnetic` faces become permanent hard walls.
  `.pml` faces get a graded, impedance-matched **lossy layer**, not a true
  PML — no complex-frequency-shifted coordinate stretching, so it absorbs
  normal-incidence waves reasonably well but reflects more than real PML at
  oblique angles and low frequencies. `.periodic` is unimplemented.
- The port-current extraction and the resistive stamp are exact only when
  the feed gap spans exactly one Yee edge, which is guaranteed by
  `GridMesher` always placing a fixed grid line at each port terminal.
- **Before spending minutes on a run**, it checks that every excited lumped
  port's terminals actually touch a conductor. Without that, the port's
  resistor sits alone in free space, perfectly matched to its own reference
  impedance — S11 comes out flat and near 0 dB at every frequency, a result
  that looks like a solver bug but is really just an unconnected port. The
  run refuses immediately instead of computing that silently.
- Everything else a full antenna solver needs — waveguide ports,
  near-to-far-field transform, multi-port S-parameters, adaptive
  time-stepping/frequency-domain features — is not implemented.

Being a derivative of GPLv3-licensed openEMS code, `osasfom_cadSolver` is
GPLv3 (see `LICENSE`).

#### Running a simulation

The **Run** tab (inspector) drives everything:

- **Run / Stop.** Stopping doesn't discard the work in progress: the DFT
  integrates over whatever time series was recorded so far, so a stopped run
  still yields a (less converged, clearly flagged) spectrum instead of
  nothing — useful for an early look at where a resonance is heading.
- **Plot range.** The S11 chart can be rescoped to a sub-band of what was
  actually simulated, recomputed instantly from the already-recorded time
  series — no re-run needed, since the DFT can be evaluated at any frequency
  after the fact. Any requested range is clamped to the band that was
  actually excited, so you can never end up looking at frequencies with no
  real excitation energy behind them.
- **Run history.** Every completed run this session is kept, tied to the
  variable values that produced it. Selecting a past run shows its S11 curve
  and its full variable snapshot — any variable that has since changed in
  the live document is highlighted, old value → new, so a result never
  quietly goes stale without you noticing. History is session-only — it is
  not written to the project file, so it resets when the app relaunches.

#### Multicore

The per-timestep field updates (`Engine.updateVoltages`/`updateCurrents`)
are parallelized across X-plane chunks via `DispatchQueue.concurrentPerform`
— safe because each phase only *writes* its own plane while *reading* a
field array nothing else touches during that phase (the standard leapfrog
property). Two things had to be fixed to make this actually pay off, both
confirmed by direct benchmark, not just theory:

- Dispatching one task per X-plane (as small grids only have a few dozen)
  cost more in scheduling overhead than it saved — fixed by chunking into
  core-sized batches instead of one dispatch per plane.
- Even chunked, it was *still* slower than sequential, because field storage
  was a Swift `Array`, whose copy-on-write bookkeeping causes cross-core
  cache-line contention on every access — even to disjoint indices. Fixed by
  switching to raw `UnsafeMutablePointer` storage.

Net result, on a 512k-cell synthetic grid: **5.6x speedup** (1.76s → 0.31s
for 20 timesteps), and the sequential path itself got roughly 2x faster too
as a side effect of dropping the `Array` overhead. Below a cell-count
threshold, the plain sequential loop still wins and is used automatically —
parallelizing everything unconditionally was the original mistake.

## Modelling

### Expressions

Any dimension field accepts an expression:

```
patch_w / 2
lambda / 4 - gap
sqrt(2) * h_sub
c0 / (f0_GHz * 1e9) * 1000
```

Operators `+ - * / % ^` with the usual precedence (`^` is right-associative,
`-2^2 == -4`). Functions include `sqrt`, `abs`, `min`, `max`, `clamp`, `lerp`,
`hypot`, `mod`, `floor`, `ceil`, `round`, `exp`, `log`, `log10`, `log2`, the
trigonometric family in radians plus `sind`/`cosd`/`tand` in degrees, and
`deg`/`rad`. Constants: `pi`, `tau`, `e`, `c0`, `eps0`, `mu0`, `z0`.

Variables may reference other variables. Cycles are detected and reported, not
hung on. Renaming a variable rewrites every expression that referenced it, so a
rename can never leave a dangling reference behind.

`.` is the only decimal separator, so a project file means the same thing on
every machine regardless of locale.

### Primitives

- **Box** — width (X), height (Y), depth (Z)
- **Cylinder** — radius, a selectable axis, and **begin/end**: the absolute
  coordinates of its two terminals along that axis, in the same frame as a
  body's position. This lets a monopole start exactly at a ground plane
  instead of always being centred on it — the body's Position field on that
  one axis is unused for a cylinder; the other two axes still position it as
  usual.
- **Sheet** — width, depth, thickness and a selectable normal. **Thickness may
  be zero**, giving an infinitely thin surface, which is the natural way to
  model a PEC patch or ground plane.

### Overlap priority

Where bodies overlap, the higher `priority` owns the cells; ties break toward
the later body in the list. Overlapping bodies with equal priority and different
materials raise a warning, because that case is ambiguous for a voxeliser.

### Materials

ε_r, µ_r, electric conductivity (S/m), magnetic conductivity (Ω/m), an explicit
PEC/PMC flag, and optional Debye, Drude or Lorentz dispersion. Loss tangent can
be entered directly and is converted to σ at the band centre. A body with no
material assignment resolves to vacuum.

### Simulation setup

Computational domain (automatic padding or manual bounds), per-face boundary
conditions (PML / electric / magnetic / periodic), mesh settings (cells per
wavelength, min and max cell size, fixed grid lines, local refinements), the
frequency range and excitation waveform, lumped and waveguide ports, and field
monitors.

## Validation

Nothing is silently repaired. The resolver produces diagnostics, and a body
whose expressions do not evaluate drops out of the resolved model with an error
rather than rendering a stale size. The status bar summarises errors and
warnings; clicking one selects the body it belongs to.

## Files

Two distinct formats, deliberately:

| | Project (`.osasfomcad`) | Solver export (`.json`) |
|---|---|---|
| Purpose | editable source | run a simulation |
| Dimensions | expressions, verbatim | resolved numbers |
| Units | project units | **SI — metres, hertz, S/m** |
| Round-trips | yes | no, it is an output |

The solver export refuses to run while the model has errors, so a deck can never
silently omit a broken body. Bodies are emitted in material-assignment order
(highest priority first) with precomputed axis-aligned bounds, and it records
the coordinate and rotation conventions plus the overlap rule in its `meta`
block.

Projects written by the original prototype (format 1) are imported
automatically; its name-based variable bindings become real expressions.

**STL export** (File → Export STL…, ⇧⌘E) writes every visible body's surface
as binary STL, in the project's own length unit — for cross-checking this
model's geometry against another EM tool (e.g. CST) that can import STL.
STL carries no unit metadata, so the export dialog says explicitly which
unit to tell the importing tool to use.

## Editing behaviour worth knowing

- **The camera never moves on its own.** The scene is reconciled incrementally,
  so editing a dimension does not disturb your orbit. Use *Zoom to Fit* (⌘0).
- **Undo covers everything** (⌘Z / ⇧⌘Z). Typing into a field is one undo step,
  not one per keystroke.
- **Extent editing is offered only where it is well defined.** For a rotated
  body the box shown is its true axis-aligned bounding box, read-only; a
  cylinder has no unique inverse, so you edit radius, begin, end and axis
  instead. Editing extents on a parametric body replaces those expressions
  with numbers, and says so first.
- **Changing the length unit reinterprets numbers, it does not rescale them** —
  expressions like `patch_w / 2` have no meaningful rescale.
- **The X/Y/Z axes are labelled in the 3D view** (red/green/blue, matching the
  axis pickers), so it is never a guess which is which.
- **New documents start empty** — no starter geometry or preset variables are
  loaded on launch.
- **A lumped port renders as a thick tube with colored terminal markers** —
  red at `begin`, blue at `end` (voltage is measured begin → end) — instead
  of a hairline, which is easy to lose against real geometry. A waveguide
  port (no discrete terminals) still shows as a wire box with a direction
  arrow.
- **A port's terminals can be set by clicking**, not just typing coordinates.
  In the port editor, **Pick** next to Begin or End arms click-to-place in
  the viewport; clicking a body's face snaps that terminal to the face's
  center. (Editing a lumped port's gap through **Begin/End**, not the
  Region fields — Region is only meaningful for waveguide ports; the
  resolver never reads it for a lumped one.)

## Building

```bash
swift build
swift run osasfom_cad
swift test
```

In Xcode: open `Package.swift`, select the `osasfom_cad` scheme and *My Mac*.

Requires macOS 13+ and Swift 5.9.

## Not yet implemented

Sketch-based modelling, extrude, boolean operations, general face/edge
selection (beyond picking a face to place a port terminal), and snapping. On
the solver side: solving waveguide ports, a near-to-far-field transform (so
no 3D radiation-pattern render yet), multi-port S-parameters, adaptive
time-stepping/frequency-domain features, and a true PML (the current
absorbing boundary is an approximate graded lossy layer — see
[Solver](#solver)).
