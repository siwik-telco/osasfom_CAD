import XCTest
@testable import osasfom_cadCore

final class STLExporterTests: XCTestCase {

    // MARK: - Winding / outward-normal correctness

    /// Every triangle's winding must produce a normal pointing away from the
    /// shape's own center — get this backwards and the STL "looks" fine in
    /// many viewers (which patch it up) but silently has inverted normals
    /// that some importers (CST included) will refuse or misinterpret.
    func testBoxTrianglesHaveOutwardNormals() {
        let size = Vec3(x: 4, y: 6, z: 8)
        let triangles = STLExporter.boxTriangles(size: size)
        XCTAssertEqual(triangles.count, 12)
        assertAllOutward(triangles, center: .zero)
    }

    func testCylinderTrianglesHaveOutwardNormals() {
        for axis in Axis.allCases {
            let triangles = STLExporter.cylinderTriangles(radius: 3, length: 10, axis: axis, segments: 16)
            // side walls (2) + caps (2) per segment
            XCTAssertEqual(triangles.count, 16 * 4)
            assertAllOutward(triangles, center: .zero, axis: axis)
        }
    }

    private func assertAllOutward(_ triangles: [STLExporter.Triangle], center: Vec3, axis: Axis? = nil) {
        for triangle in triangles {
            let centroid = Vec3(
                x: (triangle.v0.x + triangle.v1.x + triangle.v2.x) / 3,
                y: (triangle.v0.y + triangle.v1.y + triangle.v2.y) / 3,
                z: (triangle.v0.z + triangle.v1.z + triangle.v2.z) / 3
            )
            let normal = STLExporter.faceNormal(triangle)

            let outward: Vec3
            if let axis, abs(centroid[axis]) < 1e-9 {
                // On a cylinder's curved wall (not a cap): outward is radial,
                // not away from the overall center (which lies on the axis).
                var radial = centroid
                radial[axis] = 0
                outward = radial
            } else {
                outward = centroid - center
            }

            let dot = normal.x * outward.x + normal.y * outward.y + normal.z * outward.z
            XCTAssertGreaterThan(dot, 0, "triangle \(triangle) has an inward-facing normal \(normal)")
        }
    }

    // MARK: - Shape coverage

    func testZeroThicknessSheetIsDoubleSided() {
        let triangles = STLExporter.planeTriangles(size: Vec3(x: 10, y: 0, z: 20), normal: .y)
        XCTAssertEqual(triangles.count, 4, "two triangles per side so the sheet is visible from either face")

        let upNormals = triangles.filter { STLExporter.faceNormal($0).y > 0 }
        let downNormals = triangles.filter { STLExporter.faceNormal($0).y < 0 }
        XCTAssertEqual(upNormals.count, 2)
        XCTAssertEqual(downNormals.count, 2)
    }

    func testThickSheetIsTreatedAsABox() {
        let triangles = STLExporter.localTriangles(for: .sheet(size: Vec3(x: 10, y: 2, z: 20), normal: .y), segments: 16)
        XCTAssertEqual(triangles.count, 12)
    }

    // MARK: - World transform

    func testBodyTransformIsApplied() {
        let body = ResolvedBody(
            id: UUID(),
            name: "Box",
            shape: .box(size: Vec3(x: 2, y: 2, z: 2)),
            position: Vec3(x: 100, y: 0, z: 0),
            rotationDegrees: .zero,
            scale: .one,
            materialID: MaterialLibrary.defaultMaterialID,
            priority: 0,
            isVisible: true,
            orderIndex: 0
        )
        let triangles = STLExporter.triangles(for: [body])
        XCTAssertEqual(triangles.count, 12)
        // Every vertex must be centred on the body's world position, not the origin.
        for triangle in triangles {
            for v in [triangle.v0, triangle.v1, triangle.v2] {
                XCTAssertEqual(v.x, 100, accuracy: 1, "expected a vertex near x=100 (offset by half the box), got \(v.x)")
            }
        }
    }

    func testInvisibleBodiesAreExcluded() {
        let visible = ResolvedBody(
            id: UUID(), name: "Visible", shape: .box(size: Vec3(repeating: 1)),
            position: .zero, rotationDegrees: .zero, scale: .one,
            materialID: MaterialLibrary.defaultMaterialID, priority: 0, isVisible: true, orderIndex: 0
        )
        let hidden = ResolvedBody(
            id: UUID(), name: "Hidden", shape: .box(size: Vec3(repeating: 1)),
            position: .zero, rotationDegrees: .zero, scale: .one,
            materialID: MaterialLibrary.defaultMaterialID, priority: 0, isVisible: false, orderIndex: 1
        )
        XCTAssertEqual(STLExporter.triangles(for: [visible, hidden]).count, 12)
    }

    // MARK: - Binary format

    func testBinarySTLHeaderAndTriangleCount() {
        let triangles = STLExporter.boxTriangles(size: Vec3(repeating: 2))
        let data = STLExporter.encodeBinary(triangles)

        XCTAssertEqual(data.count, 80 + 4 + triangles.count * 50)

        let count = data.subdata(in: 80..<84).withUnsafeBytes { $0.load(as: UInt32.self) }
        XCTAssertEqual(UInt32(littleEndian: count), UInt32(triangles.count))
    }

    func testBinarySTLFirstTriangleRoundTrips() {
        let triangle = STLExporter.Triangle(
            v0: Vec3(x: 1, y: 2, z: 3),
            v1: Vec3(x: 4, y: 5, z: 6),
            v2: Vec3(x: 7, y: 8, z: 9)
        )
        let data = STLExporter.encodeBinary([triangle])
        let recordStart = 84

        func float(at offset: Int) -> Float {
            data.subdata(in: recordStart + offset..<recordStart + offset + 4)
                .withUnsafeBytes { Float(bitPattern: UInt32(littleEndian: $0.load(as: UInt32.self))) }
        }

        // Bytes 0-11 are the normal (already covered by the winding tests);
        // bytes 12-47 are the three vertices in order.
        XCTAssertEqual(float(at: 12), 1, accuracy: 1e-5)
        XCTAssertEqual(float(at: 16), 2, accuracy: 1e-5)
        XCTAssertEqual(float(at: 20), 3, accuracy: 1e-5)
        XCTAssertEqual(float(at: 24), 4, accuracy: 1e-5)
        XCTAssertEqual(float(at: 44), 9, accuracy: 1e-5)
    }
}
