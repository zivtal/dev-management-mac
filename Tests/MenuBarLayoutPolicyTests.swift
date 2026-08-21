import XCTest
@testable import DevManagement

final class MenuBarLayoutPolicyTests: XCTestCase {
    func testPopoverHeightIsCappedAtSixHundredPoints() {
        XCTAssertEqual(MenuBarLayoutPolicy.maximumPopoverHeight, 600)
    }

    func testIdleProjectListLeavesRoomForFixedPopoverControls() {
        XCTAssertEqual(MenuBarLayoutPolicy.maximumIdleProjectListHeight, 450)
        XCTAssertLessThan(
            MenuBarLayoutPolicy.maximumIdleProjectListHeight,
            MenuBarLayoutPolicy.maximumPopoverHeight
        )
    }

    func testShortIdleProjectListFitsItsContent() {
        XCTAssertEqual(
            MenuBarLayoutPolicy.projectListIdealHeight(
                projectCount: 2,
                hasActiveWork: false
            ),
            93
        )
    }

    func testLongIdleProjectListUsesScrollableHeightLimit() {
        XCTAssertEqual(
            MenuBarLayoutPolicy.projectListIdealHeight(
                projectCount: 20,
                hasActiveWork: false
            ),
            MenuBarLayoutPolicy.maximumIdleProjectListHeight
        )
    }

    func testActiveWorkKeepsMinimumProjectListVisible() {
        XCTAssertEqual(
            MenuBarLayoutPolicy.projectListIdealHeight(
                projectCount: 1,
                hasActiveWork: true
            ),
            MenuBarLayoutPolicy.minimumProjectListHeight
        )
    }

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
