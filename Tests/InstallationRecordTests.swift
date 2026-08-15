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

    func testLegacyRecordDecodesWithoutExpirationMetadata() throws {
        let projectID = UUID()
        let json = """
        {
          "projectID": "\(projectID.uuidString)",
          "deviceUDID": "PHONE-1",
          "installedAt": 0,
          "installedVersion": "1.0 (1)"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        let record = try decoder.decode(InstallationRecord.self, from: Data(json.utf8))

        XCTAssertNil(record.profileExpirationDate)
        XCTAssertNil(record.profileExpirationWasChecked)
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
