import XCTest
import osasfom_cadCore
@testable import osasfom_cadSolver

/// A boolean is only real if the physics sees it. These go through the same
/// path a run does — resolve the document, build the material provider the
/// operator uses, and sample it — rather than testing the geometry in
/// isolation.
@MainActor
final class BooleanMaterialTests: XCTestCase {

    private func makeProvider(_ state: CADModelState) -> (CADMaterialProvider, ResolvedModel) {
        let resolved = CADDocument(state: state).resolved
        XCTAssertEqual(resolved.diagnostics.errors.count, 0, "\(resolved.diagnostics.errors)")
        return (
            CADMaterialProvider(bodies: resolved.bodies, materials: state.materials, unit: state.lengthUnit),
            resolved
        )
    }

    /// Conductivity at a point, in S/m. `matType: 1` is electric conductivity;
    /// coordinates reach the provider in metres.
    private func sigma(_ provider: CADMaterialProvider, _ millimetres: Vec3) -> Double {
        provider.material(
            direction: 2,
            coords: (millimetres.x / 1000, millimetres.y / 1000, millimetres.z / 1000),
            matType: 1
        )
    }

    private func plate(booleans: [BooleanOperation]) -> CADModelState {
        var state = CADModelState(name: "Booleans", lengthUnit: .millimeter)
        state.bodies = [
            CADBody(
                name: "plate",
                primitive: .box(BoxSpec(
                    beginX: Expression(-10), endX: Expression(10),
                    beginY: Expression(-10), endY: Expression(10),
                    beginZ: Expression(0), endZ: Expression(2)
                )),
                materialID: MaterialLibrary.copperID,
                booleans: booleans
            )
        ]
        return state
    }

    func testSubtractedHoleReadsAsVacuumToTheSolver() {
        let drill = BooleanOperation(
            kind: .subtract,
            primitive: .cylinder(
                CylinderSpec(radius: Expression(3), begin: Expression(-5), end: Expression(5), axis: .z)
            )
        )
        let (provider, _) = makeProvider(plate(booleans: [drill]))

        XCTAssertEqual(sigma(provider, Vec3(x: 0, y: 0, z: 1)), 0, "the drilled hole must be empty")
        XCTAssertGreaterThan(sigma(provider, Vec3(x: 8, y: 0, z: 1)), 1e6, "the surrounding copper is untouched")
    }

    func testAddedToolBringsItsParentBodysMaterialWithIt() {
        let boss = BooleanOperation(
            kind: .add,
            primitive: .box(BoxSpec(
                beginX: Expression(12), endX: Expression(16),
                beginY: Expression(-2), endY: Expression(2),
                beginZ: Expression(0), endZ: Expression(2)
            ))
        )
        let (provider, resolved) = makeProvider(plate(booleans: [boss]))

        XCTAssertGreaterThan(sigma(provider, Vec3(x: 14, y: 0, z: 1)), 1e6, "the added volume is copper too")

        // And the mesher has to know the body reaches out there now.
        let bounds = try? XCTUnwrap(resolved.bodies.first).axisAlignedBounds
        XCTAssertEqual(bounds?.xMax, 16, "bounds must grow to cover an added tool")
    }

    func testDisabledStepIsIgnored() {
        var drill = BooleanOperation(
            kind: .subtract,
            primitive: .cylinder(
                CylinderSpec(radius: Expression(3), begin: Expression(-5), end: Expression(5), axis: .z)
            )
        )
        drill.isEnabled = false
        let (provider, _) = makeProvider(plate(booleans: [drill]))

        XCTAssertGreaterThan(sigma(provider, Vec3(x: 0, y: 0, z: 1)), 1e6, "a switched-off step must not cut")
    }

    /// The cut has to land on grid lines, or the solver resolves a hole in a
    /// different place than the model has one.
    func testMeshSnapsGridLinesToTheToolsEdges() throws {
        let drill = BooleanOperation(
            kind: .subtract,
            primitive: .box(BoxSpec(
                beginX: Expression(-3), endX: Expression(3),
                beginY: Expression(-3), endY: Expression(3),
                beginZ: Expression(-1), endZ: Expression(3)
            ))
        )
        var state = plate(booleans: [drill])
        state.simulation.domain = DomainSettings(mode: .automatic, padding: Vector3Expression(Vec3(repeating: 20)))
        state.simulation.frequency = FrequencyRange(minimumHertz: 1e9, maximumHertz: 2e9)

        let resolved = CADDocument(state: state).resolved
        let lines = try XCTUnwrap(
            GridMesher.makeDiscLines(resolved: resolved, setup: state.simulation, unit: .millimeter)
        )

        // x = ±3 mm are the tool's own faces.
        for edge in [-0.003, 0.003] {
            XCTAssertTrue(
                lines.metersLines[0].contains { abs($0 - edge) < 1e-12 },
                "expected a grid line on the cut face at \(edge) m"
            )
        }
    }
}
