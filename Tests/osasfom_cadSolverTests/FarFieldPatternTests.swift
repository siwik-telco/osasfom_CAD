import XCTest
@testable import osasfom_cadSolver

/// The pattern maths, checked against antennas whose answers are known in
/// closed form. Directivity is an integral over the whole sphere, so an error
/// in the solid-angle weighting shows up as a wrong number here long before
/// it shows up as a slightly odd-looking plot.
final class FarFieldPatternTests: XCTestCase {

    /// Builds a pattern from an analytic U(θ, φ).
    private func pattern(
        stepDegrees: Double = 2,
        hertz: Double = 2.4e9,
        acceptedPowerWatts: Double? = nil,
        reflectionCoefficient: Double? = nil,
        intensity: (_ thetaDegrees: Double, _ phiDegrees: Double) -> Double
    ) -> FarFieldPattern {
        let thetas = stride(from: 0.0, through: 180.0, by: stepDegrees).map { $0 }
        let phis = stride(from: 0.0, to: 360.0, by: stepDegrees).map { $0 }
        let grid = thetas.map { theta in phis.map { phi in intensity(theta, phi) } }
        return FarFieldPattern(
            hertz: hertz,
            thetaDegrees: thetas,
            phiDegrees: phis,
            radiationIntensity: grid,
            acceptedPowerWatts: acceptedPowerWatts,
            reflectionCoefficient: reflectionCoefficient
        )
    }

    private func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }

    // MARK: - Directivity against closed forms

    func testIsotropicRadiatorHasUnityDirectivity() {
        let isotropic = pattern { _, _ in 1.0 }

        XCTAssertEqual(isotropic.peakDirectivity, 1.0, accuracy: 1e-3)
        XCTAssertEqual(isotropic.peakDirectivityDbi, 0, accuracy: 0.01)
        // ∮ dΩ = 4π.
        XCTAssertEqual(isotropic.radiatedPowerWatts, 4 * .pi, accuracy: 1e-3)
    }

    /// A Hertzian (short) dipole radiates as sin²θ, with directivity exactly
    /// 3/2 — 1.76 dBi.
    func testShortDipoleDirectivityIsOnePointFive() {
        let dipole = pattern { theta, _ in
            let s = sin(self.radians(theta))
            return s * s
        }

        XCTAssertEqual(dipole.peakDirectivity, 1.5, accuracy: 2e-3)
        XCTAssertEqual(dipole.peakDirectivityDbi, 1.76, accuracy: 0.02)
    }

    /// A half-wave dipole's directivity is 1.6409… (2.15 dBi).
    func testHalfWaveDipoleDirectivity() {
        let dipole = pattern { theta, _ in
            let t = self.radians(theta)
            guard sin(t) > 1e-9 else { return 0 }
            let numerator = cos(.pi / 2 * cos(t))
            return pow(numerator / sin(t), 2)
        }

        XCTAssertEqual(dipole.peakDirectivityDbi, 2.15, accuracy: 0.03)
    }

    /// cos²θ over the upper hemisphere only — a broadside patch-like pattern
    /// with a ground plane. ∮ cos²θ over a hemisphere = 2π/3, so D = 6.
    func testHemisphericalCosineSquaredPatternHasDirectivitySix() {
        let patchLike = pattern { theta, _ in
            guard theta <= 90 else { return 0 }
            let c = cos(self.radians(theta))
            return c * c
        }

        XCTAssertEqual(patchLike.peakDirectivity, 6, accuracy: 0.02)
        XCTAssertEqual(patchLike.peakDirectivityDbi, 7.78, accuracy: 0.02)
        XCTAssertEqual(patchLike.peakDirection?.thetaDegrees, 0)
    }

    // MARK: - Gain, efficiency, mismatch

    func testGainFoldsInLossAndMismatchSeparately() {
        // Radiates 4π W·/sr worth of power for 5 W accepted -> 80% efficient.
        let accepted = 4 * Double.pi / 0.8
        // |Γ| = 0.1 -> 1% reflected.
        let p = pattern(acceptedPowerWatts: accepted, reflectionCoefficient: 0.1) { _, _ in 1.0 }

        XCTAssertEqual(try XCTUnwrap(p.radiationEfficiency), 0.8, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(p.mismatchEfficiency), 0.99, accuracy: 1e-6)

        // Isotropic, so D = 0 dBi and gain is purely the loss terms.
        XCTAssertEqual(try XCTUnwrap(p.peakGainDbi), 10 * log10(0.8), accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(p.peakRealizedGainDbi), 10 * log10(0.8 * 0.99), accuracy: 0.01)
    }

    /// Without port data the run can still report directivity — it must not
    /// silently present it as gain.
    func testGainIsUnavailableWithoutPortData() {
        let p = pattern { _, _ in 1.0 }

        XCTAssertNil(p.peakGainDbi)
        XCTAssertNil(p.peakRealizedGainDbi)
        XCTAssertTrue(p.supports(.directivity))
        XCTAssertTrue(p.supports(.normalized))
        XCTAssertFalse(p.supports(.realizedGain), "realized gain needs a port")
    }

    func testEfficiencyCannotExceedUnity() {
        // Numerical noise could otherwise report a >100% efficient antenna.
        let p = pattern(acceptedPowerWatts: 1e-9) { _, _ in 1.0 }
        XCTAssertEqual(try XCTUnwrap(p.radiationEfficiency), 1.0, accuracy: 1e-12)
    }

    // MARK: - Cuts

    func testPhiCutSweepsMinusOneEightyToOneEightyContinuously() throws {
        let p = pattern { theta, _ in
            let s = sin(self.radians(theta))
            return s * s
        }
        let cut = p.cut(atPhiDegrees: 0, quantity: .directivity)

        XCTAssertEqual(try XCTUnwrap(cut.points.first).angleDegrees, -178, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(cut.points.last).angleDegrees, 180, accuracy: 1e-9)
        XCTAssertEqual(cut.name, "φ = 0°")
        XCTAssertEqual(cut.conventionalName, "E-plane")
        // Angles must increase monotonically or the polar trace doubles back.
        let angles = cut.points.map(\.angleDegrees)
        XCTAssertEqual(angles, angles.sorted(), "cut must sweep in one direction")
    }

    func testThetaCutClosesTheCircle() {
        let p = pattern { _, _ in 1.0 }
        let cut = p.cut(atThetaDegrees: 90, quantity: .directivity)

        XCTAssertEqual(cut.points.first?.angleDegrees, 0)
        XCTAssertEqual(cut.points.last?.angleDegrees, 360)
        XCTAssertEqual(cut.points.first?.decibels, cut.points.last?.decibels)
        XCTAssertEqual(cut.conventionalName, "horizon")
    }

    /// A cut through a φ-dependent pattern must read the plane it was asked
    /// for — the classic bug is silently plotting φ=0 for every cut.
    func testCutsReadTheirOwnPlane() {
        // Bright along φ=0/180, dark along φ=90/270.
        let p = pattern { theta, phi in
            let s = sin(self.radians(theta))
            let c = cos(self.radians(phi))
            return s * s * c * c
        }

        let ePlane = p.cut(atPhiDegrees: 0, quantity: .directivity)
        let hPlane = p.cut(atPhiDegrees: 90, quantity: .directivity)

        XCTAssertGreaterThan(ePlane.peakDecibels, 0)
        XCTAssertEqual(hPlane.peakDecibels, -60, "the φ=90 plane is a null for this pattern")
    }

    /// The negative half of a φ cut comes from the φ+180 column. A pattern
    /// that is bright on one side only must show that asymmetry.
    func testPhiCutNegativeHalfComesFromTheOppositePlane() {
        let p = pattern { theta, phi in
            // Only the φ ≈ 0 hemisphere radiates.
            let s = sin(self.radians(theta))
            return cos(self.radians(phi)) > 0 ? s * s : 0
        }
        let cut = p.cut(atPhiDegrees: 0, quantity: .directivity)

        let front = cut.points.first { abs($0.angleDegrees - 90) < 1e-9 }
        let back = cut.points.first { abs($0.angleDegrees + 90) < 1e-9 }
        XCTAssertGreaterThan(try XCTUnwrap(front).decibels, 0)
        XCTAssertEqual(try XCTUnwrap(back).decibels, -60)
    }

    func testHalfPowerBeamwidthOfAShortDipoleIsNinetyDegrees() {
        let dipole = pattern(stepDegrees: 1) { theta, _ in
            let s = sin(self.radians(theta))
            return s * s
        }
        let cut = dipole.cut(atPhiDegrees: 0, quantity: .directivity)

        // sin²θ falls to half power at θ = 45° and 135°.
        XCTAssertEqual(try XCTUnwrap(cut.halfPowerBeamwidthDegrees), 90, accuracy: 1.0)
    }

    func testOmnidirectionalCutReportsNoBeamwidthRatherThanZero() {
        let p = pattern { _, _ in 1.0 }
        let cut = p.cut(atThetaDegrees: 90, quantity: .directivity)

        XCTAssertNil(cut.halfPowerBeamwidthDegrees, "a flat trace has no half-power edge")
    }

    func testFrontToBackRatioMeasuresTheOppositeDirection() {
        // Bright at θ=0, 20 dB down at θ=180.
        let p = pattern { theta, _ in
            theta < 90 ? 1.0 : 0.01
        }
        let cut = p.cut(atPhiDegrees: 0, quantity: .directivity)

        XCTAssertEqual(try XCTUnwrap(cut.frontToBackDb), 20, accuracy: 0.5)
    }

    func testNormalizedQuantityPutsThePeakAtZeroDb() {
        let p = pattern { theta, _ in
            let c = cos(self.radians(theta))
            return theta <= 90 ? c * c : 0
        }
        let cut = p.cut(atPhiDegrees: 0, quantity: .normalized)

        XCTAssertEqual(cut.peakDecibels, 0, accuracy: 1e-9)
    }

    func testPrincipalCutsAreTheThreeRequestedPlanes() {
        let p = pattern { _, _ in 1.0 }
        let cuts = p.principalCuts(quantity: .directivity)

        XCTAssertEqual(cuts.map(\.name), ["φ = 0°", "φ = 90°", "θ = 90°"])
    }
}
