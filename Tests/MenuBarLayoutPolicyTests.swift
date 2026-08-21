import XCTest
@testable import DevManagement

final class MenuBarLayoutPolicyTests: XCTestCase {
    func testShortContentStillFillsMinimumHeight() {
        let sizing = MenuBarLayoutPolicy.sizing(
            contentHeight: 100,
            headerHeight: 35,
            footerHeight: 20
        )

        XCTAssertEqual(sizing.popoverHeight, 600)
        XCTAssertEqual(sizing.scrollableHeight, 600 - 35 - 20 - 65)
    }

    func testTallContentScrollsWithinMaximumHeight() {
        let sizing = MenuBarLayoutPolicy.sizing(
            contentHeight: 1_000,
            headerHeight: 35,
            footerHeight: 20
        )

        XCTAssertEqual(sizing.popoverHeight, 600)
        XCTAssertEqual(sizing.scrollableHeight, 600 - 35 - 20 - 65)
    }

    func testInvalidMeasurementsFallBackToZero() {
        let sizing = MenuBarLayoutPolicy.sizing(
            contentHeight: .nan,
            headerHeight: .infinity,
            footerHeight: -10
        )

        XCTAssertEqual(sizing.popoverHeight, 600)
        XCTAssertEqual(sizing.scrollableHeight, 600 - 65)
    }
}
