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

    func testPhoneAndWatchSchemesBuildSeparatelyWithPhoneFirst() throws {
        var app = project(platform: .iOS)
        app.scheme = "ExamplePhone"
        app.bundleIdentifier = "com.example.phone"
        app.companionWatch = CompanionWatchConfiguration(
            scheme: "ExampleWatch", bundleIdentifier: "com.example.watch", isVerified: true
        )
        app.signingTeamID = "TEAM"
        app.buildBranch = "release"
        app.setInstallationDeviceOrder([watch.udid, phone.udid])
        let batches = app.installationBatches(for: [watch, phone])
        XCTAssertEqual(batches.map { $0.project.scheme }, ["ExamplePhone", "ExampleWatch"])
        XCTAssertEqual(batches.map { $0.devices.map(\.udid) }, [["PHONE"], ["WATCH"]])
        XCTAssertEqual(batches.map { $0.project.bundleIdentifier }, ["com.example.phone", "com.example.watch"])
        for batch in batches {
            XCTAssertEqual(batch.project.id, app.id)
            XCTAssertEqual(batch.project.signingTeamID, "TEAM")
            XCTAssertEqual(batch.project.buildBranch, "release")
            XCTAssertNil(batch.project.companionWatch)
            XCTAssertTrue(batch.devices.allSatisfy(batch.project.supports))
        }
        XCTAssertEqual(app.installationProject(for: watch).scheme, "ExampleWatch")
        XCTAssertEqual(app.installationProject(for: phone).scheme, "ExamplePhone")
    }

    func testCompanionWatchPersistsWithoutChangingPhoneSelection() throws {
        var app = project(platform: .iOS)
        app.setInstallationEnabled(false, for: phone.udid)
        app.companionWatch = CompanionWatchConfiguration(scheme: "ExampleWatch", isVerified: true)
        let restored = try JSONDecoder().decode(ManagedProject.self, from: JSONEncoder().encode(app))
        XCTAssertEqual(restored, app)
        XCTAssertFalse(restored.installationEnabled(for: phone))
        XCTAssertTrue(restored.installationEnabled(for: watch))
        app.companionWatch = nil
        XCTAssertFalse(app.supports(watch))
        XCTAssertFalse(app.installationEnabled(for: phone))
        app.companionWatch = restored.companionWatch
        app.isEnabled = false
        XCTAssertTrue(app.installationBatches(for: [watch, phone]).isEmpty)
        XCTAssertTrue(app.isSelectedInstallationTarget(watch))
    }

    func testUnverifiedWatchSchemeIsNotScheduledAndLegacyProjectsStillDecode() throws {
        var app = project(platform: .iOS)
        app.companionWatch = CompanionWatchConfiguration(scheme: "NotAWatchApp")
        XCTAssertFalse(app.supports(watch))
        XCTAssertEqual(app.installationBatches(for: [watch, phone]).count, 1)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(app)) as? [String: Any])
        json.removeValue(forKey: "companionWatch")
        let legacy = try JSONDecoder().decode(ManagedProject.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.companionWatch)
        XCTAssertTrue(legacy.installationEnabled(for: phone))
        XCTAssertFalse(legacy.supports(watch))
    }

    func testExcludingOnePlatformDoesNotExcludeTheOtherAndMacDoesNotBuildCompanion() {
        var app = project(platform: .iOS)
        app.companionWatch = CompanionWatchConfiguration(scheme: "ExampleWatch", isVerified: true)
        app.setInstallationEnabled(false, for: watch.udid)
        XCTAssertEqual(app.installationBatches(for: [watch, phone]).flatMap { $0.devices.map(\.udid) }, ["PHONE"])
        app.setInstallationEnabled(true, for: watch.udid)
        app.setInstallationEnabled(false, for: phone.udid)
        XCTAssertEqual(app.installationBatches(for: [watch, phone]).flatMap { $0.devices.map(\.udid) }, ["WATCH"])
        app.applicationPlatform = .macOS
        XCTAssertTrue(app.installationBatches(for: [watch, phone]).isEmpty)
    }

    func testManagedBuildsDoNotInheritDeploymentSigningOverride() {
        let environment = ProcessRunner.childEnvironment(inheriting: [
            "XCODE_XCCONFIG_FILE": "/tmp/manual-signing.xcconfig",
            "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer",
            "PATH": "/usr/bin"
        ])
        XCTAssertNil(environment["XCODE_XCCONFIG_FILE"])
        XCTAssertEqual(environment["DEVELOPER_DIR"], "/Applications/Xcode.app/Contents/Developer")
        XCTAssertEqual(environment["PATH"], "/usr/bin")
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
