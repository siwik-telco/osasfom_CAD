import XCTest
@testable import osasfom_cadSolver

/// The axis domains a return-loss chart is drawn on.
///
/// Written after a 2–3 GHz sweep was plotted on an axis running from 0 GHz:
/// the chart framework's default domain is anchored at zero, so two thirds of
/// the plot showed frequencies that were never simulated and the resonance
/// was squeezed into an unreadable spike.
final class S11PlotDomainTests: XCTestCase {

    private func spectrum(_ points: [(ghz: Double, db: Double)]) -> [S11Point] {
        points.map { S11Point(hertz: $0.ghz * 1e9, decibels: $0.db) }
    }

    func testFrequencyAxisSpansTheSweptRangeNotZeroToTheTop() {
        let domain = S11PlotDomain(spectrum([(2.0, -0.4), (2.242, -18.19), (3.0, -0.38)]))

        XCTAssertEqual(domain.frequencyGHz.lowerBound, 2.0, accuracy: 1e-12)
        XCTAssertEqual(domain.frequencyGHz.upperBound, 3.0, accuracy: 1e-12)
    }

    func testDecibelAxisClearsTheDeepestDip() {
        // The real run that prompted this: a -18.19 dB dip must not be clipped.
        let domain = S11PlotDomain(spectrum([(2.0, -0.4), (2.242, -18.19), (3.0, -0.38)]))

        XCTAssertLessThanOrEqual(domain.decibels.lowerBound, -18.19)
        XCTAssertEqual(domain.decibels.lowerBound, -25, "rounded out to a whole 5 dB division")
        XCTAssertEqual(domain.decibels.upperBound, 0)
    }

    func testAVeryDeepDipStillFitsInsideTheAxis() {
        let domain = S11PlotDomain(spectrum([(2.0, -0.2), (2.5, -47.3), (3.0, -0.2)]))

        XCTAssertLessThanOrEqual(domain.decibels.lowerBound, -47.3)
        XCTAssertEqual(domain.decibels.lowerBound, -50)
    }

    /// An unmatched port sits near 0 dB across the whole band. Fitting the
    /// axis tightly to that would magnify numerical fuzz into what looks like
    /// structure, so the axis keeps a floor.
    func testAFlatUnmatchedTraceKeepsAReadableFloor() {
        let domain = S11PlotDomain(spectrum([(2.0, -0.41), (2.5, -0.40), (3.0, -0.39)]))

        XCTAssertEqual(domain.decibels.lowerBound, -5)
        XCTAssertEqual(domain.decibels.upperBound, 0)
    }

    /// Numerical overshoot slightly above 0 dB is real and has to stay
    /// visible rather than being cropped at the top.
    func testOvershootAboveZeroIsNotCropped() {
        let domain = S11PlotDomain(spectrum([(2.0, 1.2), (2.5, -12.0)]))

        XCTAssertGreaterThanOrEqual(domain.decibels.upperBound, 1.2)
        XCTAssertEqual(domain.decibels.upperBound, 5)
    }

    func testASinglePointStillGivesAUsableRange() {
        let domain = S11PlotDomain(spectrum([(2.4, -10)]))

        XCTAssertLessThan(domain.frequencyGHz.lowerBound, domain.frequencyGHz.upperBound)
        XCTAssertLessThan(domain.decibels.lowerBound, domain.decibels.upperBound)
    }

    func testAnEmptySpectrumDoesNotProduceAnInvalidRange() {
        let domain = S11PlotDomain([])

        XCTAssertLessThan(domain.frequencyGHz.lowerBound, domain.frequencyGHz.upperBound)
        XCTAssertLessThan(domain.decibels.lowerBound, domain.decibels.upperBound)
    }

    /// The narrowed plot range is what the runner regenerates the spectrum
    /// over, so the axis must follow it rather than the original full sweep.
    func testAxisFollowsANarrowedPlotRange() {
        let narrowed = S11PlotDomain(spectrum([(2.20, -8), (2.242, -18.19), (2.30, -7)]))

        XCTAssertEqual(narrowed.frequencyGHz.lowerBound, 2.20, accuracy: 1e-12)
        XCTAssertEqual(narrowed.frequencyGHz.upperBound, 2.30, accuracy: 1e-12)
    }
}
