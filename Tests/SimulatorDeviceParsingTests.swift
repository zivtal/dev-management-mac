import XCTest
@testable import DevManagement

final class SimulatorDeviceParsingTests: XCTestCase {
    private let listJSON = #"""
    {
      "devices": {
        "com.apple.CoreSimulator.SimRuntime.iOS-17-5": [
          {"udid": "OLD-IPHONE", "name": "iPhone 15", "state": "Shutdown", "isAvailable": true},
          {"udid": "UNAVAILABLE", "name": "iPhone 14", "state": "Shutdown", "isAvailable": false}
        ],
        "com.apple.CoreSimulator.SimRuntime.iOS-18-2": [
          {"udid": "NEW-IPHONE", "name": "iPhone 17 Pro", "state": "Shutdown", "isAvailable": true},
          {"udid": "NEW-IPAD", "name": "iPad Pro 13-inch (M4)", "state": "Shutdown", "isAvailable": true},
          {"udid": "SCRIPT-SIM", "name": "ios_sim_1756199254", "state": "Shutdown", "isAvailable": true},
          {"udid": "SCRIPT-TEST", "name": "test_auto_delete_1756199100", "state": "Shutdown", "isAvailable": true},
          {"udid": "RENAMED-IPAD", "name": "Ziv's tablet", "state": "Shutdown", "isAvailable": true, "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M4"}
        ],
        "com.apple.CoreSimulator.SimRuntime.watchOS-11-0": [
          {"udid": "WATCH", "name": "Apple Watch Ultra 2", "state": "Shutdown", "isAvailable": true}
        ]
      }
    }
    """#

    private var devices: [SimulatorDevice] {
        SimulatorDevice.availableDevices(fromSimctlList: Data(listJSON.utf8))
    }

    func testParsesAvailableDevicesAndSkipsUnavailable() {
        let parsed = devices
        XCTAssertEqual(
            Set(parsed.map(\.udid)),
            ["OLD-IPHONE", "NEW-IPHONE", "NEW-IPAD", "WATCH", "SCRIPT-SIM", "SCRIPT-TEST", "RENAMED-IPAD"]
        )
    }

    func testScriptCreatedDevicesAreExcludedFromCompatibleList() {
        let compatible = SimulatorDevice.compatibleIOSDevices(
            in: devices,
            supportedFamilies: [.iPhone, .iPad]
        )
        XCTAssertFalse(compatible.contains { $0.udid == "SCRIPT-SIM" })
        XCTAssertFalse(compatible.contains { $0.udid == "SCRIPT-TEST" })
        XCTAssertTrue(compatible.contains { $0.udid == "RENAMED-IPAD" })
    }

    func testDeviceTypeIdentifierDrivesFamilyForRenamedDevices() {
        XCTAssertEqual(
            devices.first { $0.udid == "RENAMED-IPAD" }?.mobileDeviceFamily,
            .iPad
        )
    }

    func testDeviceFamilyDetectionCoversIOSOnly() {
        let parsed = devices
        XCTAssertEqual(
            parsed.first { $0.udid == "NEW-IPHONE" }?.mobileDeviceFamily,
            .iPhone
        )
        XCTAssertEqual(
            parsed.first { $0.udid == "NEW-IPAD" }?.mobileDeviceFamily,
            .iPad
        )
        XCTAssertNil(parsed.first { $0.udid == "WATCH" }?.mobileDeviceFamily)
    }

    func testCompatibleDevicesFilterByFamilyAndSortNewestRuntimeFirst() {
        let compatible = SimulatorDevice.compatibleIOSDevices(
            in: devices,
            supportedFamilies: [.iPhone]
        )
        XCTAssertEqual(compatible.map(\.udid), ["NEW-IPHONE", "OLD-IPHONE"])
    }

    func testPreferredDevicePrefersBootedDevice() {
        var parsed = devices
        if let index = parsed.firstIndex(where: { $0.udid == "OLD-IPHONE" }) {
            parsed[index] = SimulatorDevice(
                udid: "OLD-IPHONE",
                name: "iPhone 15",
                state: "Booted",
                runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-17-5"
            )
        }
        let preferred = SimulatorDevice.preferredDevice(
            in: parsed,
            supportedFamilies: [.iPhone, .iPad]
        )
        XCTAssertEqual(preferred?.udid, "OLD-IPHONE")
    }

    func testPreferredDevicePrefersNewestIPhoneWhenNothingIsBooted() {
        let preferred = SimulatorDevice.preferredDevice(
            in: devices,
            supportedFamilies: [.iPhone, .iPad]
        )
        XCTAssertEqual(preferred?.udid, "NEW-IPHONE")
    }

    func testFriendlyRuntimeFormatsVersion() {
        let device = SimulatorDevice(
            udid: "X",
            name: "iPhone 17 Pro",
            state: "Shutdown",
            runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-18-2"
        )
        XCTAssertEqual(device.friendlyRuntime, "iOS 18.2")
    }
}
