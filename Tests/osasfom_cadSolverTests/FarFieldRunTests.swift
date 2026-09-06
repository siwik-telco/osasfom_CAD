import XCTest
import osasfom_cadCore
@testable import osasfom_cadSolver

/// End-to-end far field: a real FDTD run, through the near-to-far-field
/// surface, out to a pattern. The unit tests pin the maths; this pins the
/// physics, against an antenna whose answer is known independently.
@MainActor
final class FarFieldRunTests: XCTestCase {

    /// A half-wave dipole at 1 GHz: two thin PEC arms either side of a
    /// lumped feed. Padded by a full wavelength so the near-to-far-field
    /// surface has room to sit outside the 8-cell PML and still enclose the
    /// antenna. Its pattern is the textbook doughnut — a null along the
    /// wire, peak broadside, directivity ≈ 2.15 dBi.
    private func makeDipoleDocument(farField: FarFieldSettings) -> CADDocument {
        var state = CADModelState(name: "Dipole", lengthUnit: .millimeter)
        let armLength = 68.0, gap = 6.0, radius = 2.0

        state.bodies = [
            CADBody(
                name: "Arm+Y",
                primitive: .cylinder(
                    CylinderSpec(radius: Expression(radius), begin: Expression(gap / 2), end: Expression(gap / 2 + armLength), axis: .y)
                ),
                materialID: MaterialLibrary.pecID
            ),
            CADBody(
                name: "Arm-Y",
                primitive: .cylinder(
                    CylinderSpec(radius: Expression(radius), begin: Expression(-(gap / 2 + armLength)), end: Expression(-gap / 2), axis: .y)
                ),
                materialID: MaterialLibrary.pecID
            )
        ]
        state.simulation.domain = DomainSettings(mode: .automatic, padding: Vector3Expression(Vec3(repeating: 300)))
        state.simulation.frequency = FrequencyRange(minimumHertz: 0.7e9, maximumHertz: 1.3e9)
        state.simulation.mesh = MeshSettings(cellsPerWavelength: 12)
        state.simulation.ports = [
            SimulationPort(
                name: "Feed",
                begin: Vector3Expression(x: Expression(0), y: Expression(-gap / 2), z: Expression(0)),
                end: Vector3Expression(x: Expression(0), y: Expression(gap / 2), z: Expression(0)),
                direction: .y,
                impedanceOhm: 73
            )
        ]
        state.simulation.solver.maximumTimeSteps = 6000
        state.simulation.farField = farField
        return CADDocument(state: state)
    }

    func testDipoleRunProducesTheExpectedDoughnutPattern() async throws {
        let document = makeDipoleDocument(
            farField: FarFieldSettings(isEnabled: true, frequenciesHertz: [1.0e9], angularStepDegrees: 5)
        )
        let runner = SimulationRunner()
        await (try runner.run(document: document)).value

        let pattern = try XCTUnwrap(runner.farFieldPatterns.first, "a far-field pattern should have been produced")
        XCTAssertEqual(pattern.hertz, 1.0e9)
        XCTAssertGreaterThan(pattern.radiatedPowerWatts, 0, "the surface integral must see real radiated power")

        // The wire lies along Y. In spherical terms that is θ=90°, φ=90°,
        // which must be a deep null; broadside (θ=90°, φ=0°) must be the peak.
        let broadside = pattern.cut(atThetaDegrees: 90, quantity: .normalized)
        func value(at phi: Double) throws -> Double {
            try XCTUnwrap(broadside.points.min { abs($0.angleDegrees - phi) < abs($1.angleDegrees - phi) }).decibels
        }

        XCTAssertEqual(try value(at: 0), 0, accuracy: 0.6, "broadside is the peak")
        XCTAssertLessThan(try value(at: 90), -12, "along the wire must be a deep null")

        // Directivity of a half-wave dipole is 2.15 dBi. A coarse grid with an
        // approximate absorbing layer will not nail that, but it should be in
        // the right neighbourhood rather than an order out.
        XCTAssertEqual(pattern.peakDirectivityDbi, 2.15, accuracy: 2.0)
    }

    func testFarFieldIsNotRecordedUnlessAskedFor() async throws {
        let document = makeDipoleDocument(farField: FarFieldSettings(isEnabled: false))
        let runner = SimulationRunner()
        await (try runner.run(document: document)).value

        XCTAssertTrue(runner.farFieldPatterns.isEmpty, "recording is opt-in")
        XCTAssertFalse(runner.s11Spectrum.isEmpty, "the ordinary sweep still runs")
    }

    /// Enabling without naming frequencies should still work — the band
    /// centre is the useful default.
    func testEnablingWithoutFrequenciesRecordsTheBandCentre() async throws {
        let document = makeDipoleDocument(farField: FarFieldSettings(isEnabled: true))
        let runner = SimulationRunner()
        await (try runner.run(document: document)).value

        let pattern = try XCTUnwrap(runner.farFieldPatterns.first)
        XCTAssertEqual(pattern.hertz, 1.0e9, accuracy: 1, "band centre of 0.7–1.3 GHz")
    }

    func testPatternCarriesPortDataSoGainIsAvailable() async throws {
        let document = makeDipoleDocument(
            farField: FarFieldSettings(isEnabled: true, frequenciesHertz: [1.0e9], angularStepDegrees: 10)
        )
        let runner = SimulationRunner()
        await (try runner.run(document: document)).value

        let pattern = try XCTUnwrap(runner.farFieldPatterns.first)
        XCTAssertNotNil(pattern.acceptedPowerWatts, "the excited port supplies accepted power")
        XCTAssertNotNil(pattern.reflectionCoefficient, "and its S11 supplies the mismatch term")
        XCTAssertTrue(pattern.supports(.realizedGain))

        let efficiency = try XCTUnwrap(pattern.radiationEfficiency)
        XCTAssertGreaterThan(efficiency, 0)
        XCTAssertLessThanOrEqual(efficiency, 1)
        // A PEC dipole in vacuum is lossless, so gain should track directivity.
        XCTAssertLessThanOrEqual(try XCTUnwrap(pattern.peakGainDbi), pattern.peakDirectivityDbi + 1e-9)
    }
}
