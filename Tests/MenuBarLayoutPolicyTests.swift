import XCTest
@testable import DevManagement

final class MenuBarLayoutPolicyTests: XCTestCase {
    func testSingleInstallationKeepsAVisibleProgressCardHeight() {
        XCTAssertEqual(
            MenuBarLayoutPolicy.activeWorkHeight(
                publishingCount: 0,
                installationCount: 1
            ),
            88
        )
    }

    func testPublishingReceivesMoreRoomThanCompactInstallationProgress() {
        XCTAssertEqual(
            MenuBarLayoutPolicy.activeWorkHeight(
                publishingCount: 1,
                installationCount: 0
            ),
            136
        )
    }

    func testMultipleJobsUseBoundedScrollableProgressArea() {
        XCTAssertEqual(
            MenuBarLayoutPolicy.activeWorkHeight(
                publishingCount: 2,
                installationCount: 2
            ),
            MenuBarLayoutPolicy.maximumActiveWorkHeight
        )
    }
}
