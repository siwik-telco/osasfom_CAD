import XCTest
import osasfom_cadCore
@testable import osasfom_cadSolver

/// Regression test for the "port feeding nothing" failure mode: a lumped
/// port whose terminals never actually touch a conductor stamps a resistor
/// that is, by construction, perfectly matched to its own reference
/// impedance — S11 comes out flat and near 0 dB everywhere, a result that
/// looks like a solver bug but is really just an unconnected port. The
/// runner should refuse to spend minutes computing that and fail
/// immediately instead.
final class NoConductorNearPortTests: XCTestCase {

    private func makeState(armMaterial: UUID?) -> CADModelState {
        var state = CADModelState(name: "Dipole", lengthUnit: .millimeter)
        let armLength = 56.0, gap = 6.0, radius = 3.0

        let topArm = CADBody(
            name: "Arm+Y",
            primitive: .cylinder(
                CylinderSpec(radius: Expression(radius), begin: Expression(gap / 2), end: Expression(gap / 2 + armLength), axis: .y)
            ),
            materialID: armMaterial
        )
        let bottomArm = CADBody(
            name: "Arm-Y",
            primitive: .cylinder(
                CylinderSpec(radius: Expression(radius), begin: Expression(-(gap / 2 + armLength)), end: Expression(-gap / 2), axis: .y)
            ),
            materialID: armMaterial
        )
        state.bodies = [topArm, bottomArm]
        state.simulation.domain = DomainSettings(mode: .automatic, padding: Vector3Expression(Vec3(repeating: 62)))
        state.simulation.frequency = FrequencyRange(minimumHertz: 0.8e9, maximumHertz: 2.0e9)
        state.simulation.mesh = MeshSettings(cellsPerWavelength: 10)
        state.simulation.ports = [
            SimulationPort(
                name: "Feed",
                begin: Vector3Expression(x: Expression(0), y: Expression(-gap / 2), z: Expression(0)),
                end: Vector3Expression(x: Expression(0), y: Expression(gap / 2), z: Expression(0)),
                direction: .y,
                impedanceOhm: 50
            )
        ]
        return state
    }

    @MainActor
    func testUnconnectedPortFailsImmediatelyInsteadOfRunning() throws {
        let document = CADDocument(state: makeState(armMaterial: nil)) // vacuum arms — nothing to feed
        let runner = SimulationRunner()

        XCTAssertThrowsError(try runner.run(document: document)) { error in
            guard case SimulationRunner.RunnerError.noConductorNearExcitedPort(let name) = error else {
                return XCTFail("expected .noConductorNearExcitedPort, got \(error)")
            }
            XCTAssertEqual(name, "Feed")
        }
        XCTAssertFalse(runner.isRunning, "a rejected run must never start")
    }

    @MainActor
    func testConnectedPortIsNotRejected() throws {
        var state = makeState(armMaterial: MaterialLibrary.pecID)
        // Only the synchronous pre-flight check matters here, so keep the
        // (unawaited, background) run itself as cheap as possible.
        state.simulation.solver.maximumTimeSteps = 1
        let document = CADDocument(state: state)
        let runner = SimulationRunner()

        XCTAssertNoThrow(try runner.run(document: document))
    }

    /// Regression test for a real false positive: a vertical via-style port
    /// spanning an entire substrate (gap ~1.5mm) to connect a thin top trace
    /// to an even thinner (35µm) ground plane. The port's own gap is ~45x
    /// the ground plane's thickness, so the old "step one gap-length beyond
    /// each terminal" check overshot the ground plane by over a millimeter
    /// and landed in free space — flagging a correctly-connected port as
    /// unconnected. This is the exact geometry (units, thicknesses) of the
    /// patch antenna project that surfaced the bug.
    @MainActor
    func testViaStylePortThroughAThinGroundPlaneIsNotRejected() throws {
        let copper = MaterialLibrary.copperID
        let substrateHeight = 1.6
        let copperThickness = 0.035
        let boardWidth = 40.0, boardDepth = 40.0

        let substrate = CADBody(
            name: "substrate",
            primitive: .box(
                BoxSpec(
                    beginX: Expression(-boardWidth / 2), endX: Expression(boardWidth / 2),
                    beginY: Expression(-boardDepth / 2), endY: Expression(boardDepth / 2),
                    beginZ: Expression(0), endZ: Expression(substrateHeight)
                )
            ),
            materialID: MaterialLibrary.fr4ID,
            priority: 0
        )
        // A thin trace at the bottom, reaching the board edge — same role as
        // the feed line in the real project.
        let trace = CADBody(
            name: "trace",
            primitive: .sheet(SheetSpec(width: Expression(3), depth: Expression(boardDepth), begin: Expression(0), end: Expression(copperThickness), normal: .z)),
            materialID: copper,
            priority: 1
        )
        // A thin ground plane at the top, spanning the whole board.
        let ground = CADBody(
            name: "ground",
            primitive: .sheet(
                SheetSpec(
                    width: Expression(boardWidth), depth: Expression(boardDepth),
                    begin: Expression(substrateHeight), end: Expression(substrateHeight + copperThickness),
                    normal: .z
                )
            ),
            materialID: copper,
            priority: 1
        )

        var state = CADModelState(name: "Patch", lengthUnit: .millimeter)
        state.bodies = [substrate, trace, ground]
        state.simulation.domain = DomainSettings(mode: .automatic, padding: Vector3Expression(Vec3(repeating: 30)))
        state.simulation.frequency = FrequencyRange(minimumHertz: 2.0e9, maximumHertz: 3.0e9)
        state.simulation.mesh = MeshSettings(cellsPerWavelength: 10)
        state.simulation.ports = [
            SimulationPort(
                name: "Feed",
                // Vertical via: bottom terminal on the trace's top face,
                // top terminal on the ground plane's bottom face — exactly
                // touching each conductor, same as the fixed project file.
                begin: Vector3Expression(x: Expression(0), y: Expression(boardDepth / 2 - 2), z: Expression(copperThickness)),
                end: Vector3Expression(x: Expression(0), y: Expression(boardDepth / 2 - 2), z: Expression(substrateHeight)),
                direction: .z,
                impedanceOhm: 50
            )
        ]
        state.simulation.solver.maximumTimeSteps = 1

        let document = CADDocument(state: state)
        XCTAssertEqual(document.resolved.diagnostics.errors.count, 0, "\(document.resolved.diagnostics.errors)")

        let runner = SimulationRunner()
        XCTAssertNoThrow(try runner.run(document: document))
    }

    /// Regression test for a false positive caused by floating-point noise
    /// rather than a modeling mistake: an edge-launched feed line whose
    /// board-edge coordinate is built from the *same* shared expression
    /// (`-lg/2`) as the feed line body's own edge. Combining that value
    /// through the body's center/half-extent subtraction introduces a ~1e-15
    /// rounding error, so the exact-shape containment test's bare `<=`
    /// rejected the feed line at the one point the port actually needs it —
    /// falling through to the FR-4 substrate underneath and reporting an
    /// unconnected port for a design that was geometrically correct. This is
    /// the real patch antenna project that surfaced the bug: a Box-shaped
    /// substrate/patch/feed-line/ground stack (not the Sheet-based one
    /// above), all bodies at priority 0, via-style port from the feed line's
    /// top face to the ground plane's far face.
    @MainActor
    func testEdgeLaunchedPortOnASharedCoordinateBoundaryIsNotRejected() throws {
        let copper = MaterialLibrary.copperID
        let w = 38.4, l = 29.8, wg = 69.6, lg = 61.0, h = 1.6, mt = 0.035, wt = 2.61

        let substrate = CADBody(
            name: "fr-4",
            primitive: .box(BoxSpec(
                beginX: Expression(-wg / 2), endX: Expression(wg / 2),
                beginY: Expression(-lg / 2), endY: Expression(lg / 2),
                beginZ: Expression(0), endZ: Expression(h)
            )),
            materialID: MaterialLibrary.fr4ID,
            priority: 0
        )
        let patch = CADBody(
            name: "patch",
            primitive: .box(BoxSpec(
                beginX: Expression(-w / 2), endX: Expression(w / 2),
                beginY: Expression(-l / 2), endY: Expression(l / 2),
                beginZ: Expression(0), endZ: Expression(mt)
            )),
            materialID: copper,
            priority: 0
        )
        // Reaches the board edge at y = -lg/2 — the same expression the
        // port's own coordinate is built from.
        let feedLine = CADBody(
            name: "feed line",
            primitive: .box(BoxSpec(
                beginX: Expression(-wt / 2), endX: Expression(wt / 2),
                beginY: Expression(-lg / 2), endY: Expression(-l / 2),
                beginZ: Expression(0), endZ: Expression(mt)
            )),
            materialID: copper,
            priority: 0
        )
        let ground = CADBody(
            name: "ground",
            primitive: .box(BoxSpec(
                beginX: Expression(-wg / 2), endX: Expression(wg / 2),
                beginY: Expression(-lg / 2), endY: Expression(lg / 2),
                beginZ: Expression(h), endZ: Expression(h + mt)
            )),
            materialID: copper,
            priority: 0
        )

        var state = CADModelState(name: "Patch", lengthUnit: .millimeter)
        state.bodies = [substrate, patch, feedLine, ground]
        state.simulation.domain = DomainSettings(
            mode: .automatic,
            padding: Vector3Expression(x: Expression(125.0 / 4), y: Expression(125.0 / 4), z: Expression(125.0 / 2))
        )
        state.simulation.frequency = FrequencyRange(minimumHertz: 2.0e9, maximumHertz: 3.0e9)
        state.simulation.mesh = MeshSettings(cellsPerWavelength: 20)
        state.simulation.ports = [
            SimulationPort(
                name: "Feed",
                begin: Vector3Expression(x: Expression(0), y: Expression(-lg / 2), z: Expression(mt)),
                end: Vector3Expression(x: Expression(0), y: Expression(-lg / 2), z: Expression(h + mt)),
                direction: .y,
                impedanceOhm: 50
            )
        ]
        state.simulation.solver.maximumTimeSteps = 1

        let document = CADDocument(state: state)
        XCTAssertEqual(document.resolved.diagnostics.errors.count, 0, "\(document.resolved.diagnostics.errors)")

        let runner = SimulationRunner()
        XCTAssertNoThrow(try runner.run(document: document))
    }

    /// A probe feeding a patch built from zero-thickness PEC sheets — the
    /// standard way to draw a microstrip antenna here, since modelling 35 µm
    /// copper would force 35 µm cells through the whole board.
    ///
    /// Regression: the check only ever sampled one cell step *away* from each
    /// terminal, in both directions. A sheet has no volume, so both samples
    /// land off it no matter how small the step, and a correctly drawn patch
    /// feed was rejected as unconnected. `ShapeContainment` keeps sheets a
    /// surface on purpose — `snapToBodyEdges` puts a grid line exactly on
    /// them — so a terminal sitting on one is the most correct way to draw
    /// the connection, not an error.
    @MainActor
    func testProbeOntoZeroThicknessSheetsIsNotRejected() throws {
        let h = 1.575, patchW = 48.97, patchL = 40.98, board = 68.0
        var state = CADModelState(name: "Patch", lengthUnit: .millimeter)

        state.bodies = [
            CADBody(
                name: "Substrate",
                primitive: .box(
                    BoxSpec(
                        beginX: Expression(-board / 2), endX: Expression(board / 2),
                        beginY: Expression(-board / 2), endY: Expression(board / 2),
                        beginZ: Expression(0), endZ: Expression(h)
                    )
                ),
                materialID: MaterialLibrary.fr4ID,
                priority: 0
            ),
            CADBody(
                name: "Ground",
                primitive: .sheet(
                    SheetSpec(
                        width: Expression(board), depth: Expression(board),
                        begin: Expression(0), end: Expression(0), normal: .z
                    )
                ),
                materialID: MaterialLibrary.pecID,
                priority: 2
            ),
            CADBody(
                name: "Patch",
                primitive: .sheet(
                    SheetSpec(
                        width: Expression(patchW), depth: Expression(patchL),
                        begin: Expression(h), end: Expression(h), normal: .z
                    )
                ),
                materialID: MaterialLibrary.pecID,
                priority: 2
            )
        ]
        state.simulation.domain = DomainSettings(mode: .automatic, padding: Vector3Expression(Vec3(repeating: 62)))
        state.simulation.frequency = FrequencyRange(minimumHertz: 2.0e9, maximumHertz: 2.9e9)
        state.simulation.mesh = MeshSettings(
            cellsPerWavelength: 10,
            fixedLinesZ: [Expression(h / 4), Expression(h / 2), Expression(3 * h / 4)]
        )
        // Probe from the ground sheet up to the patch sheet, offset toward a
        // radiating edge the way a real feed is.
        state.simulation.ports = [
            SimulationPort(
                name: "Feed",
                begin: Vector3Expression(x: Expression(0), y: Expression(6.18), z: Expression(0)),
                end: Vector3Expression(x: Expression(0), y: Expression(6.18), z: Expression(h)),
                direction: .z,
                impedanceOhm: 50
            )
        ]
        state.simulation.solver.maximumTimeSteps = 1

        let runner = SimulationRunner()
        XCTAssertNoThrow(try runner.run(document: CADDocument(state: state)))
    }
}
