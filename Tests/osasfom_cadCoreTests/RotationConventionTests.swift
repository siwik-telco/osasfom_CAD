import XCTest

@testable import osasfom_cadCore

/// Locks down the Euler convention.
///
/// Core computes bounding boxes with `Matrix3.euler` while the renderer hands
/// the same angles to `SCNNode.eulerAngles`. If the two ever disagree, bounding
/// boxes drift silently away from what is drawn, so the convention is pinned
/// here: components are pitch (X), yaw (Y), roll (Z), applied Z then Y then X,
/// giving `Rx * Ry * Rz`.
final class RotationConventionTests: XCTestCase {
    private func assertMaps(
        _ matrix: Matrix3,
        _ input: Vec3,
        to expected: Vec3,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let result = matrix.apply(to: input)
        XCTAssertEqual(result.x, expected.x, accuracy: 1e-12, file: file, line: line)
        XCTAssertEqual(result.y, expected.y, accuracy: 1e-12, file: file, line: line)
        XCTAssertEqual(result.z, expected.z, accuracy: 1e-12, file: file, line: line)
    }

    func testIdentity() {
        let matrix = Matrix3.euler(degrees: .zero)
        for axis in Axis.allCases {
            assertMaps(matrix, axis.unitVector, to: axis.unitVector)
        }
    }

    func testSingleAxisRotationsAreRightHanded() {
        // +90° about X takes +Y to +Z.
        assertMaps(
            Matrix3.euler(degrees: Vec3(x: 90, y: 0, z: 0)),
            Vec3(x: 0, y: 1, z: 0),
            to: Vec3(x: 0, y: 0, z: 1)
        )
        // +90° about Y takes +Z to +X.
        assertMaps(
            Matrix3.euler(degrees: Vec3(x: 0, y: 90, z: 0)),
            Vec3(x: 0, y: 0, z: 1),
            to: Vec3(x: 1, y: 0, z: 0)
        )
        // +90° about Z takes +X to +Y.
        assertMaps(
            Matrix3.euler(degrees: Vec3(x: 0, y: 0, z: 90)),
            Vec3(x: 1, y: 0, z: 0),
            to: Vec3(x: 0, y: 1, z: 0)
        )
    }

    func testCompositionOrderIsRollThenYawThenPitch() {
        // With R = Rx * Ry * Rz, applying (90, 90, 0) to +X gives Rx(Ry(+X)).
        // Ry(90) takes +X to -Z, then Rx(90) takes -Z to +Y.
        assertMaps(
            Matrix3.euler(degrees: Vec3(x: 90, y: 90, z: 0)),
            Vec3(x: 1, y: 0, z: 0),
            to: Vec3(x: 0, y: 1, z: 0)
        )
    }

    /// The renderer orients a Y-aligned `SCNCylinder` onto the body's axis with
    /// `Axis.rotationFromYAxisDegrees`; these are the mappings it relies on.
    func testCylinderAxisRotations() {
        for axis in Axis.allCases {
            let matrix = Matrix3.euler(degrees: axis.rotationFromYAxisDegrees)
            assertMaps(matrix, Vec3(x: 0, y: 1, z: 0), to: axis.unitVector)
        }
    }

    /// The renderer draws a zero-thickness sheet as an `SCNPlane`, which lies in
    /// its local XY plane facing +Z. These triples must carry (plane X, plane Y,
    /// plane normal) onto (perpendicular.0, perpendicular.1, normal).
    func testSheetPlaneOrientations() {
        let quarter = 90.0
        let orientations: [Axis: Vec3] = [
            .z: .zero,
            .y: Vec3(x: -quarter, y: 0, z: -quarter),
            .x: Vec3(x: 0, y: quarter, z: quarter)
        ]

        for (normal, angles) in orientations {
            let matrix = Matrix3.euler(degrees: angles)
            let (first, second) = normal.perpendicular

            assertMaps(matrix, Vec3(x: 1, y: 0, z: 0), to: first.unitVector)
            assertMaps(matrix, Vec3(x: 0, y: 1, z: 0), to: second.unitVector)
            assertMaps(matrix, Vec3(x: 0, y: 0, z: 1), to: normal.unitVector)
        }
    }

    func testRotationMatricesAreOrthonormal() {
        for angles in [
            Vec3(x: 13, y: 47, z: 91),
            Vec3(x: -120, y: 5, z: 200),
            Vec3(x: 360, y: 0, z: -45)
        ] {
            let matrix = Matrix3.euler(degrees: angles)
            let columns = [matrix.columns.0, matrix.columns.1, matrix.columns.2]
            for column in columns {
                let length = (column.x * column.x + column.y * column.y + column.z * column.z)
                    .squareRoot()
                XCTAssertEqual(length, 1, accuracy: 1e-12)
            }
            // Pairwise orthogonal.
            for i in 0..<3 {
                for j in (i + 1)..<3 {
                    let a = columns[i]
                    let b = columns[j]
                    XCTAssertEqual(a.x * b.x + a.y * b.y + a.z * b.z, 0, accuracy: 1e-12)
                }
            }
        }
    }
}
