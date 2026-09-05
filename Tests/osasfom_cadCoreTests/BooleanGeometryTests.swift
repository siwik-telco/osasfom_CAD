import XCTest

@testable import osasfom_cadCore

/// Boolean geometry has two independent implementations that must agree:
/// `ShapeContainment` (analytic, what the FDTD solver samples) and `MeshCSG`
/// (triangles, what the viewport and STL export show). These tests pin both,
/// and check them against each other.
final class BooleanGeometryTests: XCTestCase {

    // MARK: - Helpers

    /// Signed volume of a closed triangle soup — the divergence-theorem sum
    /// over tetrahedra to the origin. Also a cheap closedness check: an open
    /// or inconsistently wound mesh gives a value that doesn't match the
    /// shape it is supposed to be.
    private func volume(of triangles: [STLExporter.Triangle]) -> Double {
        triangles.reduce(0) { total, t in
            total + t.v0.dot(t.v1.cross(t.v2)) / 6
        }
    }

    private func box(size: Vec3, center: Vec3 = .zero) -> [STLExporter.Triangle] {
        STLExporter.boxTriangles(size: size).map { t in
            STLExporter.Triangle(v0: t.v0 + center, v1: t.v1 + center, v2: t.v2 + center)
        }
    }

    private func makeBody(
        shape: ResolvedShape,
        position: Vec3 = .zero,
        booleans: [ResolvedBooleanOperation] = []
    ) -> ResolvedBody {
        ResolvedBody(
            id: UUID(),
            name: "Test",
            shape: shape,
            position: position,
            rotationDegrees: .zero,
            scale: .one,
            materialID: MaterialLibrary.vacuumID,
            priority: 0,
            isVisible: true,
            orderIndex: 0,
            booleans: booleans
        )
    }

    private func tool(
        _ kind: BooleanKind,
        shape: ResolvedShape,
        position: Vec3 = .zero,
        rotationDegrees: Vec3 = .zero,
        scale: Vec3 = .one
    ) -> ResolvedBooleanOperation {
        ResolvedBooleanOperation(
            id: UUID(),
            kind: kind,
            shape: shape,
            position: position,
            rotationDegrees: rotationDegrees,
            scale: scale
        )
    }

    // MARK: - MeshCSG volumes

    func testSubtractingAnOverlappingHalfLeavesHalfTheVolume() {
        let cube = box(size: Vec3(repeating: 10))
        // A slab covering x ∈ [0, 10], so exactly half the cube.
        let slab = box(size: Vec3(x: 10, y: 20, z: 20), center: Vec3(x: 5, y: 0, z: 0))

        let result = MeshCSG.subtract(cube, slab)
        XCTAssertEqual(volume(of: result), 500, accuracy: 1e-6)
    }

    func testIntersectionKeepsOnlyTheSharedVolume() {
        let a = box(size: Vec3(repeating: 10))
        let b = box(size: Vec3(repeating: 10), center: Vec3(x: 5, y: 0, z: 0))
        // Overlap is 5 x 10 x 10.
        XCTAssertEqual(volume(of: MeshCSG.intersect(a, b)), 500, accuracy: 1e-6)
    }

    func testUnionOfTwoOverlappingBoxesCountsTheOverlapOnce() {
        let a = box(size: Vec3(repeating: 10))
        let b = box(size: Vec3(repeating: 10), center: Vec3(x: 5, y: 0, z: 0))
        // 1000 + 1000 - 500 shared.
        XCTAssertEqual(volume(of: MeshCSG.union(a, b)), 1500, accuracy: 1e-6)
    }

    func testUnionOfIdenticalSolidsIsNotDoubleCounted() {
        // Coincident faces are the classic way a BSP boolean goes wrong,
        // producing either a doubled shell or a hollow one.
        let cube = box(size: Vec3(repeating: 10))
        XCTAssertEqual(volume(of: MeshCSG.union(cube, cube)), 1000, accuracy: 1e-6)
    }

    func testSubtractingADisjointToolChangesNothing() {
        let cube = box(size: Vec3(repeating: 10))
        let faraway = box(size: Vec3(repeating: 2), center: Vec3(x: 100, y: 0, z: 0))
        XCTAssertEqual(volume(of: MeshCSG.subtract(cube, faraway)), 1000, accuracy: 1e-6)
    }

    func testSubtractingAnEnclosingToolLeavesNothing() {
        let cube = box(size: Vec3(repeating: 10))
        let bigger = box(size: Vec3(repeating: 20))
        XCTAssertEqual(volume(of: MeshCSG.subtract(cube, bigger)), 0, accuracy: 1e-6)
    }

    /// A hole through a plate: the through-cut case that made the feature
    /// worth having. The cylinder is tessellated, so the expected volume uses
    /// the polygon's area, not πr².
    func testDrillingAThroughHoleRemovesTheCylinderVolume() {
        let segments = 64
        let plate = box(size: Vec3(x: 20, y: 20, z: 2))
        let drill = STLExporter.cylinderTriangles(radius: 3, length: 10, axis: .z, segments: segments)

        let result = MeshCSG.subtract(plate, drill)

        let polygonArea = 0.5 * Double(segments) * sin(2 * .pi / Double(segments)) * 9
        XCTAssertEqual(volume(of: result), 20 * 20 * 2 - polygonArea * 2, accuracy: 1e-6)
    }

    // MARK: - ShapeContainment

    func testContainmentAppliesSubtractAsAHole() {
        let body = makeBody(
            shape: .box(size: Vec3(repeating: 10)),
            booleans: [tool(.subtract, shape: .box(size: Vec3(repeating: 2)))]
        )
        XCTAssertFalse(body.contains(worldPoint: .zero), "inside the hole")
        XCTAssertTrue(body.contains(worldPoint: Vec3(x: 4, y: 0, z: 0)), "outside the hole, inside the box")
        XCTAssertFalse(body.contains(worldPoint: Vec3(x: 40, y: 0, z: 0)), "outside everything")
    }

    func testContainmentAppliesAddAsExtraMaterial() {
        let body = makeBody(
            shape: .box(size: Vec3(repeating: 10)),
            booleans: [tool(.add, shape: .box(size: Vec3(repeating: 4)), position: Vec3(x: 11, y: 0, z: 0))]
        )
        XCTAssertTrue(body.contains(worldPoint: Vec3(x: 11, y: 0, z: 0)), "inside the added tool")
        XCTAssertTrue(body.contains(worldPoint: .zero), "still inside the base")
        XCTAssertFalse(body.contains(worldPoint: Vec3(x: 30, y: 0, z: 0)))
    }

    func testContainmentAppliesTrimAsAnIntersection() {
        let body = makeBody(
            shape: .box(size: Vec3(repeating: 10)),
            booleans: [tool(.trim, shape: .box(size: Vec3(repeating: 10)), position: Vec3(x: 5, y: 0, z: 0))]
        )
        XCTAssertTrue(body.contains(worldPoint: Vec3(x: 2, y: 0, z: 0)), "in both")
        XCTAssertFalse(body.contains(worldPoint: Vec3(x: -2, y: 0, z: 0)), "in the base only")
        XCTAssertFalse(body.contains(worldPoint: Vec3(x: 8, y: 0, z: 0)), "in the tool only")
    }

    /// Order matters, and it is the order the inspector lists: a later `add`
    /// can refill a hole an earlier `subtract` made.
    func testStepsApplyInOrderSoAnAddCanRefillAHole() {
        let hole = tool(.subtract, shape: .box(size: Vec3(repeating: 6)))
        let plug = tool(.add, shape: .box(size: Vec3(repeating: 2)))

        let drilled = makeBody(shape: .box(size: Vec3(repeating: 10)), booleans: [hole, plug])
        XCTAssertTrue(drilled.contains(worldPoint: .zero), "the plug went back in")

        let refilledThenDrilled = makeBody(shape: .box(size: Vec3(repeating: 10)), booleans: [plug, hole])
        XCTAssertFalse(refilledThenDrilled.contains(worldPoint: .zero), "the subtract came last and won")
    }

    func testARotatedToolCutsWhereItIsActuallyOriented() {
        // A slab far thinner than the base, turned 90° about Z: it can only
        // reach the sampled point if the rotation is honoured.
        let body = makeBody(
            shape: .box(size: Vec3(repeating: 10)),
            booleans: [
                tool(.subtract, shape: .box(size: Vec3(x: 20, y: 1, z: 20)), rotationDegrees: Vec3(x: 0, y: 0, z: 90))
            ]
        )
        XCTAssertFalse(body.contains(worldPoint: Vec3(x: 0, y: 4, z: 0)), "the rotated slab lies along Y")
        XCTAssertTrue(body.contains(worldPoint: Vec3(x: 4, y: 0, z: 0)), "and not along X")
    }

    func testCylinderContainmentIsRoundNotBoxy() {
        let body = makeBody(shape: .cylinder(radius: 5, begin: -10, end: 10, axis: .z))
        XCTAssertTrue(body.contains(worldPoint: Vec3(x: 4.9, y: 0, z: 0)))
        // Inside the enclosing box's corner, outside the actual cylinder.
        XCTAssertFalse(body.contains(worldPoint: Vec3(x: 4.9, y: 4.9, z: 0)))
        XCTAssertFalse(body.contains(worldPoint: Vec3(x: 0, y: 0, z: 11)))
    }

    // MARK: - The two implementations must agree

    /// Samples a grid through a drilled plate and checks the analytic
    /// predicate against a point-in-mesh test of the CSG result. If these
    /// two ever disagree, the solver is simulating something other than what
    /// the user is looking at.
    func testAnalyticContainmentAgreesWithTheGeneratedMesh() {
        let body = makeBody(
            shape: .box(size: Vec3(x: 20, y: 20, z: 4)),
            booleans: [tool(.subtract, shape: .cylinder(radius: 4, begin: -10, end: 10, axis: .z))]
        )
        let mesh = BodyMesh.worldTriangles(for: body, segments: 128)

        var checked = 0
        for x in stride(from: -9.0, through: 9.0, by: 1.5) {
            for y in stride(from: -9.0, through: 9.0, by: 1.5) {
                let point = Vec3(x: x, y: y, z: 0)
                // Skip points close to the (faceted) cut, where a 128-sided
                // prism and a true cylinder legitimately disagree.
                let radius = (x * x + y * y).squareRoot()
                guard abs(radius - 4) > 0.2 else { continue }

                checked += 1
                XCTAssertEqual(
                    body.contains(worldPoint: point),
                    Self.meshContains(mesh, point: point),
                    "disagreement at (\(x), \(y))"
                )
            }
        }
        XCTAssertGreaterThan(checked, 100, "the sweep should actually have sampled something")
    }

    /// Ray casting along +X: odd crossings means inside. Adequate for a test
    /// oracle on axis-aligned-ish geometry.
    private static func meshContains(_ triangles: [STLExporter.Triangle], point: Vec3) -> Bool {
        let direction = Vec3(x: 1, y: 0.0001, z: 0.0001)
        var crossings = 0
        for t in triangles {
            let edge1 = t.v1 - t.v0
            let edge2 = t.v2 - t.v0
            let h = direction.cross(edge2)
            let a = edge1.dot(h)
            guard abs(a) > 1e-12 else { continue }
            let f = 1 / a
            let s = point - t.v0
            let u = f * s.dot(h)
            guard u >= 0, u <= 1 else { continue }
            let q = s.cross(edge1)
            let v = f * direction.dot(q)
            guard v >= 0, u + v <= 1 else { continue }
            if f * edge2.dot(q) > 1e-9 { crossings += 1 }
        }
        return crossings % 2 == 1
    }
}
