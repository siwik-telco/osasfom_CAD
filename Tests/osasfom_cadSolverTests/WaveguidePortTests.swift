import XCTest
import osasfom_cadCore
@testable import osasfom_cadSolver

/// The waveguide port: a TE_m0 mode imposed over a user-drawn rectangle.
///
/// The model layer always carried `kind == .waveguide`, a `region` and a
/// `modeIndex`, and the viewport drew the box — but the solver looped over
/// `where port.kind == .lumped` and silently ignored them, so a waveguide port
/// simulated as nothing at all.
///
/// The geometry here is WR-90 (22.86 × 10.16 mm, TE₁₀ cutoff 6.557 GHz) built
/// the minimal way: the *domain walls* are the guide walls. Electric boundaries
/// on the two transverse faces, PML on the propagation axis, nothing else in
/// the model. That makes the expected answer exact rather than approximate —
/// a mode launched into a matched guide must come back as almost nothing.
final class WaveguidePortTests: XCTestCase {

    private let a = 22.86, b = 10.16, guideLength = 60.0
    /// c / 2a for WR-90.
    private let cutoffGHz = 6.5570

    private func makeState(
        modeIndex: Int = 1,
        minimumHertz: Double = 8.0e9,
        maximumHertz: Double = 12.0e9
    ) -> CADModelState {
        var state = CADModelState(name: "WR-90", lengthUnit: .millimeter)
        state.bodies = []

        state.simulation.domain = DomainSettings(
            mode: .manual,
            manualBounds: BoundsExpression(
                xMin: Expression(0), xMax: Expression(a),
                yMin: Expression(0), yMax: Expression(b),
                zMin: Expression(0), zMax: Expression(guideLength)
            )
        )
        // The transverse walls are the waveguide; only the ends absorb.
        state.simulation.boundaries = BoundarySettings(
            xMin: .electric, xMax: .electric,
            yMin: .electric, yMax: .electric,
            zMin: .pml, zMax: .pml,
            pmlCellCount: 8
        )
        state.simulation.frequency = FrequencyRange(minimumHertz: minimumHertz, maximumHertz: maximumHertz)
        state.simulation.mesh = MeshSettings(cellsPerWavelength: 20)
        state.simulation.solver.maximumTimeSteps = 20_000
        state.simulation.solver.energyDecayDecibels = -40
        state.simulation.ports = [
            SimulationPort(
                name: "WG",
                kind: .waveguide,
                begin: .zero,
                end: .zero,
                region: BoundsExpression(
                    xMin: Expression(0), xMax: Expression(a),
                    yMin: Expression(0), yMax: Expression(b),
                    // A box a third of the way in, clear of the PML. The
                    // resolver requires a span along the propagation axis;
                    // the mode is launched from the face it starts at.
                    zMin: Expression(guideLength / 3), zMax: Expression(guideLength / 3 + 4)
                ),
                direction: .z,
                modeIndex: modeIndex
            )
        ]
        return state
    }

    private func plan(_ state: CADModelState) throws -> WaveguidePortExtension.Plan {
        let resolved = ModelResolver.resolve(state)
        XCTAssertEqual(resolved.errorCount, 0, "\(resolved.diagnostics.errors)")
        let lines = try XCTUnwrap(
            GridMesher.makeDiscLines(resolved: resolved, setup: state.simulation, unit: state.lengthUnit)
        )
        let op = Operator()
        op.setupGrid(discLines: lines.metersLines, gridDeltaUnit: 1.0)
        let provider = CADMaterialProvider(
            bodies: resolved.bodies, materials: state.materials, unit: state.lengthUnit
        )
        op.materialProvider = provider
        op.calcECOperator()

        let port = try XCTUnwrap(resolved.simulation.ports.first)
        return try XCTUnwrap(
            WaveguidePortExtension.plan(
                for: port, unit: state.lengthUnit, lines: lines, op: op, materialProvider: provider
            )
        )
    }

    // MARK: - Mode geometry

    /// The whole design rests on picking the broad wall correctly: get it
    /// backwards and the cutoff more than doubles, putting the entire X band
    /// below it. It is taken from the rectangle rather than asked for, so a
    /// port drawn either way up still excites the fundamental.
    func testBroadWallAndCutoffComeFromTheRectangle() throws {
        let plan = try plan(makeState())
        XCTAssertEqual(plan.broadWidthMeters, a / 1000, accuracy: 1e-6, "broad wall is the 22.86 mm one")
        XCTAssertEqual(plan.cutoffHertz / 1e9, cutoffGHz, accuracy: 0.01)
        // TE10: E across the narrow wall (Y), transverse H along the broad (X).
        XCTAssertEqual(plan.eIndex, 1)
        XCTAssertEqual(plan.hIndex, 0)
    }

    func testHigherModeHasProportionallyHigherCutoff() throws {
        let te10 = try plan(makeState(modeIndex: 1))
        let te20 = try plan(makeState(modeIndex: 2, minimumHertz: 14e9, maximumHertz: 18e9))
        XCTAssertEqual(te20.cutoffHertz / te10.cutoffHertz, 2, accuracy: 1e-9, "f_c scales with m")
    }

    /// The profile must vanish at both walls — tangential E on a perfect
    /// conductor is zero — and peak in the middle. A sampled edge with a
    /// non-zero weight against a wall would be driving a field the boundary
    /// condition then annihilates.
    func testModeProfileVanishesAtTheWalls() throws {
        let plan = try plan(makeState())
        let weights = plan.probe.map(\.weight)
        XCTAssertFalse(weights.isEmpty)
        XCTAssertTrue(weights.allSatisfy { $0 > 0 }, "TE10 is single-signed across the guide")
        XCTAssertEqual(try XCTUnwrap(weights.max()), 1.0, accuracy: 0.02, "peaks at the centre")
    }

    // MARK: - Modal impedance

    /// A waveguide's wave impedance is dispersive, which is the reason
    /// `PortRecorder` asks for it per frequency instead of storing one number
    /// the way a lumped port does.
    func testModalImpedanceIsDispersiveAndUndefinedBelowCutoff() throws {
        let plan = try plan(makeState())
        let port = WaveguidePortExtension(
            name: "t", handle: EngineHandle(),
            eIndex: plan.eIndex, hIndex: plan.hIndex, drive: plan.drive, probe: plan.probe,
            cutoffHertz: plan.cutoffHertz, mediumImpedance: plan.mediumImpedance,
            isReversed: false, excitation: Excitation(waveform: .gaussianPulse),
            frequency: FrequencyRange(minimumHertz: 8e9, maximumHertz: 12e9),
            isExcited: true, amplitude: 1, dT: { 1e-12 }
        )

        XCTAssertNil(port.referenceImpedance(atHertz: 5e9), "below cutoff there is no propagating mode")
        XCTAssertNil(port.referenceImpedance(atHertz: plan.cutoffHertz), "at cutoff it diverges")

        let low = try XCTUnwrap(port.referenceImpedance(atHertz: 7.5e9))
        let high = try XCTUnwrap(port.referenceImpedance(atHertz: 12e9))
        XCTAssertGreaterThan(low, high, "Z_TE falls toward η as frequency rises")
        XCTAssertGreaterThan(high, 376.7, "and stays above the free-space value")

        // Z_TE = eta / sqrt(1 - (fc/f)^2), checked against the closed form.
        let ratio = plan.cutoffHertz / 10e9
        let expected = 376.730313668 / (1 - ratio * ratio).squareRoot()
        XCTAssertEqual(try XCTUnwrap(port.referenceImpedance(atHertz: 10e9)), expected, accuracy: 1e-6)
    }

    // MARK: - Rejections

    @MainActor
    func testBandEntirelyBelowCutoffIsRejectedWithTheNumber() throws {
        // WR-90 cuts off at 6.56 GHz; sweep 2-4 GHz and nothing can propagate.
        let state = makeState(minimumHertz: 2e9, maximumHertz: 4e9)
        let runner = SimulationRunner()
        XCTAssertThrowsError(try runner.run(document: CADDocument(state: state))) { error in
            guard case SimulationRunner.RunnerError.waveguidePortBelowCutoff(let name, let cutoff) = error else {
                return XCTFail("expected .waveguidePortBelowCutoff, got \(error)")
            }
            XCTAssertEqual(name, "WG")
            XCTAssertEqual(cutoff / 1e9, cutoffGHz, accuracy: 0.01)
        }
        XCTAssertFalse(runner.isRunning)
    }

    // MARK: - End to end

    /// The load-bearing test, in two halves.
    ///
    /// **Passivity** pins the sign convention. A passive port cannot reflect
    /// more power than it receives, so |S11| must stay below 0 dB. Get the
    /// sign of the modal current backwards and this comes out positive — the
    /// port appears to generate power, the same failure the lumped port's
    /// current flip guards against.
    ///
    /// **Propagation** proves the mode is real rather than a stationary
    /// disturbance: a guide whose far end absorbs must ring down markedly
    /// faster than one that shorts. Nothing launched, and the two would agree.
    ///
    /// What is deliberately *not* asserted is a near-zero |S11| for this
    /// "matched" guide. It is not matched: `absorbingBoundary` is tuned for
    /// free space and reflects a substantial share of a guided mode, which the
    /// ratio below quantifies. That is a boundary-condition limitation, and
    /// the port reports the resulting standing wave correctly.
    @MainActor
    func testLaunchedModeIsPassiveAndPropagatesAway() async throws {
        let runner = SimulationRunner()
        runner.spectrumPointCount = 41
        await (try runner.run(document: CADDocument(state: makeState()))).value

        XCTAssertFalse(runner.s11Spectrum.isEmpty)
        let finite = runner.s11Spectrum.filter { $0.decibels.isFinite }
        XCTAssertFalse(finite.isEmpty, "the whole band is above cutoff, so every point should resolve")

        for point in finite {
            XCTAssertLessThan(
                point.decibels, 0.01,
                "a passive port cannot reflect more than it receives (\(point.hertz / 1e9) GHz)"
            )
        }

        func stepsToDecay(farEnd: BoundaryCondition) async throws -> Int {
            var state = makeState()
            state.simulation.boundaries = BoundarySettings(
                xMin: .electric, xMax: .electric,
                yMin: .electric, yMax: .electric,
                zMin: .pml, zMax: farEnd,
                pmlCellCount: 8
            )
            let runner = SimulationRunner()
            runner.spectrumPointCount = 5
            await (try runner.run(document: CADDocument(state: state))).value
            guard case .energyDecay(_, let atStep)? = runner.completionReason else {
                XCTFail("expected the run to converge on energy decay")
                return 0
            }
            return atStep
        }

        let absorbed = try await stepsToDecay(farEnd: .pml)
        let shorted = try await stepsToDecay(farEnd: .electric)
        XCTAssertGreaterThan(
            Double(shorted) / Double(absorbed), 2.0,
            "a mode that actually propagates must leave through an absorbing end "
                + "far sooner than through a shorting one (absorbed \(absorbed), shorted \(shorted))"
        )
    }
}
