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
`ResolvedModel`, drives the engine, and extracts S11 from an excited lumped
port. `SimulationRunner.run(document:)` is the entry point; it is not yet
wired into the app's UI, only into the library graph.

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
- Everything else a full antenna solver needs — waveguide ports,
  near-to-far-field transform, multi-port S-parameters, adaptive
  time-stepping/frequency-domain features — is not implemented.

Being a derivative of GPLv3-licensed openEMS code, `osasfom_cadSolver` is
GPLv3 (see `LICENSE`).

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

## Building

```bash
swift build
swift run osasfom_cad
swift test
```

In Xcode: open `Package.swift`, select the `osasfom_cad` scheme and *My Mac*.

Requires macOS 13+ and Swift 5.9.

## Not yet implemented

Sketch-based modelling, extrude, boolean operations, face and edge selection,
and snapping. On the solver side: a UI to launch a run and see its results,
waveguide ports, near/far-field transforms, multi-port S-parameters, and a
true PML (the current absorbing boundary is an approximate graded lossy
layer — see [Solver](#solver)).
