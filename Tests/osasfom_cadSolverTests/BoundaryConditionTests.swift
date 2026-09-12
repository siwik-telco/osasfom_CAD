import XCTest
import osasfom_cadCore
@testable import osasfom_cadSolver

/// Electric and magnetic walls, pinned against a rectangular cavity whose
/// resonance is known in closed form.
///
/// Both wall kinds used to be wrong in a way no antenna-level test could see.
/// `applyElectricBC` zeroed the field *normal* to each face instead of the
/// tangential pair, and `applyMagneticBC` did the same to H, so the walls were
/// really set by the engine's bare edges: an electric conductor on every lower
/// face and a magnetic one half a cell beyond every upper face, whatever was
/// asked for.
final class BoundaryConditionTests: XCTestCase {

    /// Cavity extents, metres. TE101 has E along y varying as
    /// sin(πx/a)·sin(πz/d). The 2 mm cells put 20, 5 and 14 cells across it,
    /// so both the centre and the quarter points land on grid lines.
    private let a = 0.040, b = 0.010, d = 0.028, cell = 0.002

    private let everyFace = [Bool](repeating: true, count: 6)
    private let noFace = [Bool](repeating: false, count: 6)

    private func lines(from start: Double, to stop: Double) -> [Double] {
        let count = Int(((stop - start) / cell).rounded())
        return (0...count).map { start + Double($0) * cell }
    }

    /// f = c/2 · √((1/a)² + (1/d)²).
    private var analyticTE101Hertz: Double {
        FDTDConstants.C0 / 2 * ((1 / a) * (1 / a) + (1 / d) * (1 / d)).squareRoot()
    }

    // MARK: - Coefficients

    /// A conductor constrains the field lying *in* its surface. The component
    /// normal to the face has to stay live, or a ground plane drawn as a wall
    /// silently loses the first cell of whatever sits on it.
    func testElectricWallZeroesTangentialFieldButNotNormalField() {
        let axis = lines(from: 0, to: 0.010)
        let op = Operator()
        op.setupGrid(discLines: [axis, axis, axis], gridDeltaUnit: 1)
        op.calcECOperator()
        op.applyElectricBC(everyFace)

        let last = axis.count - 1, mid = 2
        func vi(_ component: Int, normal: Int, index: Int) -> Double {
            var pos = [mid, mid, mid]
            pos[normal] = index
            return op.getVI(component, pos[0], pos[1], pos[2])
        }

        for normal in 0..<3 {
            for tangential in [(normal + 1) % 3, (normal + 2) % 3] {
                XCTAssertEqual(vi(tangential, normal: normal, index: 0), 0, "tangential E on lower face \(normal)")
                XCTAssertEqual(vi(tangential, normal: normal, index: last), 0, "tangential E on upper face \(normal)")
                XCTAssertGreaterThan(vi(tangential, normal: normal, index: 1), 0, "one cell inside is untouched")
            }
            XCTAssertGreaterThan(vi(normal, normal: normal, index: 0), 0, "normal E leaving lower face \(normal)")
            XCTAssertGreaterThan(vi(normal, normal: normal, index: last - 1), 0, "normal E reaching upper face \(normal)")
            XCTAssertEqual(vi(normal, normal: normal, index: last), 0, "an edge starting on the last line is outside")
        }
    }

    func testMagneticWallLeavesTheFaceFieldFree() {
        let axis = lines(from: 0, to: 0.010)
        let op = Operator()
        op.setupGrid(discLines: [axis, axis, axis], gridDeltaUnit: 1)
        op.calcECOperator()
        op.applyMagneticBC(everyFace)

        XCTAssertEqual(op.magneticWalls, everyFace)
        let last = axis.count - 1, mid = 2
        XCTAssertGreaterThan(op.getVI(1, 0, mid, mid), 0, "tangential E on a magnetic wall is not constrained")
        XCTAssertGreaterThan(op.getVI(1, last, mid, mid), 0)
        XCTAssertGreaterThan(op.getII(1, 0, mid, mid), 0, "and the update of H next to it is intact")
    }

    // MARK: - Cavity resonance

    /// Starts the cavity in its TE101 field, steps it, and returns the
    /// frequency a probe at `probeX` rings at.
    ///
    /// On a uniform grid the sampled mode is an exact eigenvector of the
    /// discrete operator, so the probe carries one pure tone and interpolated
    /// zero crossings time it far more finely than a spectrum of the same
    /// length could resolve.
    private func te101Hertz(
        xLines: [Double],
        electric: [Bool],
        magnetic: [Bool],
        probeX: Double,
        steps: Int = 700
    ) throws -> Double {
        let yLines = lines(from: 0, to: b)
        let zLines = lines(from: 0, to: d)
        let op = Operator()
        op.setupGrid(discLines: [xLines, yLines, zLines], gridDeltaUnit: 1)
        op.calcECOperator()
        op.applyElectricBC(electric)
        op.applyMagneticBC(magnetic)
        let engine = Engine.make(op: op)

        // volt is E·dl. The last y line starts no edge inside the cavity.
        for i in xLines.indices {
            for k in zLines.indices {
                let field = sin(.pi * xLines[i] / a) * sin(.pi * zLines[k] / d)
                for j in 0..<(yLines.count - 1) {
                    engine.setVolt(1, i, j, k, field * cell)
                }
            }
        }

        let probe = (nearestIndex(xLines, probeX), yLines.count / 2, zLines.count / 2)
        var samples: [Double] = []
        samples.reserveCapacity(steps)
        for _ in 0..<steps {
            engine.iterateTS(1)
            samples.append(engine.getVolt(1, probe.0, probe.1, probe.2))
        }

        var crossings: [Double] = []
        for i in 0..<(samples.count - 1) where (samples[i] < 0) != (samples[i + 1] < 0) {
            crossings.append(Double(i) + samples[i] / (samples[i] - samples[i + 1]))
        }
        XCTAssertGreaterThan(crossings.count, 10, "the cavity must actually ring")
        let first = try XCTUnwrap(crossings.first)
        let last = try XCTUnwrap(crossings.last)
        return Double(crossings.count - 1) / (2 * (last - first) * op.dT)
    }

    /// With the old walls every upper face was magnetic, which is a different
    /// cavity with a different spectrum entirely.
    func testElectricCavityResonatesAtTheAnalyticFrequency() throws {
        let hertz = try te101Hertz(
            xLines: lines(from: 0, to: a), electric: everyFace, magnetic: noFace, probeX: a / 4
        )
        // Yee dispersion at 14–20 cells per half wavelength is about −0.1 %.
        XCTAssertEqual(hertz / analyticTE101Hertz, 1, accuracy: 0.005)
    }

    /// A magnetic wall is a symmetry plane for fields even across it, and
    /// TE101 is even about x = a/2. Half the cavity closed there by a magnetic
    /// wall must therefore ring at the full cavity's frequency — to rounding,
    /// because the image reproduces the full grid's update exactly.
    func testMagneticWallOnAnUpperFaceIsAnExactSymmetryPlane() throws {
        let full = try te101Hertz(
            xLines: lines(from: 0, to: a), electric: everyFace, magnetic: noFace, probeX: a / 4
        )

        var electric = everyFace, magnetic = noFace
        electric[1] = false
        magnetic[1] = true
        let half = try te101Hertz(
            xLines: lines(from: 0, to: a / 2), electric: electric, magnetic: magnetic, probeX: a / 4
        )

        XCTAssertEqual(half / full, 1, accuracy: 1e-6)
    }

    func testMagneticWallOnALowerFaceIsAnExactSymmetryPlane() throws {
        let full = try te101Hertz(
            xLines: lines(from: 0, to: a), electric: everyFace, magnetic: noFace, probeX: 3 * a / 4
        )

        var electric = everyFace, magnetic = noFace
        electric[0] = false
        magnetic[0] = true
        let half = try te101Hertz(
            xLines: lines(from: a / 2, to: a), electric: electric, magnetic: magnetic, probeX: 3 * a / 4
        )

        XCTAssertEqual(half / full, 1, accuracy: 1e-6)
    }

    // MARK: - Mapping from the model

    /// Every face that is not a magnetic wall must end on an electric one,
    /// absorbing and periodic faces included — those used to be left to the
    /// engine's bare edges.
    func testEveryFaceThatIsNotMagneticEndsOnAnElectricWall() {
        let walls = SimulationRunner.wallFaces(
            BoundarySettings(xMin: .pml, xMax: .electric, yMin: .magnetic, yMax: .periodic, zMin: .pml, zMax: .magnetic)
        )
        XCTAssertEqual(walls.magnetic, [false, false, true, false, false, true])
        XCTAssertEqual(walls.electric, [true, true, false, true, true, false])
    }
}
