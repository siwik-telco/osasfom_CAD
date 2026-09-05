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
}
