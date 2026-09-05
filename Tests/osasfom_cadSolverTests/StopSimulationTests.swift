import XCTest
import osasfom_cadCore
@testable import osasfom_cadSolver

/// Regression test for the Stop button: calling `stop()` mid-run should end
/// the run promptly (not just "eventually," which would defeat the point of
/// a stop button) and still leave a usable, flagged-as-partial spectrum.
final class StopSimulationTests: XCTestCase {

    @MainActor
    func testStopEndsTheRunAndFlagsThePartialResult() async throws {
        var state = CADModelState(name: "Dipole", lengthUnit: .millimeter)
        let armLength = 56.0, gap = 6.0, radius = 3.0

        let topArm = CADBody(
            name: "Arm+Y",
            primitive: .cylinder(
                CylinderSpec(radius: Expression(radius), begin: Expression(gap / 2), end: Expression(gap / 2 + armLength), axis: .y)
            ),
            materialID: MaterialLibrary.pecID
        )
        let bottomArm = CADBody(
            name: "Arm-Y",
            primitive: .cylinder(
                CylinderSpec(radius: Expression(radius), begin: Expression(-(gap / 2 + armLength)), end: Expression(-gap / 2), axis: .y)
            ),
            materialID: MaterialLibrary.pecID
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
        // A large step count that would run for a while if never stopped —
        // the test only passes if `stop()` actually cuts it short.
        state.simulation.solver.maximumTimeSteps = 500_000

        let document = CADDocument(state: state)
        let runner = SimulationRunner()
        let task = try runner.run(document: document)

        XCTAssertTrue(runner.isRunning)
        runner.stop()
        await task.value

        XCTAssertFalse(runner.isRunning)
        XCTAssertTrue(runner.wasStoppedEarly)
        XCTAssertLessThan(runner.progress, 1.0, "a stopped run should not have completed all steps")
    }
}
