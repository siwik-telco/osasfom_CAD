import XCTest
import osasfom_cadCore
@testable import osasfom_cadSolver

/// End-to-end test: build a half-wave dipole with a lumped feed entirely
/// through the public CAD model, run it through the FDTD bridge, and check
/// that the resulting return loss actually shows a resonance — the first
/// concrete goal for the solver.
final class DipoleReturnLossTests: XCTestCase {

    @MainActor
    func testHalfWaveDipoleShowsAReturnLossDip() async throws {
        var state = CADModelState(name: "Dipole", lengthUnit: .millimeter)

        // A fairly fat dipole (radius/length ~ 1/20) so the mesh stays coarse
        // enough for a fast test — this shifts the resonance somewhat lower
        // than the classic thin-wire half-wave formula, which is fine: the
        // test only checks that *a* resonance shows up, not its exact value.
        let armLength = 56.0     // mm, each arm
        let gap = 6.0            // mm, feed gap
        let radius = 3.0         // mm

        let topArm = CADBody(
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
        )
        let bottomArm = CADBody(
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
        state.bodies = [topArm, bottomArm]

        state.simulation.domain = DomainSettings(
            mode: .automatic,
            padding: Vector3Expression(Vec3(repeating: 62))
        )
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
        // Small enough to keep the test fast; large enough for the pulse to
        // radiate out through the absorbing boundary and mostly decay.
        state.simulation.solver.maximumTimeSteps = 15000

        let document = CADDocument(state: state)
        XCTAssertEqual(document.resolved.diagnostics.errors.count, 0, "\(document.resolved.diagnostics.errors)")

        let runner = SimulationRunner()
        runner.spectrumPointCount = 25
        let task = try runner.run(document: document)
        await task.value

        XCTAssertFalse(runner.isRunning)
        XCTAssertFalse(runner.s11Spectrum.isEmpty)

        // No point may show gain: a passive one-port can never reflect more
        // power than it receives. This is the regression guard for the
        // current-direction sign bug found while building this test (an
        // inverted port current silently produced |S11| > 1 everywhere).
        for point in runner.s11Spectrum {
            XCTAssertLessThanOrEqual(point.decibels, 0.01, "S11 > 0 dB at \(point.hertz / 1e9) GHz is non-physical for a passive port")
        }

        let deepestPoint = try XCTUnwrap(runner.s11Spectrum.min { $0.decibels < $1.decibels })

        // A resonant dipole should show a clear dip in |S11|. -3 dB is a
        // lenient bar (half-power point) appropriate for the coarse mesh and
        // approximate (non-PML) absorbing boundary this MVP solver uses.
        XCTAssertLessThan(
            deepestPoint.decibels,
            -3,
            "expected a return-loss dip below -3 dB somewhere in the swept band, deepest was \(deepestPoint.decibels) dB at \(deepestPoint.hertz / 1e9) GHz"
        )
    }
}
