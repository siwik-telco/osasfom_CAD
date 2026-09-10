import XCTest
import osasfom_cadCore
@testable import osasfom_cadSolver

/// Regression tests for a lumped port whose feed gap is wider than one cell.
///
/// `GridMesher` pins a fixed line at both port terminals, and the port setup
/// used to read that as "the gap therefore spans exactly one Yee edge". It
/// does not: `fillInterval` keeps subdividing the span between two fixed
/// lines down to the target cell size, so an 8 mm gap on a ~3 mm mesh becomes
/// three cells. The old code loaded only the first of them, which put the
/// 50 Ω resistor and the generator against one terminal with bare vacuum
/// across the remaining two thirds of the gap, and integrated V over a third
/// of the path — both Zin and S11 came out wrong by roughly that factor.
final class LumpedPortGapEdgesTests: XCTestCase {

    /// A centre-fed dipole with `gap` mm between the arms.
    ///
    /// 5 GHz over `cellsPerWavelength` lines is what sets the cell size, and
    /// at 20 lines it reproduces the reported case exactly: a 2.997925 mm
    /// effective max cell, which `fillInterval` fits into an 8 mm gap three
    /// times.
    private func makeState(gap: Double, cellsPerWavelength: Double) -> CADModelState {
        var state = CADModelState(name: "Dipole", lengthUnit: .millimeter)
        let armLength = 140.0, radius = 8.0

        state.bodies = [
            CADBody(
                name: "Arm+Y",
                primitive: .cylinder(
                    CylinderSpec(
                        radius: Expression(radius),
                        begin: Expression(gap / 2),
                        end: Expression(gap / 2 + armLength),
                        axis: .y
                    )
                ),
                materialID: MaterialLibrary.pecID
            ),
            CADBody(
                name: "Arm-Y",
                primitive: .cylinder(
                    CylinderSpec(
                        radius: Expression(radius),
                        begin: Expression(-(gap / 2 + armLength)),
                        end: Expression(-gap / 2),
                        axis: .y
                    )
                ),
                materialID: MaterialLibrary.pecID
            )
        ]
        state.simulation.domain = DomainSettings(mode: .automatic, padding: Vector3Expression(Vec3(repeating: 150)))
        state.simulation.frequency = FrequencyRange(minimumHertz: 350e6, maximumHertz: 5e9)
        state.simulation.mesh = MeshSettings(cellsPerWavelength: cellsPerWavelength)
        state.simulation.ports = [
            SimulationPort(
                name: "Feed",
                begin: Vector3Expression(x: Expression(0), y: Expression(-gap / 2), z: Expression(0)),
                end: Vector3Expression(x: Expression(0), y: Expression(gap / 2), z: Expression(0)),
                direction: .y,
                impedanceOhm: 50
            )
        ]
        return state
    }

    private func edges(gap: Double, cellsPerWavelength: Double) throws -> (
        edges: [LumpedPortExtension.Edge],
        lines: GridMesher.Lines,
        port: ResolvedPort
    ) {
        let state = makeState(gap: gap, cellsPerWavelength: cellsPerWavelength)
        let resolved = ModelResolver.resolve(state)
        let unit = state.lengthUnit
        let lines = try XCTUnwrap(
            GridMesher.makeDiscLines(resolved: resolved, setup: state.simulation, unit: unit)
        )
        let port = try XCTUnwrap(resolved.simulation.ports.first)
        return (LumpedPortExtension.gridEdges(for: port, unit: unit, lines: lines), lines, port)
    }

    /// The whole point: a gap the mesher splits must hand back every edge in
    /// it, and those edges must tile the gap exactly — no vacuum left over.
    func testGapWiderThanOneCellCoversEveryEdge() throws {
        let gap = 8.0
        let (edges, lines, port) = try edges(gap: gap, cellsPerWavelength: 20.0)
        let yLines = lines.metersLines[1]

        XCTAssertEqual(edges.count, 3, "an 8 mm gap on a 2.997925 mm mesh is three cells")

        let first = try XCTUnwrap(edges.first)
        let last = try XCTUnwrap(edges.last)
        let start = yLines[first.pos.1]
        let stop = yLines[last.pos.1 + 1]

        XCTAssertEqual(start, port.bounds.minimum.y / 1000, accuracy: 1e-12, "must start at the -Y terminal")
        XCTAssertEqual(stop, port.bounds.maximum.y / 1000, accuracy: 1e-12, "must reach the +Y terminal")

        // Contiguous chain, no gaps or repeats.
        for (previous, next) in zip(edges, edges.dropFirst()) {
            XCTAssertEqual(next.pos.1, previous.pos.1 + 1)
            XCTAssertEqual(next.pos.0, previous.pos.0)
            XCTAssertEqual(next.pos.2, previous.pos.2)
        }
    }

    /// Shares are the split of the source voltage and of the reference
    /// impedance, so they have to sum to exactly one — otherwise the port
    /// neither excites at the requested amplitude nor terminates in 50 Ω.
    func testSharesSumToOneAndMatchEdgeLengths() throws {
        let gap = 8.0
        let (edges, lines, _) = try edges(gap: gap, cellsPerWavelength: 20.0)
        let yLines = lines.metersLines[1]

        XCTAssertEqual(edges.reduce(0) { $0 + $1.share }, 1.0, accuracy: 1e-12)

        let total = edges.reduce(0.0) { $0 + (yLines[$1.pos.1 + 1] - yLines[$1.pos.1]) }
        XCTAssertEqual(total, gap / 1000, accuracy: 1e-12, "the edges must tile the whole gap")

        for edge in edges {
            let length = yLines[edge.pos.1 + 1] - yLines[edge.pos.1]
            XCTAssertEqual(edge.share, length / total, accuracy: 1e-12)
        }

        // Series resistances weighted by share add back up to the port's
        // reference impedance, however the mesher divided the gap.
        let impedance = 50.0
        XCTAssertEqual(edges.reduce(0) { $0 + impedance * $1.share }, impedance, accuracy: 1e-9)
    }

    /// The transverse coordinates are degenerate, so both must land on the
    /// port's own axis rather than drift to a neighbouring line.
    func testEdgesSitOnThePortAxis() throws {
        let (edges, lines, _) = try edges(gap: 8.0, cellsPerWavelength: 20.0)

        for edge in edges {
            XCTAssertEqual(lines.metersLines[0][edge.pos.0], 0, accuracy: 1e-12)
            XCTAssertEqual(lines.metersLines[2][edge.pos.2], 0, accuracy: 1e-12)
        }
    }

    /// End-to-end guard on the multi-edge path. A passive one-port can never
    /// reflect more power than it receives, so |S11| > 0 dB anywhere means
    /// the port is producing energy — which is exactly what a mis-weighted
    /// series resistance or a mis-split source voltage would do. The single
    /// -edge path has the same guard in `DipoleReturnLossTests`; this is its
    /// counterpart for a gap the mesher subdivides.
    ///
    /// A refinement box over the feed makes the gap four cells while the rest
    /// of the domain stays coarse, so the run is still cheap.
    @MainActor
    func testSubdividedGapStaysPassiveEndToEnd() async throws {
        var state = makeState(gap: 6.0, cellsPerWavelength: 10.0)
        state.simulation.frequency = FrequencyRange(minimumHertz: 0.8e9, maximumHertz: 2.0e9)
        state.simulation.mesh.refinements = [
            MeshRefinement(
                name: "Feed",
                region: BoundsExpression(
                    xMin: Expression(-4), xMax: Expression(4),
                    yMin: Expression(-4), yMax: Expression(4),
                    zMin: Expression(-4), zMax: Expression(4)
                ),
                targetCellSize: Expression(1.5)
            )
        ]
        state.simulation.solver.maximumTimeSteps = 15000

        let resolved = ModelResolver.resolve(state)
        let lines = try XCTUnwrap(
            GridMesher.makeDiscLines(resolved: resolved, setup: state.simulation, unit: state.lengthUnit)
        )
        let port = try XCTUnwrap(resolved.simulation.ports.first)
        let edges = LumpedPortExtension.gridEdges(for: port, unit: state.lengthUnit, lines: lines)
        XCTAssertGreaterThan(edges.count, 1, "the refinement must actually subdivide the gap")

        let runner = SimulationRunner()
        runner.spectrumPointCount = 25
        let task = try runner.run(document: CADDocument(state: state))
        await task.value

        XCTAssertFalse(runner.s11Spectrum.isEmpty)
        for point in runner.s11Spectrum {
            XCTAssertLessThanOrEqual(
                point.decibels,
                0.01,
                "S11 > 0 dB at \(point.hertz / 1e9) GHz is non-physical for a passive port"
            )
        }
    }

    /// A gap the mesher does not subdivide still has to produce exactly one
    /// edge carrying the whole port — the case the old code assumed always
    /// held, and the only one it got right.
    func testGapNarrowerThanOneCellStillYieldsOneEdge() throws {
        let (edges, lines, port) = try edges(gap: 0.5, cellsPerWavelength: 10.0)
        let yLines = lines.metersLines[1]

        XCTAssertEqual(edges.count, 1)
        let edge = try XCTUnwrap(edges.first)
        XCTAssertEqual(edge.share, 1.0, accuracy: 1e-12)
        XCTAssertEqual(yLines[edge.pos.1], port.bounds.minimum.y / 1000, accuracy: 1e-12)
    }
}
