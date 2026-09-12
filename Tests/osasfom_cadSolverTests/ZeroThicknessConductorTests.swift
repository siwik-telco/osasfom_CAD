import XCTest
import osasfom_cadCore
@testable import osasfom_cadSolver

/// Infinitely thin perfect conductors — the natural way to draw a PCB antenna,
/// and what `ShapeContainment` keeps sheets as on purpose so `snapToBodyEdges`
/// can land a grid line on them.
///
/// They used to be invisible to the physics. `calcEffMatPos` averages material
/// over cell *volumes*, and a surface has none: probing a patch drawn this way
/// gave σ = 1e7 exactly on the plane and 0 one nanometre off it, while the
/// quarter-cell sampler only ever asks at quarter-cell offsets. A patch fed
/// against one reflected everything — S11 flat at -0.01 dB across the band,
/// the signature of a port driving a resistor sitting in plain dielectric.
///
/// They are now imposed the standard way instead: tangential E vanishes on a
/// perfect conductor, so the edges lying in the sheet's plane are forced to
/// zero.
final class ZeroThicknessConductorTests: XCTestCase {

    private let h = 1.575, patchW = 48.97, patchL = 40.98, board = 68.0

    private func makeState(rotated: Bool = false) -> CADModelState {
        var state = CADModelState(name: "Patch", lengthUnit: .millimeter)
        var patch = CADBody(
            name: "Patch",
            primitive: .sheet(SheetSpec(
                width: Expression(patchW), depth: Expression(patchL),
                begin: Expression(h), end: Expression(h), normal: .z
            )),
            materialID: MaterialLibrary.pecID,
            priority: 2
        )
        if rotated { patch.transform.rotationDegrees = Vector3Expression(Vec3(x: 0, y: 20, z: 0)) }

        state.bodies = [
            CADBody(
                name: "Substrate",
                primitive: .box(BoxSpec(
                    beginX: Expression(-board / 2), endX: Expression(board / 2),
                    beginY: Expression(-board / 2), endY: Expression(board / 2),
                    beginZ: Expression(0), endZ: Expression(h)
                )),
                materialID: MaterialLibrary.fr4ID,
                priority: 0
            ),
            CADBody(
                name: "Ground",
                primitive: .sheet(SheetSpec(
                    width: Expression(board), depth: Expression(board),
                    begin: Expression(0), end: Expression(0), normal: .z
                )),
                materialID: MaterialLibrary.pecID,
                priority: 2
            ),
            patch
        ]
        state.simulation.domain = DomainSettings(mode: .automatic, padding: Vector3Expression(Vec3(repeating: 62)))
        state.simulation.frequency = FrequencyRange(minimumHertz: 2.0e9, maximumHertz: 2.9e9)
        state.simulation.mesh = MeshSettings(
            cellsPerWavelength: 10,
            fixedLinesZ: [Expression(h / 4), Expression(h / 2), Expression(3 * h / 4)]
        )
        state.simulation.ports = [
            SimulationPort(
                name: "Feed",
                begin: Vector3Expression(x: Expression(0), y: Expression(6.18), z: Expression(0)),
                end: Vector3Expression(x: Expression(0), y: Expression(6.18), z: Expression(h)),
                direction: .z,
                impedanceOhm: 50
            )
        ]
        return state
    }

    private func edges(_ state: CADModelState, warnings: inout [String]) throws
        -> [(direction: Int, pos: (Int, Int, Int))] {
        let resolved = ModelResolver.resolve(state)
        XCTAssertEqual(resolved.errorCount, 0, "\(resolved.diagnostics.errors)")
        let lines = try XCTUnwrap(
            GridMesher.makeDiscLines(resolved: resolved, setup: state.simulation, unit: state.lengthUnit)
        )
        return ZeroThicknessConductors.edges(
            bodies: resolved.bodies,
            materials: state.materials,
            unit: state.lengthUnit,
            lines: lines,
            maximumHertz: state.simulation.frequency.maximumHertz,
            warnings: &warnings
        )
    }

    /// Both sheets must claim edges, and only in-plane ones: a conductor
    /// constrains the *tangential* field, never the normal component.
    func testSheetsClaimTheirInPlaneEdges() throws {
        var warnings: [String] = []
        let edges = try edges(makeState(), warnings: &warnings)

        XCTAssertTrue(warnings.isEmpty, "\(warnings)")
        XCTAssertGreaterThan(edges.count, 100, "a 49x41 mm patch and a 68 mm ground cover many edges")
        XCTAssertTrue(
            edges.allSatisfy { $0.direction != 2 },
            "both sheets have a Z normal, so no Z-directed edge is tangential to them"
        )
        // Both in-plane directions are represented.
        XCTAssertTrue(edges.contains { $0.direction == 0 })
        XCTAssertTrue(edges.contains { $0.direction == 1 })
    }

    /// A body the solver cannot represent must say so rather than vanish. A
    /// tilted plane does not lie along grid edges, and staircasing it silently
    /// would be worse than declining.
    func testRotatedSheetIsReportedRatherThanSilentlyDropped() throws {
        var warnings: [String] = []
        _ = try edges(makeState(rotated: true), warnings: &warnings)

        XCTAssertEqual(warnings.count, 1)
        let warning = try XCTUnwrap(warnings.first)
        XCTAssertTrue(warning.contains("Patch"), warning)
        XCTAssertTrue(warning.contains("rotated"), warning)
    }

    /// End to end: the patch has to actually radiate. Before this, S11 was
    /// flat within 0.1 dB of zero across the whole band.
    @MainActor
    func testSheetPatchActuallyResonates() async throws {
        var state = makeState()
        state.simulation.solver.maximumTimeSteps = 40_000
        let runner = SimulationRunner()
        runner.spectrumPointCount = 91
        await (try runner.run(document: CADDocument(state: state))).value

        let deepest = try XCTUnwrap(runner.s11Spectrum.min { $0.decibels < $1.decibels })
        XCTAssertLessThan(
            deepest.decibels, -6,
            "a fed patch built from sheets must resonate; deepest was \(deepest.decibels) dB "
                + "at \(deepest.hertz / 1e9) GHz"
        )
        for point in runner.s11Spectrum {
            XCTAssertLessThanOrEqual(point.decibels, 0.01, "passivity at \(point.hertz / 1e9) GHz")
        }
    }

    // MARK: - Conductors other than PEC

    /// A sheet assigned Copper — what most people pick for PCB metal — used to
    /// get no edges, and had no volume for the material path to find, so it
    /// vanished from the simulation without a word. It must be imposed
    /// exactly like PEC.
    func testCopperSheetsClaimTheSameEdgesAsPEC() throws {
        func key(_ edge: (direction: Int, pos: (Int, Int, Int))) -> String {
            "\(edge.direction):\(edge.pos.0),\(edge.pos.1),\(edge.pos.2)"
        }

        var pecWarnings: [String] = []
        let pec = try edges(makeState(), warnings: &pecWarnings)

        var copperState = makeState()
        for index in copperState.bodies.indices where copperState.bodies[index].materialID == MaterialLibrary.pecID {
            copperState.bodies[index].materialID = MaterialLibrary.copperID
        }
        var copperWarnings: [String] = []
        let copper = try edges(copperState, warnings: &copperWarnings)

        XCTAssertTrue(copperWarnings.isEmpty, "\(copperWarnings)")
        XCTAssertFalse(copper.isEmpty)
        XCTAssertEqual(Set(copper.map(key)), Set(pec.map(key)))
    }

    /// A surface of no thickness cannot hold a dielectric, so a zero-thickness
    /// FR-4 sheet has nothing to add — but that has to be said rather than
    /// discovered later from a result that quietly ignores it.
    func testNonConductingSheetIsReportedRatherThanSilentlyIgnored() throws {
        var baselineWarnings: [String] = []
        let baseline = try edges(makeState(), warnings: &baselineWarnings)

        var state = makeState()
        // Same outline as the patch, so the mesh — and every other edge — is
        // unchanged.
        state.bodies.append(
            CADBody(
                name: "Coverlay",
                primitive: .sheet(SheetSpec(
                    width: Expression(patchW), depth: Expression(patchL),
                    begin: Expression(h), end: Expression(h), normal: .z
                )),
                materialID: MaterialLibrary.fr4ID,
                priority: 1
            )
        )
        var warnings: [String] = []
        let withSheet = try edges(state, warnings: &warnings)

        XCTAssertEqual(withSheet.count, baseline.count, "an FR-4 sheet must not claim edges")
        XCTAssertEqual(warnings.count, 1)
        let warning = try XCTUnwrap(warnings.first)
        XCTAssertTrue(warning.contains("Coverlay"), warning)
        XCTAssertTrue(warning.contains("not a conductor"), warning)
    }

    /// The line between "conducts like PEC" and "does not" is σ/ωε at the top
    /// of the band: metals qualify, everything else in the library does not.
    func testConductorClassificationFollowsTheLossTangentAtTheTopOfTheBand() {
        let library = Dictionary(uniqueKeysWithValues: MaterialLibrary.defaults().map { ($0.id, $0) })
        let top = 5e9

        for id in [MaterialLibrary.pecID, MaterialLibrary.copperID, MaterialLibrary.aluminumID] {
            let material = library[id]
            XCTAssertTrue(material?.actsAsPerfectElectricConductor(upToHertz: top) == true, material?.name ?? "")
        }
        for id in [MaterialLibrary.vacuumID, MaterialLibrary.fr4ID, MaterialLibrary.rogers4003CID, MaterialLibrary.ptfeID] {
            let material = library[id]
            XCTAssertTrue(material?.actsAsPerfectElectricConductor(upToHertz: top) == false, material?.name ?? "")
        }

        let resistive = MaterialDefinition(name: "Resistive film", color: .neutralGray, electricConductivity: 1e3)
        XCTAssertFalse(resistive.actsAsPerfectElectricConductor(upToHertz: top))
        let pmc = MaterialDefinition(name: "PMC", color: .neutralGray, kind: .perfectMagneticConductor)
        XCTAssertFalse(pmc.actsAsPerfectElectricConductor(upToHertz: top))
    }
}
