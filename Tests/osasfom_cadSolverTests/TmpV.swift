import XCTest
import osasfom_cadCore
@testable import osasfom_cadSolver

final class TmpV: XCTestCase {
    func testValidate() throws {
        let url = URL(fileURLWithPath: "/Users/barteksiwik/Desktop/Patch-1.8GHz-InsetFed.osasfomcad")
        let state = try ProjectSerializer.decode(try Data(contentsOf: url))
        let r = ModelResolver.resolve(state)
        print("V errors=\(r.errorCount)")
        for d in r.diagnostics.errors { print("V ERROR \(d)") }
        for n in ["patch_w","patch_l","inset_x0","feed_w","gap_w","side_w","side_cx","feed_len","feed_cy","main_depth","main_cy"] {
            print(String(format: "V %-11@ = %.3f", n as NSString, r.variables.values[n] ?? .nan))
        }
        print("V --- body extents (world mm) ---")
        for b in r.bodies {
            let bb = b.axisAlignedBounds
            print(String(format: "V %-18@ x[%7.2f %7.2f] y[%7.2f %7.2f] z[%6.3f %6.3f]",
                b.name as NSString, bb.minimum.x, bb.maximum.x, bb.minimum.y, bb.maximum.y, bb.minimum.z, bb.maximum.z))
        }
        let lines = try XCTUnwrap(GridMesher.makeDiscLines(resolved: r, setup: state.simulation, unit: state.lengthUnit))
        let n = lines.metersLines.map(\.count)
        print("V grid \(n) cells=\((n[0]-1)*(n[1]-1)*(n[2]-1))")
        var warn: [String] = []
        let edges = ZeroThicknessConductors.edges(bodies: r.bodies, materials: state.materials,
                                                  unit: state.lengthUnit, lines: lines, warnings: &warn)
        print("V forced PEC edges: \(edges.count), warnings: \(warn)")
        XCTAssertEqual(r.errorCount, 0)
    }
}
