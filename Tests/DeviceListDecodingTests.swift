import XCTest
@testable import DevReinstaller

final class DeviceListDecodingTests: XCTestCase {
    func testReturnsPairedAvailableIOSDevicesForAnyTransport() throws {
        let json = #"""
        {
          "result": {
            "devices": [
              {
                "hardwareProperties": {"platform": "iOS", "udid": "PHONE-1", "marketingName": "iPhone 17 Pro"},
                "deviceProperties": {"name": "Test iPhone"},
                "connectionProperties": {"pairingState": "paired", "tunnelState": "connected", "transportType": "wired"}
              },
              {
                "hardwareProperties": {"platform": "iOS", "udid": "PHONE-2"},
                "deviceProperties": {"name": "Wi-Fi iPhone"},
                "connectionProperties": {"pairingState": "paired", "tunnelState": "disconnected", "transportType": "localNetwork"}
              },
              {
                "hardwareProperties": {"platform": "macOS", "udid": "MAC-1"},
                "deviceProperties": {"name": "Mac"},
                "connectionProperties": {"pairingState": "paired", "tunnelState": "connected", "transportType": "wired"}
              },
              {
                "hardwareProperties": {"platform": "watchOS", "udid": "WATCH-1", "marketingName": "Apple Watch Series 7"},
                "deviceProperties": {"name": "Test Watch"},
                "connectionProperties": {"pairingState": "paired", "tunnelState": "connected", "transportType": "localNetwork"}
              }
            ]
          }
        }
        """#

        let envelope = try JSONDecoder().decode(DeviceListEnvelope.self, from: Data(json.utf8))
        XCTAssertEqual(
            envelope.availableAppleDevices,
            [
                ConnectedDevice(
                    udid: "PHONE-1",
                    name: "Test iPhone",
                    model: "iPhone 17 Pro",
                    platform: "iOS",
                    transportType: "wired",
                    isInstallReady: true
                ),
                ConnectedDevice(
                    udid: "PHONE-2",
                    name: "Wi-Fi iPhone",
                    model: nil,
                    platform: "iOS",
                    transportType: "localNetwork",
                    isInstallReady: false
                ),
                ConnectedDevice(
                    udid: "WATCH-1",
                    name: "Test Watch",
                    model: "Apple Watch Series 7",
                    platform: "watchOS",
                    transportType: "localNetwork",
                    isInstallReady: true
                )
            ]
        )
        XCTAssertEqual(
            envelope.availableAppleDevices.filter(\.supportsIOSAppInstallation).map(\.udid),
            ["PHONE-1", "PHONE-2"]
        )
        XCTAssertFalse(
            try XCTUnwrap(envelope.availableAppleDevices.first { $0.udid == "WATCH-1" })
                .supportsIOSAppInstallation
        )
    }
}
