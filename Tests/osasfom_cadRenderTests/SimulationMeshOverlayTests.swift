import SceneKit
import XCTest
import osasfom_cadCore

@testable import osasfom_cadRender

/// The Yee-grid overlay: three orthogonal slices through the model, drawn from
/// the same grid lines the solver meshes.
///
/// Drawing the full lattice is not an option — a realistic domain is a couple
/// of million cells — so the slicing is what makes this viewable at all, and
/// it is the part that can silently be wrong: a slice that misses the geometry
/// or a plane that draws the wrong axis's lines still *looks* like a mesh.
final class SimulationMeshOverlayTests: XCTestCase {

    private let domain = BodyBounds(
        xMin: -10, xMax: 10,
        yMin: -20, yMax: 20,
        zMin: -5, zMax: 5
    )

    /// Deliberately different counts per axis, so a slice that drew the wrong
    /// axis's lines would change the total rather than cancel out.
    private let lines = [
        [-10.0, -4, 0, 6, 10],      // x: 5
        [-20.0, -8, 0, 8, 14, 20],  // y: 6
        [-5.0, 0, 5]                // z: 3
    ]

    private func preview(focus: Vec3 = .zero) -> SceneController.MeshPreview {
        SceneController.MeshPreview(linesPerAxis: lines, bounds: domain, focus: focus)
    }

    private func node(focus: Vec3 = .zero) -> SCNNode {
        SceneGeometryFactory.makeMeshLinesNode(
            linesPerAxis: lines,
            bounds: domain,
            focus: focus,
            color: .white
        )
    }

    /// Each of the three planes carries the lines of the two axes it does not
    /// cut, so every axis is drawn exactly twice: 2·(nx + ny + nz) segments.
    func testEachAxisIsDrawnOnBothPlanesThatShowIt() throws {
        let geometry = try XCTUnwrap(node().geometry)
        let element = try XCTUnwrap(geometry.elements.first)

        XCTAssertEqual(element.primitiveType, .line)
        XCTAssertEqual(element.primitiveCount, 2 * (5 + 6 + 3))
    }

    /// The real cell count, which is what makes this worth showing next to the
    /// inspector's uniform-fill estimate — that one ignores snapping and
    /// refinement, so the two legitimately disagree.
    func testCellCountIsTheProductOfTheGaps() {
        XCTAssertEqual(preview().cellCount, 4 * 5 * 2)
    }

    func testCellCountIsZeroWhenAnAxisHasNoCells() {
        let degenerate = SceneController.MeshPreview(
            linesPerAxis: [[0.0], [0.0, 1], [0.0, 1]],
            bounds: domain,
            focus: .zero
        )
        XCTAssertEqual(degenerate.cellCount, 0)
    }

    /// A model sitting outside the domain would otherwise put the slices
    /// outside it too, drawing three planes floating in space with the
    /// geometry nowhere near them.
    func testFocusOutsideTheDomainIsClampedBackIntoIt() throws {
        let inside = try XCTUnwrap(node(focus: .zero).geometry?.elements.first?.primitiveCount)
        let outside = try XCTUnwrap(
            node(focus: Vec3(x: 1000, y: -1000, z: 1000)).geometry?.elements.first?.primitiveCount
        )
        // Same geometry either way — clamped, not dropped.
        XCTAssertEqual(outside, inside)

        let clamped = try XCTUnwrap(node(focus: Vec3(x: 1000, y: -1000, z: 1000)).geometry?.boundingBox)
        XCTAssertLessThanOrEqual(Double(clamped.max.x), domain.xMax + 1e-9)
        XCTAssertGreaterThanOrEqual(Double(clamped.min.y), domain.yMin - 1e-9)
    }

    /// Every segment has to lie inside the domain box: the lines span it on
    /// one axis and sit on a grid line on another, so anything outside means
    /// the slicing picked up the wrong bound.
    func testEverySegmentStaysInsideTheDomain() throws {
        let box = try XCTUnwrap(node(focus: Vec3(x: 6, y: 8, z: 0)).geometry?.boundingBox)

        XCTAssertGreaterThanOrEqual(Double(box.min.x), domain.xMin - 1e-9)
        XCTAssertLessThanOrEqual(Double(box.max.x), domain.xMax + 1e-9)
        XCTAssertGreaterThanOrEqual(Double(box.min.y), domain.yMin - 1e-9)
        XCTAssertLessThanOrEqual(Double(box.max.y), domain.yMax + 1e-9)
        XCTAssertGreaterThanOrEqual(Double(box.min.z), domain.zMin - 1e-9)
        XCTAssertLessThanOrEqual(Double(box.max.z), domain.zMax + 1e-9)
    }

    /// The overlay spans the whole domain, not just the neighbourhood of the
    /// slice — that is what makes the grading from a refined region out to the
    /// coarse boundary readable.
    func testOverlaySpansTheFullDomain() throws {
        let box = try XCTUnwrap(node().geometry?.boundingBox)
        XCTAssertEqual(Double(box.min.x), domain.xMin, accuracy: 1e-6)
        XCTAssertEqual(Double(box.max.x), domain.xMax, accuracy: 1e-6)
        XCTAssertEqual(Double(box.min.y), domain.yMin, accuracy: 1e-6)
        XCTAssertEqual(Double(box.max.y), domain.yMax, accuracy: 1e-6)
    }

    func testMalformedLineSetDrawsNothingRatherThanCrashing() {
        let node = SceneGeometryFactory.makeMeshLinesNode(
            linesPerAxis: [[0.0, 1]], // only one axis
            bounds: domain,
            focus: .zero,
            color: .white
        )
        XCTAssertNil(node.geometry)
    }
}
