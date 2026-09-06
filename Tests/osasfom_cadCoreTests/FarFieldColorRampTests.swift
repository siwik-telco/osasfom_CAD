import XCTest

@testable import osasfom_cadCore

/// The pattern colour ramp. Shared by the 3D surface and the legend beside
/// it, so its behaviour is worth pinning: a legend that disagrees with the
/// surface it explains actively misleads.
final class FarFieldColorRampTests: XCTestCase {

    func testFloorIsColdAndPeakIsDeepRed() {
        let floor = FarFieldColorRamp.color(level: 0)
        XCTAssertGreaterThan(floor.blue, floor.red, "the floor should read as cold blue")

        let peak = FarFieldColorRamp.color(level: 1)
        XCTAssertGreaterThan(peak.red, 0.35)
        XCTAssertLessThan(peak.green, 0.1, "a blood red has almost no green")
        XCTAssertLessThan(peak.blue, 0.1)
        XCTAssertLessThan(peak.red, 0.6, "and is darker than a bright pillarbox red")
    }

    /// The top of the range is where the main lobe lives, so it gets a long
    /// run of reds rather than a single step.
    func testUpperRangeIsDominatedByReds() {
        for level in stride(from: 0.75, through: 1.0, by: 0.05) {
            let color = FarFieldColorRamp.color(level: level)
            XCTAssertGreaterThan(color.red, color.green, "level \(level) should read red")
            XCTAssertGreaterThan(color.red, color.blue, "level \(level) should read red")
        }
    }

    func testRedRisesMonotonicallyThroughTheWarmEnd() {
        // Between yellow and full red the red channel is already saturated,
        // so the thing that must move consistently is green falling away.
        var previousGreen = FarFieldColorRamp.color(level: 0.6).green
        for level in stride(from: 0.65, through: 1.0, by: 0.05) {
            let green = FarFieldColorRamp.color(level: level).green
            XCTAssertLessThanOrEqual(green, previousGreen + 1e-9, "green must not rise again at \(level)")
            previousGreen = green
        }
    }

    func testLevelsAreClampedRatherThanExtrapolated() {
        XCTAssertEqual(FarFieldColorRamp.color(level: -5).red, FarFieldColorRamp.color(level: 0).red)
        XCTAssertEqual(FarFieldColorRamp.color(level: 5).red, FarFieldColorRamp.color(level: 1).red)
    }

    func testRampIsContinuous() {
        // A visible band in the surface would mean a jump here.
        var previous = FarFieldColorRamp.color(level: 0)
        for level in stride(from: 0.01, through: 1.0, by: 0.01) {
            let color = FarFieldColorRamp.color(level: level)
            let jump = abs(color.red - previous.red)
                + abs(color.green - previous.green)
                + abs(color.blue - previous.blue)
            XCTAssertLessThan(jump, 0.2, "colour jumps at level \(level)")
            previous = color
        }
    }

    func testStopsAreOrderedAndSpanTheFullRange() {
        let levels = FarFieldColorRamp.stops.map(\.level)
        XCTAssertEqual(levels, levels.sorted())
        XCTAssertEqual(levels.first, 0)
        XCTAssertEqual(levels.last, 1)
    }
}
