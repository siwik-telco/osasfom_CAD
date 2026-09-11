import XCTest
import osasfom_cadCore
@testable import osasfom_cadSolver

/// `maxGrowthRatio` used to be accepted, stored, written into the solver deck
/// and then discarded — `fillInterval` ended with a literal `_ = growth`, so
/// every interval was divided uniformly and cell size stepped abruptly at each
/// fixed line. A board went from 0.4 mm inside its substrate to 3.5 mm one cell
/// later, an 8.7x jump: a numerical discontinuity in its own right, and the one
/// the Yee coefficients are least forgiving of.
final class MeshGradingTests: XCTestCase {

    private func ratios(_ sizes: [Double]) -> [Double] {
        zip(sizes, sizes.dropFirst()).map { max($1 / $0, $0 / $1) }
    }

    // MARK: - The size generator

    func testRampsFromAFineNeighbourUpToTheTarget() {
        let sizes = GridMesher.gradedCellSizes(
            length: 60, target: 3.5, startCell: 0.4, endCell: 3.5, growth: 1.4
        )
        XCTAssertEqual(sizes.reduce(0, +), 60, accuracy: 1e-9, "fixed lines must not move")
        XCTAssertLessThan(try XCTUnwrap(sizes.first), 1.0, "starts near the fine neighbour")
        XCTAssertEqual(try XCTUnwrap(sizes.last), 3.5, accuracy: 0.2, "reaches the target")
        XCTAssertLessThan(try XCTUnwrap(ratios(sizes).max()), 1.45)
    }

    func testRampsAtBothEndsWhenBothNeighboursAreFine() {
        let sizes = GridMesher.gradedCellSizes(
            length: 60, target: 3.5, startCell: 0.4, endCell: 0.4, growth: 1.4
        )
        XCTAssertEqual(sizes.reduce(0, +), 60, accuracy: 1e-9)
        XCTAssertLessThan(try XCTUnwrap(sizes.first), 1.0)
        XCTAssertLessThan(try XCTUnwrap(sizes.last), 1.0)
        XCTAssertGreaterThan(sizes.max() ?? 0, 2.0, "still reaches the target in the middle")
    }

    func testGrowthOfOneKeepsAUniformFill() {
        let sizes = GridMesher.gradedCellSizes(
            length: 10, target: 1, startCell: 0.01, endCell: 0.01, growth: 1
        )
        XCTAssertEqual(try XCTUnwrap(ratios(sizes).max()), 1, accuracy: 1e-9)
    }

    /// Two bodies sharing a face routinely disagree in the last bit, which
    /// leaves a degenerate interval between them. Uniform fill shrugged that
    /// off; a ramp seeded from a 1e-16 "cell" generated a hundred microscopic
    /// cells and drove the worst adjacent ratio to 836.
    func testDegenerateNeighbourCannotSeedAMicroscopicRamp() {
        let sizes = GridMesher.gradedCellSizes(
            length: 10, target: 1, startCell: 2e-16, endCell: 1, growth: 1.4, minimum: 0.1
        )
        XCTAssertEqual(sizes.reduce(0, +), 10, accuracy: 1e-9)
        XCTAssertGreaterThan(try XCTUnwrap(sizes.min()), 0.05, "no cell may collapse toward zero")
        XCTAssertLessThan(sizes.count, 100)
    }

    // MARK: - End to end through the mesher

    /// The real board: a 1.575 mm substrate pinned by fixed lines inside a
    /// domain padded out to half a wavelength.
    func testBoardMeshHonoursTheGrowthRatio() throws {
        let url = URL(fileURLWithPath: "/Users/barteksiwik/Desktop/Patch-2.42GHz-RT5880.osasfomcad")
        guard let data = try? Data(contentsOf: url) else {
            throw XCTSkip("reference patch project not present")
        }
        let state = try ProjectSerializer.decode(data)
        let resolved = ModelResolver.resolve(state)
        let lines = try XCTUnwrap(
            GridMesher.makeDiscLines(resolved: resolved, setup: state.simulation, unit: state.lengthUnit)
        )

        for axis in 0..<3 {
            let sizes = zip(lines.metersLines[axis], lines.metersLines[axis].dropFirst()).map { $1 - $0 }
            XCTAssertTrue(sizes.allSatisfy { $0 > 0 }, "axis \(axis) has a zero-width cell")
            // A few percent of slack: sizes are normalised to land exactly on
            // the fixed lines, which perturbs the ratio slightly.
            XCTAssertLessThan(
                try XCTUnwrap(ratios(sizes).max()), 1.5,
                "axis \(axis) still steps abruptly (limit \(state.simulation.mesh.maxGrowthRatio))"
            )
        }
    }
}
