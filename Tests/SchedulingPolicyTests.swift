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

    func testMissingApplicationIsOlderThanKnownProjectVersion() {
        XCTAssertTrue(SchedulingPolicy.installedApplicationIsOlder(
            nil,
            than: ProjectVersion(marketingVersion: "2.0", buildNumber: "20")
        ))
    }

    func testOlderMarketingVersionIsDetectedImmediately() {
        XCTAssertTrue(SchedulingPolicy.installedApplicationIsOlder(
            installedApplication(marketingVersion: "1.9.9", buildNumber: "99"),
            than: ProjectVersion(marketingVersion: "2.0", buildNumber: "20")
        ))
    }

    func testOlderBuildOfSameMarketingVersionIsDetectedNaturally() {
        XCTAssertTrue(SchedulingPolicy.installedApplicationIsOlder(
            installedApplication(marketingVersion: "2.0", buildNumber: "9"),
            than: ProjectVersion(marketingVersion: "2.0", buildNumber: "10")
        ))
    }

    func testCurrentOrNewerApplicationIsNotOlder() {
        let projectVersion = ProjectVersion(marketingVersion: "2.0", buildNumber: "20")

        XCTAssertFalse(SchedulingPolicy.installedApplicationIsOlder(
            installedApplication(marketingVersion: "2.0", buildNumber: "20"),
            than: projectVersion
        ))
        XCTAssertFalse(SchedulingPolicy.installedApplicationIsOlder(
            installedApplication(marketingVersion: "2.1", buildNumber: "1"),
            than: projectVersion
        ))
    }

    func testUnknownProjectVersionDoesNotForceInstallation() {
        XCTAssertFalse(SchedulingPolicy.installedApplicationIsOlder(
            nil,
            than: ProjectVersion(marketingVersion: nil, buildNumber: nil)
        ))
    }

    private func installedApplication(
        marketingVersion: String,
        buildNumber: String
    ) -> InstalledApplication {
        InstalledApplication(
            bundleIdentifier: "com.example.Sample",
            marketingVersion: marketingVersion,
            buildNumber: buildNumber
        )
    }
}
