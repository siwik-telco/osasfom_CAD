import XCTest
@testable import osasfom_cadSolver

/// Guards the bug that silently shipped twice: the parallel path existing but
/// never being taken, because `parallelWorkThreshold` sat above the size of
/// every realistic model. That failure mode is invisible — runs still produce
/// correct results, just single-threaded — so it needs an explicit test.
///
/// Deliberately asserts the *deterministic* property (does a realistic grid
/// engage the parallel path?) rather than wall-clock speedup, which would be
/// flaky on a loaded or low-core machine.
final class ParallelismEngagementTests: XCTestCase {

    /// Cell counts representative of models this app is actually used for:
    /// a 2.4 GHz reference dipole meshes to a few thousand cells, the
    /// dipole regression test to ~16k.
    private let realisticGridCellCounts = [
        1_800,   // 2.4 GHz reference dipole
        15_876,  // DipoleReturnLossTests grid (21 x 36 x 21)
        29_744,  // a modestly finer mesh
    ]

    func testRealisticGridsEngageTheParallelPath() {
        for cells in realisticGridCellCounts {
            XCTAssertGreaterThanOrEqual(
                cells,
                Engine.parallelWorkThreshold,
                """
                A \(cells)-cell grid falls below parallelWorkThreshold \
                (\(Engine.parallelWorkThreshold)), so it would run single-threaded. \
                Benchmarks show parallel wins from well under 1k cells upward — \
                if you raise this threshold, re-measure first.
                """
            )
        }
    }

    /// The threshold exists only to skip degenerate grids; it should never
    /// creep back up into the range of real models.
    func testThresholdStaysLowEnoughToBeUseful() {
        XCTAssertLessThanOrEqual(Engine.parallelWorkThreshold, 2_000)
    }

    /// Parallel and sequential must produce bit-identical fields — the chunked
    /// split is only safe because each phase writes its own planes and reads a
    /// field array nothing else is mutating. If that ever stops holding, the
    /// results diverge and this catches it.
    func testParallelAndSequentialAgreeExactly() {
        func run(threshold: Int) -> [Double] {
            let original = Engine.parallelWorkThreshold
            defer { Engine.parallelWorkThreshold = original }
            Engine.parallelWorkThreshold = threshold

            func lines(_ n: Int) -> [Double] { (0..<n).map { Double($0) * 1e-3 } }
            let op = Operator()
            op.setupGrid(discLines: [lines(24), lines(20), lines(18)], gridDeltaUnit: 1.0)
            op.calcECOperator()
            let engine = Engine.make(op: op)

            // Seed an asymmetric field so the comparison is meaningful.
            for x in 0..<24 where x % 3 == 0 {
                engine.setVolt(0, x, 5, 5, Double(x) * 0.5)
                engine.setCurr(1, x, 4, 6, Double(x) * 0.25)
            }
            engine.iterateTS(40)

            var out: [Double] = []
            for x in 0..<24 {
                for n in 0..<3 {
                    out.append(engine.getVolt(n, x, 5, 5))
                    out.append(engine.getCurr(n, x, 4, 6))
                }
            }
            return out
        }

        let sequential = run(threshold: .max)
        let parallel = run(threshold: 0)

        XCTAssertEqual(sequential.count, parallel.count)
        for (i, (s, p)) in zip(sequential, parallel).enumerated() {
            XCTAssertEqual(s, p, "field sample \(i) diverged: sequential \(s) vs parallel \(p)")
        }
        XCTAssertTrue(sequential.contains { $0 != 0 }, "test seeded no field; comparison would be vacuous")
    }
}
