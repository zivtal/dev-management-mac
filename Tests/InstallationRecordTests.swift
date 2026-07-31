import XCTest
@testable import DevManagement

final class InstallationRecordTests: XCTestCase {
    func testInstalledDeviceCountIncludesUniqueDevicesForRequestedProject() {
        let firstProjectID = UUID()
        let secondProjectID = UUID()
        let records = [
            makeRecord(projectID: firstProjectID, deviceUDID: "PHONE-1"),
            makeRecord(projectID: firstProjectID, deviceUDID: "PHONE-1"),
            makeRecord(projectID: firstProjectID, deviceUDID: "TABLET-1"),
            makeRecord(projectID: secondProjectID, deviceUDID: "PHONE-2")
        ]

        XCTAssertEqual(records.installedDeviceCount(for: firstProjectID), 2)
        XCTAssertEqual(records.installedDeviceCount(for: secondProjectID), 1)
        XCTAssertEqual(records.installedDeviceCount(for: UUID()), 0)
    }

    private func makeRecord(projectID: UUID, deviceUDID: String) -> InstallationRecord {
        InstallationRecord(
            projectID: projectID,
            deviceUDID: deviceUDID,
            installedAt: Date(),
            installedVersion: "1.0 (1)"
        )
    }
}
