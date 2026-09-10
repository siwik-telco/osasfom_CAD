import XCTest
@testable import osasfom_cadCore

/// Covers importing an STL as a body: parsing both flavours, the unit
/// conversion STL cannot carry itself, and — the part that actually matters
/// for a solve — whether point-in-solid on the imported triangles agrees with
/// the analytic primitive the same shape would have produced.
final class STLImportTests: XCTestCase {

    /// A 20x10x6 box as a triangle soup, offset well away from the origin so
    /// the recentring is exercised rather than accidentally satisfied.
    private let boxSize = Vec3(x: 20, y: 10, z: 6)
    private let boxOffset = Vec3(x: 100, y: -40, z: 7)

    private func boxTriangles() -> [STLExporter.Triangle] {
        STLExporter.boxTriangles(size: boxSize).map { triangle in
            STLExporter.Triangle(
                v0: triangle.v0 + boxOffset,
                v1: triangle.v1 + boxOffset,
                v2: triangle.v2 + boxOffset
            )
        }
    }

    // MARK: - Parsing

    func testBinaryRoundTripsThroughTheExporter() throws {
        let original = boxTriangles()
        let result = try STLImporter.load(
            STLExporter.encodeBinary(original),
            unit: .millimeter,
            projectUnit: .millimeter
        )

        XCTAssertEqual(result.mesh.triangleCount, original.count)
        XCTAssertEqual(result.size.x, boxSize.x, accuracy: 1e-4)
        XCTAssertEqual(result.size.y, boxSize.y, accuracy: 1e-4)
        XCTAssertEqual(result.size.z, boxSize.z, accuracy: 1e-4)
    }

    func testASCIIIsParsed() throws {
        var text = "solid test\n"
        for triangle in boxTriangles() {
            text += "facet normal 0 0 0\n  outer loop\n"
            for vertex in [triangle.v0, triangle.v1, triangle.v2] {
                text += "    vertex \(vertex.x) \(vertex.y) \(vertex.z)\n"
            }
            text += "  endloop\nendfacet\n"
        }
        text += "endsolid test\n"

        let result = try STLImporter.load(
            XCTUnwrap(text.data(using: .utf8)),
            unit: .millimeter,
            projectUnit: .millimeter
        )
        XCTAssertEqual(result.mesh.triangleCount, 12)
        XCTAssertEqual(result.size.x, boxSize.x, accuracy: 1e-9)
    }

    /// The trap every naive STL reader falls into: plenty of binary writers
    /// put the word "solid" in the free-form 80-byte header, so sniffing the
    /// first five bytes reads a binary file as ASCII and finds no triangles.
    /// The length arithmetic is what decides it here.
    func testBinaryFileWhoseHeaderSaysSolidIsStillReadAsBinary() throws {
        var data = STLExporter.encodeBinary(boxTriangles())
        let header = Array("solid exported by some CAD tool".utf8)
        data.replaceSubrange(0..<header.count, with: header)

        XCTAssertTrue(STLImporter.isBinary(data))
        let result = try STLImporter.load(data, unit: .millimeter, projectUnit: .millimeter)
        XCTAssertEqual(result.mesh.triangleCount, 12)
    }

    func testEmptyMeshIsRejected() {
        XCTAssertThrowsError(
            try STLImporter.load(STLExporter.encodeBinary([]), unit: .millimeter, projectUnit: .millimeter)
        ) { error in
            XCTAssertEqual(error as? STLImporter.Failure, .empty)
        }
    }

    // MARK: - Units and placement

    /// STL stores no units, so this is the one conversion the importer must
    /// get right — a part authored in metres dropped into a millimetre project
    /// is otherwise 1000x too small.
    func testFileUnitsAreConvertedIntoProjectUnits() throws {
        let result = try STLImporter.load(
            STLExporter.encodeBinary(boxTriangles()),
            unit: .meter,
            projectUnit: .millimeter
        )
        XCTAssertEqual(result.size.x, boxSize.x * 1000, accuracy: 1e-3)
        XCTAssertEqual(result.origin.x, boxOffset.x * 1000, accuracy: 1e-3)
    }

    /// The mesh is recentred on its bounding box and the offset handed to the
    /// body's position — that is what lets it obey the same centred-on-origin
    /// convention as every parametric primitive while still landing where the
    /// file put it.
    func testMeshIsRecentredAndTheOffsetBecomesTheOrigin() throws {
        let result = try STLImporter.load(
            STLExporter.encodeBinary(boxTriangles()),
            unit: .millimeter,
            projectUnit: .millimeter
        )

        XCTAssertEqual(result.origin.x, boxOffset.x, accuracy: 1e-4)
        XCTAssertEqual(result.origin.y, boxOffset.y, accuracy: 1e-4)
        XCTAssertEqual(result.origin.z, boxOffset.z, accuracy: 1e-4)

        let centre = result.mesh.bounds.center
        XCTAssertEqual(centre.x, 0, accuracy: 1e-4)
        XCTAssertEqual(centre.y, 0, accuracy: 1e-4)
        XCTAssertEqual(centre.z, 0, accuracy: 1e-4)
    }

    // MARK: - Containment

    /// The load-bearing test. `ShapeContainment` is what the FDTD material
    /// provider samples, so an imported box has to voxelise exactly like a
    /// declared box of the same size — otherwise the mesh renders correctly
    /// and then simulates as something else.
    func testImportedBoxContainsTheSamePointsAsAnAnalyticBox() throws {
        let mesh = try XCTUnwrap(TriangleMesh(triangles: STLExporter.boxTriangles(size: boxSize)))
        let analytic = ResolvedShape.box(size: boxSize)
        let imported = ResolvedShape.mesh(mesh)

        var checked = 0
        for xStep in -6...6 {
            for yStep in -6...6 {
                for zStep in -6...6 {
                    // Deliberately off the half-integer grid so no sample sits
                    // exactly on a face, where the two are allowed to differ
                    // by a tolerance.
                    let point = Vec3(
                        x: Double(xStep) * 1.7 + 0.13,
                        y: Double(yStep) * 0.9 + 0.07,
                        z: Double(zStep) * 0.55 + 0.03
                    )
                    XCTAssertEqual(
                        ShapeContainment.contains(imported, localPoint: point),
                        ShapeContainment.contains(analytic, localPoint: point),
                        "disagreement at \(point)"
                    )
                    checked += 1
                }
            }
        }
        XCTAssertEqual(checked, 13 * 13 * 13)
    }

    func testClosedMeshIsDetectedAsWatertight() throws {
        let mesh = try XCTUnwrap(TriangleMesh(triangles: STLExporter.boxTriangles(size: boxSize)))
        XCTAssertTrue(mesh.isWatertight)
    }

    /// A box missing a face is open, and must say so — the inspector warns on
    /// it and `contains` switches to a majority vote rather than trusting one
    /// ray through the hole.
    func testMeshWithAMissingFaceIsNotWatertight() throws {
        let full = STLExporter.boxTriangles(size: boxSize)
        let open = Array(full.dropLast(2)) // one face is two triangles
        let mesh = try XCTUnwrap(TriangleMesh(triangles: open))
        XCTAssertFalse(mesh.isWatertight)
    }

    /// A body's rotation and scale are applied by undoing them on the query
    /// point, so they must work on a mesh exactly as on a primitive.
    func testRotatedAndScaledMeshBodyContainsTheRightPoints() throws {
        let mesh = try XCTUnwrap(TriangleMesh(triangles: STLExporter.boxTriangles(size: boxSize)))

        // Quarter turn about Z swaps the X and Y extents; a 2x scale on X
        // doubles what was the X half-extent.
        let rotated = ResolvedShape.mesh(mesh)
        let position = Vec3(x: 5, y: 5, z: 0)

        func contains(_ point: Vec3) -> Bool {
            ShapeContainment.contains(
                rotated,
                position: position,
                rotationDegrees: Vec3(x: 0, y: 0, z: 90),
                scale: Vec3(x: 2, y: 1, z: 1),
                worldPoint: point
            )
        }

        // Local +X half-extent 10, scaled to 20, rotated onto world +Y.
        XCTAssertTrue(contains(position + Vec3(x: 0, y: 19, z: 0)))
        XCTAssertFalse(contains(position + Vec3(x: 0, y: 21, z: 0)))
        // Local +Y half-extent 5 lands on world -X.
        XCTAssertTrue(contains(position + Vec3(x: -4, y: 0, z: 0)))
        XCTAssertFalse(contains(position + Vec3(x: -6, y: 0, z: 0)))
    }

    // MARK: - Acceleration

    /// Midpoint-subdivided box: 12 * 4^levels triangles, and watertight
    /// because a shared edge's midpoint is `(a + b) / 2` either way round,
    /// bit-identical.
    private func subdividedBox(levels: Int) -> [STLExporter.Triangle] {
        var triangles = STLExporter.boxTriangles(size: boxSize)
        for _ in 0..<levels {
            var next: [STLExporter.Triangle] = []
            next.reserveCapacity(triangles.count * 4)
            for t in triangles {
                let a = (t.v0 + t.v1) / 2, b = (t.v1 + t.v2) / 2, c = (t.v2 + t.v0) / 2
                next.append(STLExporter.Triangle(v0: t.v0, v1: a, v2: c))
                next.append(STLExporter.Triangle(v0: a, v1: t.v1, v2: b))
                next.append(STLExporter.Triangle(v0: c, v1: b, v2: t.v2))
                next.append(STLExporter.Triangle(v0: a, v1: b, v2: c))
            }
            triangles = next
        }
        return triangles
    }

    /// Tessellation must not change what the shape *is*. Three subdivisions of
    /// the same box occupy the same volume, so every sample point has to land
    /// the same way in all of them — the check that the ray parity is reading
    /// the surface rather than the triangle count.
    func testContainmentIsIndependentOfTessellation() throws {
        let meshes = try [1, 3, 5].map { try XCTUnwrap(TriangleMesh(triangles: subdividedBox(levels: $0))) }
        XCTAssertTrue(meshes.allSatisfy(\.isWatertight))

        for step in 0..<4000 {
            let t = Double(step)
            let point = Vec3(
                x: (t * 0.7919).truncatingRemainder(dividingBy: 26) - 13,
                y: (t * 0.3313).truncatingRemainder(dividingBy: 14) - 7,
                z: (t * 0.5717).truncatingRemainder(dividingBy: 10) - 5
            )
            let answers = meshes.map { $0.contains(point) }
            XCTAssertEqual(Set(answers).count, 1, "tessellation changed the answer at \(point): \(answers)")
        }
    }

    /// Guards the BVH itself. `ShapeContainment` is sampled millions of times
    /// building the FDTD operator, so a regression to a linear scan over
    /// triangles would be a catastrophic slowdown that no correctness test
    /// would notice. Compared as a *ratio* so the bar does not move with the
    /// machine: 64x the triangles costs about a third more time with a tree,
    /// and 64x more without one.
    func testQueryCostDoesNotScaleWithTriangleCount() throws {
        let small = try XCTUnwrap(TriangleMesh(triangles: subdividedBox(levels: 1)))
        let large = try XCTUnwrap(TriangleMesh(triangles: subdividedBox(levels: 4)))
        XCTAssertEqual(large.triangleCount, small.triangleCount * 64)

        func time(_ mesh: TriangleMesh) -> TimeInterval {
            let start = Date()
            for step in 0..<20_000 {
                let t = Double(step)
                _ = mesh.contains(
                    Vec3(
                        x: (t * 0.7919).truncatingRemainder(dividingBy: 26) - 13,
                        y: (t * 0.3313).truncatingRemainder(dividingBy: 14) - 7,
                        z: (t * 0.5717).truncatingRemainder(dividingBy: 10) - 5
                    )
                )
            }
            return Date().timeIntervalSince(start)
        }

        _ = time(small) // warm up, so the first run does not pay for paging
        let ratio = time(large) / max(time(small), 1e-9)
        XCTAssertLessThan(ratio, 15, "64x the triangles cost \(ratio)x the time — the BVH is not being used")
    }

    // MARK: - Persistence

    /// A mesh body has to survive a project save/load — the triangles ride as
    /// a base64 float32 blob, and a body that came back as anything else would
    /// silently lose the imported geometry.
    func testMeshBodySurvivesAProjectRoundTrip() throws {
        let result = try STLImporter.load(
            STLExporter.encodeBinary(boxTriangles()),
            unit: .millimeter,
            projectUnit: .millimeter
        )

        var state = CADModelState(name: "Imported", lengthUnit: .millimeter)
        state.bodies = [
            CADBody(
                name: "Bracket",
                primitive: .mesh(
                    MeshSpec(mesh: result.mesh, sourceName: "bracket.stl", sourceUnit: .millimeter)
                ),
                transform: BodyTransform(position: Vector3Expression(result.origin))
            )
        ]

        let restored = try ProjectSerializer.decode(ProjectSerializer.encode(state))
        let spec = try XCTUnwrap(restored.bodies.first?.primitive.meshSpec)

        XCTAssertEqual(spec.sourceName, "bracket.stl")
        XCTAssertEqual(spec.sourceUnit, .millimeter)
        XCTAssertEqual(spec.mesh.id, result.mesh.id, "identity must survive, it is what == compares")
        XCTAssertEqual(spec.mesh.triangleCount, result.mesh.triangleCount)
        XCTAssertTrue(spec.mesh.isWatertight)

        for (restoredTriangle, originalTriangle) in zip(spec.mesh.triangles, result.mesh.triangles) {
            XCTAssertEqual(restoredTriangle.v0.x, originalTriangle.v0.x, accuracy: 1e-3)
            XCTAssertEqual(restoredTriangle.v1.y, originalTriangle.v1.y, accuracy: 1e-3)
            XCTAssertEqual(restoredTriangle.v2.z, originalTriangle.v2.z, accuracy: 1e-3)
        }
    }

    /// The resolver must pass the mesh through by reference. Rebuilding it
    /// would rebuild the BVH on every keystroke in the inspector.
    func testResolvingReusesTheSameMeshObject() throws {
        let mesh = try XCTUnwrap(TriangleMesh(triangles: STLExporter.boxTriangles(size: boxSize)))
        var state = CADModelState(name: "Imported", lengthUnit: .millimeter)
        state.bodies = [
            CADBody(
                name: "Bracket",
                primitive: .mesh(MeshSpec(mesh: mesh, sourceName: "b.stl", sourceUnit: .millimeter))
            )
        ]

        let resolved = ModelResolver.resolve(state)
        XCTAssertEqual(resolved.errorCount, 0, "\(resolved.diagnostics.errors)")
        guard case .mesh(let resolvedMesh)? = resolved.bodies.first?.shape else {
            return XCTFail("expected a mesh shape")
        }
        XCTAssertTrue(resolvedMesh === mesh)
    }
}
