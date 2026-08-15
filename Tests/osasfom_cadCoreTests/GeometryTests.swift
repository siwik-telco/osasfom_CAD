import XCTest

@testable import osasfom_cadCore

final class GeometryTests: XCTestCase {
    private func makeResolvedBody(
        shape: ResolvedShape,
        position: Vec3 = .zero,
        rotationDegrees: Vec3 = .zero,
        scale: Vec3 = .one
    ) -> ResolvedBody {
        ResolvedBody(
            id: UUID(),
            name: "Test",
            shape: shape,
            position: position,
            rotationDegrees: rotationDegrees,
            scale: scale,
            materialID: MaterialLibrary.vacuumID,
            priority: 0,
            isVisible: true,
            orderIndex: 0
        )
    }

    // MARK: - Rotated bounding boxes

    func testUnrotatedBoundsMatchTheExtents() {
        let body = makeResolvedBody(
            shape: .box(size: Vec3(x: 40, y: 10, z: 30)),
            position: Vec3(x: 5, y: 0, z: -2)
        )
        let bounds = body.axisAlignedBounds
        XCTAssertEqual(bounds.xMin, -15)
        XCTAssertEqual(bounds.xMax, 25)
        XCTAssertEqual(bounds.yMin, -5)
        XCTAssertEqual(bounds.yMax, 5)
        XCTAssertTrue(body.isAxisAligned)
    }

    /// The old implementation ignored rotation, so a rotated body reported a box
    /// that did not contain it.
    func testRotationGrowsTheBoundingBox() {
        let body = makeResolvedBody(
            shape: .box(size: Vec3(x: 10, y: 2, z: 10)),
            rotationDegrees: Vec3(x: 0, y: 45, z: 0)
        )
        let bounds = body.axisAlignedBounds
        let expected = 10 * (2.0).squareRoot() / 2

        XCTAssertEqual(bounds.xMax, expected, accuracy: 1e-9)
        XCTAssertEqual(bounds.zMax, expected, accuracy: 1e-9)
        XCTAssertEqual(bounds.yMax, 1, accuracy: 1e-9, "the rotation axis is unaffected")
        XCTAssertFalse(body.isAxisAligned)
        XCTAssertGreaterThan(bounds.size.x, body.scaledSize.x)
    }

    func testNinetyDegreeRotationSwapsExtents() {
        let body = makeResolvedBody(
            shape: .box(size: Vec3(x: 10, y: 2, z: 4)),
            rotationDegrees: Vec3(x: 0, y: 90, z: 0)
        )
        let size = body.axisAlignedBounds.size
        XCTAssertEqual(size.x, 4, accuracy: 1e-9)
        XCTAssertEqual(size.y, 2, accuracy: 1e-9)
        XCTAssertEqual(size.z, 10, accuracy: 1e-9)
    }

    func testBoundingBoxAlwaysContainsTheRotatedBody() {
        let shape = ResolvedShape.box(size: Vec3(x: 7, y: 3, z: 11))
        for angle in stride(from: 0.0, to: 360.0, by: 17.0) {
            let body = makeResolvedBody(
                shape: shape,
                position: Vec3(x: 2, y: -1, z: 4),
                rotationDegrees: Vec3(x: angle, y: angle / 2, z: angle / 3)
            )
            let bounds = body.axisAlignedBounds
            let matrix = body.rotationMatrix
            for corner in BodyBounds.corners(halfExtent: body.scaledSize / 2) {
                let world = matrix.apply(to: corner) + body.position
                XCTAssertGreaterThanOrEqual(world.x, bounds.xMin - 1e-9)
                XCTAssertLessThanOrEqual(world.x, bounds.xMax + 1e-9)
                XCTAssertGreaterThanOrEqual(world.y, bounds.yMin - 1e-9)
                XCTAssertLessThanOrEqual(world.y, bounds.yMax + 1e-9)
                XCTAssertGreaterThanOrEqual(world.z, bounds.zMin - 1e-9)
                XCTAssertLessThanOrEqual(world.z, bounds.zMax + 1e-9)
            }
        }
    }

    func testScaleAffectsExtents() {
        let body = makeResolvedBody(
            shape: .box(size: Vec3(x: 10, y: 10, z: 10)),
            scale: Vec3(x: 2, y: 0.5, z: -1)
        )
        let size = body.axisAlignedBounds.size
        XCTAssertEqual(size.x, 20)
        XCTAssertEqual(size.y, 5)
        XCTAssertEqual(size.z, 10, "a negative scale mirrors but does not shrink")
    }

    // MARK: - Shape extents

    func testCylinderLocalSizeFollowsItsAxis() {
        for axis in Axis.allCases {
            let shape = ResolvedShape.cylinder(radius: 2, length: 30, axis: axis)
            let size = shape.localSize
            XCTAssertEqual(size[axis], 30)
            let (first, second) = axis.perpendicular
            XCTAssertEqual(size[first], 4)
            XCTAssertEqual(size[second], 4)
        }
    }

    func testZeroThicknessSheetKeepsItsDegenerateAxis() {
        let shape = ResolvedShape.sheet(size: Vec3(x: 10, y: 0, z: 20), normal: .y)
        XCTAssertEqual(shape.degenerateAxis, .y)
        XCTAssertEqual(shape.localSize.y, 0, "a zero-thickness PEC sheet must stay zero")
    }

    // MARK: - Bounds editability

    func testBoundsEditabilityRules() {
        let box = makeResolvedBody(shape: .box(size: Vec3(repeating: 1)))
        XCTAssertEqual(box.boundsEditability, .editable)

        let rotated = makeResolvedBody(
            shape: .box(size: Vec3(repeating: 1)),
            rotationDegrees: Vec3(x: 0, y: 30, z: 0)
        )
        XCTAssertEqual(rotated.boundsEditability, .rotated)

        // A cylinder's radius cannot be recovered from two independent spans, so
        // the editor is refused rather than silently discarding one of them.
        let cylinder = makeResolvedBody(shape: .cylinder(radius: 1, length: 4, axis: .y))
        XCTAssertEqual(cylinder.boundsEditability, .lossyForKind(.cylinder))
    }

    // MARK: - BodyBounds

    func testNormalizedSwapsButNeverWidens() {
        let inverted = BodyBounds(xMin: 5, xMax: 1, yMin: 0, yMax: 0, zMin: -1, zMax: 1)
        let normalized = inverted.normalized()
        XCTAssertEqual(normalized.xMin, 1)
        XCTAssertEqual(normalized.xMax, 5)
        XCTAssertEqual(normalized.yMin, 0)
        XCTAssertEqual(normalized.yMax, 0, "a zero span must not be inflated")
    }

    func testUnionAndContainment() {
        let a = BodyBounds(center: .zero, size: Vec3(repeating: 10))
        let b = BodyBounds(center: Vec3(x: 20, y: 0, z: 0), size: Vec3(repeating: 2))
        let union = a.union(b)
        XCTAssertEqual(union.xMax, 21)
        XCTAssertTrue(union.contains(a))
        XCTAssertTrue(union.contains(b))
        XCTAssertFalse(a.intersects(b))
    }

    // MARK: - Units

    func testUnitConversion() {
        XCTAssertEqual(LengthUnit.millimeter.toMeters(1.6), 0.0016, accuracy: 1e-12)
        XCTAssertEqual(LengthUnit.inch.toMeters(1), 0.0254, accuracy: 1e-12)
        XCTAssertEqual(LengthUnit.mil.toMeters(1000), 0.0254, accuracy: 1e-12)

        let wavelength = LengthUnit.millimeter.wavelength(atHertz: 2.45e9)
        XCTAssertEqual(try XCTUnwrap(wavelength), 122.36, accuracy: 0.01)
    }
}
