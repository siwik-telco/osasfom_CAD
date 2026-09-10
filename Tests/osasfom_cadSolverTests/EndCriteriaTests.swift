import XCTest
import osasfom_cadCore
@testable import osasfom_cadSolver

/// The end criterion: stop once residual field energy has decayed by the
/// requested number of dB below its peak, rather than always burning the full
/// step cap.
///
/// `energyDecayDecibels` existed as a setting, was written into the solver
/// deck, and was read by nobody — every run went the full `maximumTimeSteps`.
/// That is not only slow: a step-capped run gives no signal about whether the
/// time series was long enough for the DFT behind S11, which assumes the
/// fields have rung down. These cover both halves — that it fires, and that it
/// cannot fire for the wrong reason.
final class EndCriteriaTests: XCTestCase {

    private func makeState(
        decayDb: Double = -40,
        maximumTimeSteps: Int = 60_000,
        waveform: ExcitationWaveform = .gaussianPulse
    ) -> CADModelState {
        var state = CADModelState(name: "Dipole", lengthUnit: .millimeter)
        let armLength = 56.0, gap = 6.0, radius = 3.0

        state.bodies = [
            CADBody(
                name: "Arm+Y",
                primitive: .cylinder(
                    CylinderSpec(
                        radius: Expression(radius),
                        begin: Expression(gap / 2),
                        end: Expression(gap / 2 + armLength),
                        axis: .y
                    )
                ),
                materialID: MaterialLibrary.pecID
            ),
            CADBody(
                name: "Arm-Y",
                primitive: .cylinder(
                    CylinderSpec(
                        radius: Expression(radius),
                        begin: Expression(-(gap / 2 + armLength)),
                        end: Expression(-gap / 2),
                        axis: .y
                    )
                ),
                materialID: MaterialLibrary.pecID
            )
        ]
        state.simulation.domain = DomainSettings(mode: .automatic, padding: Vector3Expression(Vec3(repeating: 62)))
        state.simulation.frequency = FrequencyRange(minimumHertz: 0.8e9, maximumHertz: 2.0e9)
        state.simulation.mesh = MeshSettings(cellsPerWavelength: 10)
        state.simulation.excitation.waveform = waveform
        state.simulation.ports = [
            SimulationPort(
                name: "Feed",
                begin: Vector3Expression(x: Expression(0), y: Expression(-gap / 2), z: Expression(0)),
                end: Vector3Expression(x: Expression(0), y: Expression(gap / 2), z: Expression(0)),
                direction: .y,
                impedanceOhm: 50
            )
        ]
        state.simulation.solver.energyDecayDecibels = decayDb
        state.simulation.solver.maximumTimeSteps = maximumTimeSteps
        return state
    }

    @MainActor
    private func run(_ state: CADModelState) async throws -> SimulationRunner {
        let runner = SimulationRunner()
        runner.spectrumPointCount = 5
        await (try runner.run(document: CADDocument(state: state))).value
        return runner
    }

    // MARK: - Excitation length

    /// The domain starts empty, so a decay test taken before the source has
    /// finished driving would end the run at step one. Only a pulse has an
    /// end; a continuous source must report none.
    func testOnlyAPulseHasAFiniteExcitationLength() {
        let frequency = FrequencyRange(minimumHertz: 0.8e9, maximumHertz: 2.0e9)

        let pulse = ExcitationWaveformSampler.excitationDurationSeconds(
            excitation: Excitation(waveform: .gaussianPulse),
            frequency: frequency
        )
        XCTAssertNotNil(pulse)
        XCTAssertGreaterThan(try XCTUnwrap(pulse), 0)

        for waveform in [ExcitationWaveform.sinusoidal, .step] {
            XCTAssertNil(
                ExcitationWaveformSampler.excitationDurationSeconds(
                    excitation: Excitation(waveform: waveform),
                    frequency: frequency
                ),
                "\(waveform) never stops driving, so it has no decay to wait for"
            )
        }
    }

    /// The reported length must actually cover the waveform
    /// `value(excitation:frequency:timeSeconds:)` generates. If the two drift
    /// apart the criterion either fires into a still-live source or waits far
    /// longer than it needs to — this caught exactly that, the first version
    /// stopped at 6σ with the pulse still at ~1% of peak.
    func testExcitationLengthCoversThePulse() throws {
        let frequency = FrequencyRange(minimumHertz: 0.8e9, maximumHertz: 2.0e9)
        let excitation = Excitation(waveform: .gaussianPulse)
        let duration = try XCTUnwrap(
            ExcitationWaveformSampler.excitationDurationSeconds(excitation: excitation, frequency: frequency)
        )

        let peak = (0...200)
            .map { ExcitationWaveformSampler.value(
                excitation: excitation,
                frequency: frequency,
                timeSeconds: duration * Double($0) / 200
            ) }
            .map(abs)
            .max() ?? 0
        let atEnd = abs(
            ExcitationWaveformSampler.value(excitation: excitation, frequency: frequency, timeSeconds: duration)
        )
        XCTAssertLessThan(atEnd, peak * 1e-3, "the pulse must be spent by the reported duration")
    }

    // MARK: - The criterion

    /// The point of the whole feature: a broadband dipole rings down quickly,
    /// so it must converge well short of the step cap instead of burning it.
    @MainActor
    func testRunConvergesOnEnergyDecayBeforeTheStepCap() async throws {
        let runner = try await run(makeState(decayDb: -40, maximumTimeSteps: 60_000))

        let reason = try XCTUnwrap(runner.completionReason)
        guard case .energyDecay(let decibels, let atStep) = reason else {
            return XCTFail("expected .energyDecay, got \(reason) — \(reason.summary)")
        }
        XCTAssertLessThanOrEqual(decibels, -40, "must not stop above the requested decay")
        XCTAssertGreaterThan(atStep, 0)
        XCTAssertLessThan(atStep, 60_000, "the whole point is to finish early")
        XCTAssertTrue(reason.didConverge)
        XCTAssertFalse(runner.s11Spectrum.isEmpty)
    }

    /// A tight criterion the run cannot reach must be reported as such rather
    /// than passing quietly — this is the case openEMS warns about, where the
    /// spectrum is truncated and carries leakage.
    @MainActor
    func testHittingTheStepCapIsReportedAsNotConverged() async throws {
        // -1000 dB is unreachable in double precision, which makes this
        // deterministic: pinning it on a small step cap instead would depend
        // on the mesh's dT and the pulse length lining up a certain way.
        let runner = try await run(makeState(decayDb: -1000, maximumTimeSteps: 600))

        let reason = try XCTUnwrap(runner.completionReason)
        guard case .stepCapReached(let decibels) = reason else {
            return XCTFail("expected .stepCapReached, got \(reason)")
        }
        XCTAssertFalse(reason.didConverge)
        XCTAssertNotNil(decibels, "a pulse run still reports how far it got")
        XCTAssertTrue(reason.summary.contains("step cap"))
    }

    /// A source that never stops driving has no decay to wait for. Its energy
    /// plateaus, so the criterion must stand down and let the step cap end the
    /// run — not fire on a dip in a steady state.
    @MainActor
    func testContinuousExcitationFallsBackOnTheStepCap() async throws {
        let runner = try await run(makeState(decayDb: -40, maximumTimeSteps: 600, waveform: .sinusoidal))

        let reason = try XCTUnwrap(runner.completionReason)
        guard case .stepCapReached(let decibels) = reason else {
            return XCTFail("expected .stepCapReached, got \(reason)")
        }
        XCTAssertNil(decibels, "no decay criterion applies to a source that never stops")
        XCTAssertNil(runner.energyDecayDb)
    }

    /// A stricter target must be honoured, and can never be reached sooner
    /// than a looser one. This is the knob a high-Q structure needs, so it has
    /// to bite rather than be nominally wired up.
    ///
    /// The assertion is monotonic rather than strict on purpose: energy is
    /// only sampled every `chunk` steps, and a fast-decaying model can fall
    /// through both thresholds inside one interval — which this fixture does,
    /// dropping past -45 dB in a single check.
    @MainActor
    func testStricterDecayIsHonouredAndNeverReachedSooner() async throws {
        let loose = try await run(makeState(decayDb: -20, maximumTimeSteps: 60_000))
        let tight = try await run(makeState(decayDb: -45, maximumTimeSteps: 60_000))

        guard case .energyDecay(let looseDb, let looseStep) = try XCTUnwrap(loose.completionReason),
              case .energyDecay(let tightDb, let tightStep) = try XCTUnwrap(tight.completionReason) else {
            return XCTFail("both runs were expected to converge")
        }

        // Each run must actually satisfy the target it was given — the check
        // that would catch a flipped comparison.
        XCTAssertLessThanOrEqual(looseDb, -20)
        XCTAssertLessThanOrEqual(tightDb, -45)
        XCTAssertGreaterThanOrEqual(tightStep, looseStep, "-45 dB cannot be reached before -20 dB")
    }

    // MARK: - Energy

    /// Energy is only ever used as a ratio against its own peak, but it still
    /// has to behave like energy: zero in a quiescent domain, positive once
    /// the fields are excited.
    func testEnergyIsZeroBeforeExcitationAndPositiveAfter() throws {
        let state = makeState()
        let resolved = ModelResolver.resolve(state)
        let lines = try XCTUnwrap(
            GridMesher.makeDiscLines(resolved: resolved, setup: state.simulation, unit: state.lengthUnit)
        )

        let op = Operator()
        op.setupGrid(discLines: lines.metersLines, gridDeltaUnit: 1.0)
        op.materialProvider = CADMaterialProvider(
            bodies: resolved.bodies,
            materials: state.materials,
            unit: state.lengthUnit
        )
        op.calcECOperator()

        let engine = Engine.make(op: op)
        XCTAssertEqual(engine.calcEnergy(), 0, "an unexcited domain holds nothing")

        engine.setVolt(1, 4, 4, 4, 2.0)
        XCTAssertEqual(engine.calcEnergy(), 4.0, accuracy: 1e-12, "sum of squares over the field arrays")
    }
}
