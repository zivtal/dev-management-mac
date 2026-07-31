import XCTest
@testable import DevManagement

final class SchedulingPolicyTests: XCTestCase {
    func testNeverInstalledIsImmediatelyDue() {
        XCTAssertTrue(SchedulingPolicy.isDue(lastInstalledAt: nil, intervalDays: 3))
    }

    func testRecentInstallationIsNotDue() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let twoDaysAgo = now.addingTimeInterval(-2 * 24 * 60 * 60)
        XCTAssertFalse(SchedulingPolicy.isDue(lastInstalledAt: twoDaysAgo, now: now, intervalDays: 3))
    }

    func testInstallationAtThresholdIsDue() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let threeDaysAgo = now.addingTimeInterval(-3 * 24 * 60 * 60)
        XCTAssertTrue(SchedulingPolicy.isDue(lastInstalledAt: threeDaysAgo, now: now, intervalDays: 3))
    }

    func testIntervalHasOneDayMinimum() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let twelveHoursAgo = now.addingTimeInterval(-12 * 60 * 60)
        XCTAssertFalse(SchedulingPolicy.isDue(lastInstalledAt: twelveHoursAgo, now: now, intervalDays: 0))
    }
}
