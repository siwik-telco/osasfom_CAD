import SceneKit
import XCTest
import osasfom_cadCore

@testable import osasfom_cadRender

/// Orientation of a primitive's own mesh inside its body node.
///
/// Written after an X- or Z-aligned cylinder drew at 116.6° instead of 90°:
/// the degrees from `Axis.rotationFromYAxisDegrees` were handed to
/// `SCNNode.eulerAngles`, which is radians, so 90 wrapped to 2.035 rad. It
/// went unnoticed because the default cylinder is Y-aligned, whose rotation
/// is zero in either unit.
final class IntrinsicRotationTests: XCTestCase {

    private func rotation(forCylinderOn axis: Axis) -> SCNVector3 {
        SceneGeometryFactory.intrinsicRotation(for: .cylinder(radius: 1, begin: -5, end: 5, axis: axis))
    }

    private let quarterTurn = Double.pi / 2

    // MARK: - Units

    func testCylinderRotationIsInRadiansNotDegrees() {
        let onZ = rotation(forCylinderOn: .z)
        XCTAssertEqual(Double(onZ.x), quarterTurn, accuracy: 1e-12)
        XCTAssertEqual(Double(onZ.y), 0, accuracy: 1e-12)
        XCTAssertEqual(Double(onZ.z), 0, accuracy: 1e-12)

        let onX = rotation(forCylinderOn: .x)
        XCTAssertEqual(Double(onX.z), -quarterTurn, accuracy: 1e-12)
    }

    /// The specific symptom: anything near 90 means degrees leaked through.
    func testNoComponentIsADegreeValue() {
        for axis in Axis.allCases {
            let r = rotation(forCylinderOn: axis)
            for component in [Double(r.x), Double(r.y), Double(r.z)] {
                XCTAssertLessThanOrEqual(
                    abs(component), 2 * Double.pi,
                    "\(axis) got \(component) — a Euler angle this large is degrees, not radians"
                )
            }
        }
    }

    func testAYAlignedCylinderNeedsNoRotation() {
        let r = rotation(forCylinderOn: .y)
        XCTAssertEqual(Double(r.x), 0)
        XCTAssertEqual(Double(r.y), 0)
        XCTAssertEqual(Double(r.z), 0)
    }

    // MARK: - Direction

    /// The rotation must actually carry SceneKit's +Y cylinder onto the
    /// chosen axis — right magnitude, right sign.
    func testRotationCarriesTheMeshOntoTheChosenAxis() {
        for axis in Axis.allCases {
            let r = rotation(forCylinderOn: axis)
            let matrix = Matrix3.euler(
                degrees: Vec3(
                    x: Double(r.x) * 180 / .pi,
                    y: Double(r.y) * 180 / .pi,
                    z: Double(r.z) * 180 / .pi
                )
            )
            let pointed = matrix.apply(to: Vec3(x: 0, y: 1, z: 0))
            XCTAssertEqual(
                abs(pointed[axis]), 1, accuracy: 1e-9,
                "a \(axis)-aligned cylinder must end up along \(axis), got \(pointed)"
            )
        }
    }

    // MARK: - The boolean path

    /// A body with a boolean history is drawn from a CSG mesh built in its own
    /// frame with the axis already baked in, so it must not be turned again —
    /// which is why adding a cylinder to another body made it look right while
    /// the standalone one was tilted.
    func testABodyWithBooleansIsNotRotatedAgain() {
        let tool = ResolvedBooleanOperation(
            id: UUID(),
            kind: .add,
            shape: .box(size: Vec3(repeating: 2)),
            position: .zero,
            rotationDegrees: .zero,
            scale: .one
        )
        let body = ResolvedBody(
            id: UUID(),
            name: "Boom",
            shape: .cylinder(radius: 1, begin: -5, end: 5, axis: .x),
            position: .zero,
            rotationDegrees: .zero,
            scale: .one,
            materialID: MaterialLibrary.pecID,
            priority: 0,
            isVisible: true,
            orderIndex: 0,
            booleans: [tool]
        )

        let r = SceneGeometryFactory.intrinsicRotation(for: body)
        XCTAssertEqual(Double(r.x), 0)
        XCTAssertEqual(Double(r.y), 0)
        XCTAssertEqual(Double(r.z), 0)
    }
}
