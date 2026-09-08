import XCTest

@testable import osasfom_cadCore

/// Sizing the domain and the mesh from the frequency range alone. These are
/// the numbers every run depends on, and getting them from the wrong end of
/// the band — or from a material nothing uses — is silent and expensive.
final class AutomaticDomainTests: XCTestCase {

    private let c = 299_792_458.0

    private func makeState(
        minimumHertz: Double = 400e6,
        maximumHertz: Double = 600e6,
        paddingWavelengths: Double = 0.5,
        cellsPerWavelength: Double = 20,
        bodyMaterial: UUID = MaterialLibrary.pecID,
        farField: Bool = false,
        pmlCells: Int = 8
    ) -> CADModelState {
        var state = CADModelState(name: "Auto", lengthUnit: .millimeter)
        state.bodies = [
            CADBody(
                name: "Element",
                primitive: .box(BoxSpec(
                    beginX: Expression(-150), endX: Expression(150),
                    beginY: Expression(-5), endY: Expression(5),
                    beginZ: Expression(-5), endZ: Expression(5)
                )),
                materialID: bodyMaterial
            )
        ]
        state.simulation.frequency = FrequencyRange(minimumHertz: minimumHertz, maximumHertz: maximumHertz)
        state.simulation.domain = DomainSettings(mode: .fromFrequency, paddingWavelengths: paddingWavelengths)
        state.simulation.mesh = MeshSettings(cellsPerWavelength: cellsPerWavelength)
        state.simulation.farField = FarFieldSettings(isEnabled: farField)
        state.simulation.boundaries.pmlCellCount = pmlCells
        return state
    }

    private func resolve(_ state: CADModelState) -> ResolvedModel {
        ModelResolver.resolve(state)
    }

    // MARK: - Domain

    /// Padding follows the *longest* wavelength — the lowest frequency — not
    /// the shortest. Sizing on f_max would look tighter and be wrong.
    func testPaddingComesFromTheLowestFrequency() throws {
        let resolved = resolve(makeState(minimumHertz: 400e6, maximumHertz: 600e6))
        let domain = try XCTUnwrap(resolved.simulation.domain)

        let longestWavelengthMM = c / 400e6 * 1000    // 749.5 mm
        let expectedPadding = 0.5 * longestWavelengthMM

        // Body spans 300mm in X, padded on both sides.
        XCTAssertEqual(domain.size.x, 300 + 2 * expectedPadding, accuracy: 0.01)
        XCTAssertEqual(domain.size.y, 10 + 2 * expectedPadding, accuracy: 0.01)
    }

    func testPaddingScalesWithTheWavelengthMultiplier() throws {
        let half = try XCTUnwrap(resolve(makeState(paddingWavelengths: 0.5)).simulation.domain)
        let full = try XCTUnwrap(resolve(makeState(paddingWavelengths: 1.0)).simulation.domain)

        let bodyX = 300.0
        XCTAssertEqual(full.size.x - bodyX, 2 * (half.size.x - bodyX), accuracy: 0.01)
    }

    /// Lowering the band lengthens the wavelength, so the domain must grow.
    func testALowerBandProducesALargerDomain() throws {
        let high = try XCTUnwrap(resolve(makeState(minimumHertz: 2e9, maximumHertz: 3e9)).simulation.domain)
        let low = try XCTUnwrap(resolve(makeState(minimumHertz: 400e6, maximumHertz: 600e6)).simulation.domain)

        XCTAssertGreaterThan(low.size.x, high.size.x)
    }

    func testAnInvalidFrequencyRangeIsReportedRatherThanGuessed() {
        var state = makeState()
        state.simulation.frequency = FrequencyRange(minimumHertz: 0, maximumHertz: 0)
        let resolved = resolve(state)

        XCTAssertNil(resolved.simulation.domain)
        XCTAssertTrue(
            resolved.diagnostics.errors.contains { $0.message.contains("frequency range") },
            "the user should be told why there is no domain"
        )
    }

    // MARK: - Mesh

    /// The cell size comes from the highest frequency — the shortest
    /// wavelength — which is the opposite end from the domain padding.
    func testCellSizeComesFromTheHighestFrequency() throws {
        let resolved = resolve(makeState(minimumHertz: 400e6, maximumHertz: 600e6, cellsPerWavelength: 20))
        let cell = try XCTUnwrap(resolved.simulation.mesh.wavelengthLimitedCellSize)

        let shortestWavelengthMM = c / 600e6 * 1000    // 499.7 mm
        XCTAssertEqual(cell, shortestWavelengthMM / 20, accuracy: 1e-6)
    }

    /// The bug this fixes: an unused FR-4 in the default material library was
    /// dividing the cell size by its refractive index, making an all-metal
    /// model in air twice as fine — and eight times as many cells — for
    /// nothing.
    func testAnUnusedDielectricDoesNotShrinkTheCellSize() throws {
        let air = resolve(makeState(bodyMaterial: MaterialLibrary.pecID))
        let cell = try XCTUnwrap(air.simulation.mesh.wavelengthLimitedCellSize)

        let shortestWavelengthMM = c / 600e6 * 1000
        XCTAssertEqual(cell, shortestWavelengthMM / 20, accuracy: 1e-6, "n = 1, not FR-4's 2.07")
    }

    /// A dielectric that *is* used must still refine the mesh.
    func testAUsedDielectricStillShrinksTheCellSize() throws {
        let withFR4 = resolve(makeState(bodyMaterial: MaterialLibrary.fr4ID))
        let cell = try XCTUnwrap(withFR4.simulation.mesh.wavelengthLimitedCellSize)

        let shortestWavelengthMM = c / 600e6 * 1000
        let index = (4.3 as Double).squareRoot()
        XCTAssertEqual(cell, shortestWavelengthMM / index / 20, accuracy: 1e-3)
        XCTAssertLessThan(cell, shortestWavelengthMM / 20, "a real substrate does refine the mesh")
    }

    // MARK: - Far-field clearance

    /// Automatic sizing must not produce a domain too small for the far-field
    /// surface it was told to record.
    func testPaddingWidensSoAFarFieldSurfaceFits() throws {
        // A tight multiplier that alone would leave nowhere for the surface.
        let tight = makeState(paddingWavelengths: 0.05, farField: true, pmlCells: 8)
        let resolved = resolve(tight)
        let domain = try XCTUnwrap(resolved.simulation.domain)
        let cell = try XCTUnwrap(resolved.simulation.mesh.effectiveMaxCellSize)

        let paddingPerSide = (domain.size.y - 10) / 2
        let cellsPerSide = paddingPerSide / cell
        XCTAssertGreaterThanOrEqual(cellsPerSide, 14, "8 PML + 2 inset + 4 interior")

        XCTAssertTrue(
            resolved.diagnostics.warnings.contains { $0.message.contains("far-field surface") },
            "widening it silently would be worse than saying so"
        )
    }

    /// Without far field there is nothing to make room for, so the multiplier
    /// is respected exactly.
    func testTightPaddingIsRespectedWhenNoFarFieldIsRecorded() throws {
        let resolved = resolve(makeState(paddingWavelengths: 0.05, farField: false))
        let domain = try XCTUnwrap(resolved.simulation.domain)

        let expected = 0.05 * (c / 400e6 * 1000)
        XCTAssertEqual((domain.size.y - 10) / 2, expected, accuracy: 0.01)
    }

    /// Generous padding already clears the absorber, so nothing is changed.
    func testAmpleePaddingIsLeftAlone() throws {
        let resolved = resolve(makeState(paddingWavelengths: 1.0, farField: true))
        let domain = try XCTUnwrap(resolved.simulation.domain)

        let expected = 1.0 * (c / 400e6 * 1000)
        XCTAssertEqual((domain.size.y - 10) / 2, expected, accuracy: 0.01)
        XCTAssertFalse(resolved.diagnostics.warnings.contains { $0.message.contains("far-field surface") })
    }
}
