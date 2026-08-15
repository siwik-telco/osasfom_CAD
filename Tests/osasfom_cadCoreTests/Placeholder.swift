import XCTest

@testable import osasfom_cadCore

final class PlaceholderTests: XCTestCase {
    func testCoreLoads() {
        XCTAssertEqual(Expression(2.5).source, "2.5")
    }
}
