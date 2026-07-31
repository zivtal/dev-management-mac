import XCTest
@testable import DevReinstaller

final class DeviceInstallationSelectionTests: XCTestCase {
    func testDevicesAreEnabledByDefault() {
        let preferences = AppPreferences()

        XCTAssertTrue(preferences.installationEnabled(for: "PHONE-1"))
        XCTAssertTrue(preferences.installationEnabled(for: "PHONE-2"))
    }

    func testDeviceCanBeExcludedAndEnabledAgain() {
        var preferences = AppPreferences()

        preferences.setInstallationEnabled(false, for: "PHONE-1")
        XCTAssertFalse(preferences.installationEnabled(for: "PHONE-1"))
        XCTAssertTrue(preferences.installationEnabled(for: "PHONE-2"))

        preferences.setInstallationEnabled(true, for: "PHONE-1")
        XCTAssertTrue(preferences.installationEnabled(for: "PHONE-1"))
        XCTAssertNil(preferences.excludedDeviceUDIDs)
    }

    func testLegacyPreferencesDecodeWithAllDevicesEnabled() throws {
        let json = #"""
        {
          "automationEnabled": true,
          "reinstallAfterDays": 3,
          "launchAtLogin": true,
          "pollIntervalSeconds": 300,
          "notificationsEnabled": true
        }
        """#

        let preferences = try JSONDecoder().decode(AppPreferences.self, from: Data(json.utf8))

        XCTAssertTrue(preferences.installationEnabled(for: "PHONE-1"))
    }
}
