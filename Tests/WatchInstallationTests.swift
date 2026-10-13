import XCTest
@testable import DevManagement

final class WatchInstallationTests: XCTestCase {
    private let watch = ConnectedDevice(
        udid: "WATCH", name: "Watch", model: "Apple Watch", platform: "watchOS",
        transportType: "localNetwork", isInstallReady: true
    )
    private let phone = ConnectedDevice(
        udid: "PHONE", name: "Phone", model: "iPhone", platform: "iOS",
        transportType: "wired", isInstallReady: true
    )

    private func project(platform: ApplicationPlatform) -> ManagedProject {
        ManagedProject(
            id: UUID(), displayName: "Example", folderPath: "/tmp/Example",
            containerPath: "/tmp/Example/Example.xcodeproj", containerKind: .project,
            scheme: "ExampleWatch", configuration: "Debug",
            availableSchemes: ["ExampleWatch"], availableConfigurations: ["Debug"],
            isEnabled: true, applicationPlatform: platform
        )
    }

    func testWatchSelectionIsRestrictedToWatchSchemeAndSurvivesPausing() {
        var app = project(platform: .watchOS)
        XCTAssertTrue(app.supports(watch))
        XCTAssertFalse(app.supports(phone))
        XCTAssertFalse(project(platform: .iOS).supports(watch))
        XCTAssertFalse(project(platform: .macOS).supports(watch))
        XCTAssertEqual(app.selectedDeviceCount(in: [watch, phone]), 1)
        app.isEnabled = false
        XCTAssertTrue(app.isSelectedInstallationTarget(watch))
        XCTAssertFalse(app.installationEnabled(for: watch))
        app.isEnabled = true
        XCTAssertTrue(app.installationEnabled(for: watch))
        app.setInstallationEnabled(false, for: watch.udid)
        XCTAssertEqual(app.selectedDeviceCount(in: [watch, phone]), 0)
    }

    func testWatchBuildAndInstallUseWatchDestinationAndProduct() {
        let arguments = InstallationService.xcodeArguments(
            project: project(platform: .watchOS), device: watch,
            derivedDataURL: URL(fileURLWithPath: "/tmp/Build"), scheme: "SanitizedWatch"
        )
        XCTAssertTrue(arguments.contains("platform=watchOS,id=WATCH"))
        XCTAssertTrue(arguments.contains("SanitizedWatch"))
        XCTAssertFalse(arguments.contains(where: { $0.hasPrefix("MARKETING_VERSION=") }))
        XCTAssertFalse(arguments.contains(where: { $0.hasPrefix("CURRENT_PROJECT_VERSION=") }))
        let appURL = URL(fileURLWithPath: "/tmp/Build/Debug-watchos/Watch.app")
        let install = InstallationService.deviceInstallArguments(device: watch, applicationURL: appURL)
        XCTAssertEqual(Array(install.prefix(4)), ["devicectl", "device", "install", "app"])
        XCTAssertTrue(install.contains("WATCH"))
        XCTAssertEqual(install.last, appURL.path)
    }

    func testEmbeddedWatchMetadataDoesNotReplacePhoneMetadata() throws {
        let json = #"""
        [
          {"buildSettings": {
            "PRODUCT_TYPE": "com.apple.product-type.application",
            "SDKROOT": "watchos", "SUPPORTED_PLATFORMS": "watchos watchsimulator",
            "SKIP_INSTALL": "YES", "PRODUCT_BUNDLE_IDENTIFIER": "com.example.app.watch",
            "WRAPPER_EXTENSION": "app", "WRAPPER_NAME": "Watch.app",
            "TARGET_BUILD_DIR": "/tmp/Debug-watchos"
          }},
          {"buildSettings": {
            "PRODUCT_TYPE": "com.apple.product-type.application",
            "SDKROOT": "iphoneos", "TARGETED_DEVICE_FAMILY": "1,2",
            "PRODUCT_BUNDLE_IDENTIFIER": "com.example.app",
            "WRAPPER_EXTENSION": "app", "WRAPPER_NAME": "Phone.app",
            "TARGET_BUILD_DIR": "/tmp/Debug-iphoneos"
          }}
        ]
        """#
        let phone = try XCTUnwrap(ProjectDiscoveryService.applicationMetadata(fromBuildSettingsJSON: json))
        XCTAssertEqual(phone.applicationPlatform, .iOS)
        XCTAssertEqual(phone.bundleIdentifier, "com.example.app")
        let watch = try XCTUnwrap(ProjectDiscoveryService.applicationMetadata(
            fromBuildSettingsJSON: json, expectedPlatform: .watchOS
        ))
        XCTAssertEqual(watch.applicationPlatform, .watchOS)
        XCTAssertEqual(watch.bundleIdentifier, "com.example.app.watch")
        XCTAssertNil(watch.supportedDeviceFamilies)
        XCTAssertEqual(InstallationService.applicationURL(
            fromBuildSettingsJSON: json, expectedPlatform: .watchOS
        )?.path, "/tmp/Debug-watchos/Watch.app")
        XCTAssertEqual(InstallationService.applicationURL(
            fromBuildSettingsJSON: json, expectedPlatform: .iOS
        )?.path, "/tmp/Debug-iphoneos/Phone.app")
    }
}
