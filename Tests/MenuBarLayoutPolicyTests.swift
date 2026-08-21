import XCTest
@testable import DevManagement

final class MenuBarLayoutPolicyTests: XCTestCase {
    func testRetinaHeightUsesFourHundredToSixHundredPhysicalPixels() {
        let minimum = MenuBarLayoutPolicy.sizing(
            contentHeight: 0,
            headerHeight: 35,
            footerHeight: 20,
            displayScale: 2
        )
        let maximum = MenuBarLayoutPolicy.sizing(
            contentHeight: 1_000,
            headerHeight: 35,
            footerHeight: 20,
            displayScale: 2
        )

        XCTAssertEqual(minimum.popoverHeight, 200)
        XCTAssertEqual(maximum.popoverHeight, 300)
        XCTAssertEqual(minimum.popoverHeight * 2, 400)
        XCTAssertEqual(maximum.popoverHeight * 2, 600)
    }

    func testShortContentFitsBetweenHeightBounds() {
        let sizing = MenuBarLayoutPolicy.sizing(
            contentHeight: 100,
            headerHeight: 35,
            footerHeight: 20,
            displayScale: 2
        )

        XCTAssertEqual(sizing.scrollableHeight, 100)
        XCTAssertEqual(sizing.popoverHeight, 220)
    }

    func testOneTimesDisplayUsesRequestedPixelBoundsDirectly() {
        let minimum = MenuBarLayoutPolicy.sizing(
            contentHeight: 0,
            headerHeight: 35,
            footerHeight: 20,
            displayScale: 1
        )
        let maximum = MenuBarLayoutPolicy.sizing(
            contentHeight: 1_000,
            headerHeight: 35,
            footerHeight: 20,
            displayScale: 1
        )

        XCTAssertEqual(minimum.popoverHeight, 400)
        XCTAssertEqual(maximum.popoverHeight, 600)
    }

    func testInvalidDisplayScaleFallsBackToOne() {
        let sizing = MenuBarLayoutPolicy.sizing(
            contentHeight: 0,
            headerHeight: 35,
            footerHeight: 20,
            displayScale: 0
        )

        XCTAssertEqual(sizing.popoverHeight, 400)
    }
}
