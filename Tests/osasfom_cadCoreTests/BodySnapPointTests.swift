import XCTest

@testable import osasfom_cadCore

/// The face/edge picker used to snap ports to a body's surface — rewritten
/// after the bounding-box approximation gave wrong results for a cylinder's
/// curved side and for rotated bodies. These tests exercise the actual
/// geometry, not just "it compiles."
final class BodySnapPointTests: XCTestCase {
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

    private func assertVec3(_ a: Vec3, _ b: Vec3, accuracy: Double = 1e-9, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, "x", file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, "y", file: file, line: line)
        XCTAssertEqual(a.z, b.z, accuracy: accuracy, "z", file: file, line: line)
    }

    // MARK: - Box: face center and edge midpoints

    func testBoxClickNearFaceCenterSnapsToCenter() {
        let body = makeResolvedBody(shape: .box(size: Vec3(x: 10, y: 20, z: 30)), position: Vec3(x: 100, y: 0, z: 0))
        // Click near the middle of the +X face (world x = 100 + 5 = 105).
        let snap = BodySnapPoint.nearest(on: body, to: Vec3(x: 105, y: 1, z: 1))
        assertVec3(snap, Vec3(x: 105, y: 0, z: 0))
    }

    func testBoxClickNearAnEdgeSnapsToThatEdgeMidpoint() {
        let body = makeResolvedBody(shape: .box(size: Vec3(x: 10, y: 20, z: 30)))
        // On the +X face (x=5), close to the +Y edge (y=10) but not the +Z edge.
        let snap = BodySnapPoint.nearest(on: body, to: Vec3(x: 5, y: 9, z: 1))
        assertVec3(snap, Vec3(x: 5, y: 10, z: 0))
    }

    func testBoxPicksTheCorrectFaceOnEachAxis() {
        let body = makeResolvedBody(shape: .box(size: Vec3(x: 10, y: 20, z: 30)))
        assertVec3(BodySnapPoint.nearest(on: body, to: Vec3(x: -5, y: 1, z: 1)), Vec3(x: -5, y: 0, z: 0))
        assertVec3(BodySnapPoint.nearest(on: body, to: Vec3(x: 1, y: 10, z: 1)), Vec3(x: 0, y: 10, z: 0))
        assertVec3(BodySnapPoint.nearest(on: body, to: Vec3(x: 1, y: 1, z: -15)), Vec3(x: 0, y: 0, z: -15))
    }

    // MARK: - Zero-thickness sheet

    func testZeroThicknessSheetAlwaysSnapsToItsNormalPlane() {
        // A flat sheet in the XZ plane (normal = Y) — clicking anywhere on it
        // should snap within that one plane, never mistake an in-plane axis
        // for "the face."
        let body = makeResolvedBody(shape: .sheet(size: Vec3(x: 40, y: 0, z: 60), normal: .y))
        let snap = BodySnapPoint.nearest(on: body, to: Vec3(x: 5, y: 0, z: 5))
        XCTAssertEqual(snap.y, 0, accuracy: 1e-9)
        assertVec3(snap, Vec3(x: 0, y: 0, z: 0)) // near the middle -> center
    }

    // MARK: - Cylinder: end cap, rim, and curved side

    func testCylinderClickNearCenterOfEndCapSnapsToAxis() {
        let body = makeResolvedBody(shape: .cylinder(radius: 5, begin: -10, end: 10, axis: .y))
        // Near the top cap, close to the axis (radial distance 1, radius 5).
        let snap = BodySnapPoint.nearest(on: body, to: Vec3(x: 1, y: 10, z: 0))
        assertVec3(snap, Vec3(x: 0, y: 10, z: 0))
    }

    func testCylinderClickNearRimOfEndCapSnapsToRimAtThatAngle() {
        let body = makeResolvedBody(shape: .cylinder(radius: 5, begin: -10, end: 10, axis: .y))
        // Near the top cap, close to the rim at a specific angle.
        let snap = BodySnapPoint.nearest(on: body, to: Vec3(x: 4.9, y: 10, z: 0))
        assertVec3(snap, Vec3(x: 5, y: 10, z: 0), accuracy: 1e-6)
    }

    func testCylinderClickOnCurvedSideProjectsOntoAxis() {
        let body = makeResolvedBody(shape: .cylinder(radius: 5, begin: -10, end: 10, axis: .y))
        // Squarely on the curved side, well away from either end cap.
        let snap = BodySnapPoint.nearest(on: body, to: Vec3(x: 5, y: 3, z: 0))
        assertVec3(snap, Vec3(x: 0, y: 3, z: 0))
    }

    func testCylinderAlongXAxisUsesCorrectPerpendicularPlane() {
        let body = makeResolvedBody(shape: .cylinder(radius: 5, begin: -10, end: 10, axis: .x))
        let snap = BodySnapPoint.nearest(on: body, to: Vec3(x: 10, y: 1, z: 0))
        assertVec3(snap, Vec3(x: 10, y: 0, z: 0))
    }

    // MARK: - Position, rotation and scale

    func testSnapPointRespectsBodyPosition() {
        let body = makeResolvedBody(shape: .box(size: Vec3(repeating: 10)), position: Vec3(x: 50, y: -20, z: 5))
        let snap = BodySnapPoint.nearest(on: body, to: Vec3(x: 55, y: -19, z: 6))
        assertVec3(snap, Vec3(x: 55, y: -20, z: 5))
    }

    /// The bug this file exists to catch: a bounding-box approximation gets
    /// the wrong face once a body is rotated, because the world-space AABB
    /// is not the shape of the true rotated faces. Working in local space
    /// (as `BodySnapPoint` does) must stay correct regardless.
    func testSnapPointIsCorrectForARotatedBody() {
        let body = makeResolvedBody(
            shape: .box(size: Vec3(x: 10, y: 20, z: 30)),
            rotationDegrees: Vec3(x: 0, y: 90, z: 0)
        )
        // A 90 degree yaw swaps the X and Z extents in world space: the
        // local +X face (half-extent 5) now points along world -Z.
        let worldBounds = body.axisAlignedBounds
        XCTAssertEqual(worldBounds.size.x, 30, accuracy: 1e-9)
        XCTAssertEqual(worldBounds.size.z, 10, accuracy: 1e-9)

        // Clicking near the middle of that rotated face (world -Z, at the
        // world extreme) must snap to local (+5, 0, 0) rotated into world
        // space, not to whatever the AABB's -Z face would naively suggest.
        let snap = BodySnapPoint.nearest(on: body, to: Vec3(x: 1, y: 1, z: -5))
        let expected = body.rotationMatrix.apply(to: Vec3(x: 5, y: 0, z: 0))
        assertVec3(snap, expected, accuracy: 1e-6)
    }

    func testSnapPointRespectsNonUniformScale() {
        let body = makeResolvedBody(shape: .box(size: Vec3(repeating: 10)), scale: Vec3(x: 2, y: 1, z: 1))
        // Local +X face is at local x=5; scaled by 2 that's world x=10.
        let snap = BodySnapPoint.nearest(on: body, to: Vec3(x: 9, y: 1, z: 1))
        assertVec3(snap, Vec3(x: 10, y: 0, z: 0))
    }
}
