import XCTest
@testable import DevManagement

final class DeviceInstallationSelectionTests: XCTestCase {
    private let iPhone = ConnectedDevice(
        udid: "PHONE-1",
        name: "Test iPhone",
        model: "iPhone 17 Pro",
        platform: "iOS",
        transportType: "localNetwork",
        isInstallReady: true
    )
    private let iPad = ConnectedDevice(
        udid: "TABLET-1",
        name: "Test iPad",
        model: "iPad Pro 13-inch",
        platform: "iOS",
        transportType: "wired",
        isInstallReady: true
    )

    func testProjectDevicesAreEnabledIndependentlyByDefault() {
        var firstProject = makeProject(families: [.iPhone, .iPad])
        let secondProject = makeProject(families: [.iPhone, .iPad])

        firstProject.setInstallationEnabled(false, for: iPhone.udid)

        XCTAssertFalse(firstProject.installationEnabled(for: iPhone))
        XCTAssertTrue(firstProject.installationEnabled(for: iPad))
        XCTAssertTrue(secondProject.installationEnabled(for: iPhone))
        XCTAssertTrue(secondProject.installationEnabled(for: iPad))
    }

    func testDeviceCanBeExcludedAndEnabledAgainForOneProject() {
        var project = makeProject(families: [.iPhone])

        project.setInstallationEnabled(false, for: iPhone.udid)
        XCTAssertFalse(project.installationEnabled(for: iPhone))

        project.setInstallationEnabled(true, for: iPhone.udid)
        XCTAssertTrue(project.installationEnabled(for: iPhone))
        XCTAssertNil(project.excludedDeviceUDIDs)
    }

    func testSelectedDeviceCountReflectsCurrentSelectionEvenWhenProjectIsPaused() {
        var project = makeProject(families: [.iPhone, .iPad])

        XCTAssertEqual(project.selectedDeviceCount(in: [iPhone, iPad]), 2)

        project.setInstallationEnabled(false, for: iPhone.udid)
        XCTAssertEqual(project.selectedDeviceCount(in: [iPhone, iPad]), 1)

        project.isEnabled = false
        XCTAssertEqual(project.selectedDeviceCount(in: [iPhone, iPad]), 1)
    }

    func testPausedProjectKeepsItsDeviceSelectionButDisablesInstallation() {
        var project = makeProject(families: [.iPhone])

        XCTAssertTrue(project.isSelectedInstallationTarget(iPhone))
        XCTAssertTrue(project.installationEnabled(for: iPhone))

        project.isEnabled = false

        XCTAssertTrue(project.isSelectedInstallationTarget(iPhone))
        XCTAssertFalse(project.installationEnabled(for: iPhone))

        project.isEnabled = true
        XCTAssertTrue(project.installationEnabled(for: iPhone))
    }

    func testDevicesUseTheInstallationOrderSavedForEachProject() {
        var firstProject = makeProject(families: [.iPhone, .iPad])
        let secondProject = makeProject(families: [.iPhone, .iPad])
        firstProject.setInstallationDeviceOrder([iPad.udid, iPhone.udid])

        XCTAssertEqual(
            firstProject.devicesInInstallationOrder([iPhone, iPad]).map(\.udid),
            [iPad.udid, iPhone.udid]
        )
        XCTAssertEqual(
            secondProject.devicesInInstallationOrder([iPhone, iPad]).map(\.udid),
            [iPhone.udid, iPad.udid]
        )
    }

    func testNewlyConnectedDevicesFollowTheSavedInstallationOrder() {
        var project = makeProject(families: [.iPhone, .iPad])
        let newlyConnectedPhone = ConnectedDevice(
            udid: "PHONE-2",
            name: "Another iPhone",
            model: "iPhone 16",
            platform: "iOS",
            transportType: "wired",
            isInstallReady: true
        )
        project.setInstallationDeviceOrder([iPad.udid, iPhone.udid])

        XCTAssertEqual(
            project.devicesInInstallationOrder([newlyConnectedPhone, iPhone, iPad]).map(\.udid),
            [iPad.udid, iPhone.udid, newlyConnectedPhone.udid]
        )
    }

    func testReorderingConnectedDevicesPreservesDisconnectedDevicePosition() {
        var project = makeProject(families: [.iPhone, .iPad])
        project.installationDeviceOrder = ["OFFLINE-PHONE", iPhone.udid, iPad.udid]

        project.setInstallationDeviceOrder([iPad.udid, iPhone.udid])

        XCTAssertEqual(
            project.installationDeviceOrder,
            ["OFFLINE-PHONE", iPad.udid, iPhone.udid]
        )
    }

    func testInstallationDeviceOrderSurvivesPersistence() throws {
        var project = makeProject(families: [.iPhone, .iPad])
        project.setInstallationDeviceOrder([iPad.udid, iPhone.udid])

        let restoredProject = try JSONDecoder().decode(
            ManagedProject.self,
            from: JSONEncoder().encode(project)
        )

        XCTAssertEqual(restoredProject.installationDeviceOrder, [iPad.udid, iPhone.udid])
    }

    func testProjectCompatibilityCoversEveryIPhoneAndIPadCombination() {
        let iPhoneOnly = makeProject(families: [.iPhone])
        let iPadOnly = makeProject(families: [.iPad])
        let universal = makeProject(families: [.iPhone, .iPad])

        XCTAssertTrue(iPhoneOnly.supports(iPhone))
        XCTAssertFalse(iPhoneOnly.supports(iPad))
        XCTAssertFalse(iPadOnly.supports(iPhone))
        XCTAssertTrue(iPadOnly.supports(iPad))
        XCTAssertTrue(universal.supports(iPhone))
        XCTAssertTrue(universal.supports(iPad))
    }

    func testIPadFamilyUsesDeviceNameWhenMarketingModelIsUnavailable() {
        let namedIPad = ConnectedDevice(
            udid: "TABLET-2",
            name: "Living Room iPad",
            model: nil,
            platform: "iOS",
            transportType: "localNetwork",
            isInstallReady: true
        )

        XCTAssertEqual(namedIPad.mobileDeviceFamily, .iPad)
        XCTAssertEqual(namedIPad.platformDescription, "iPadOS")
        XCTAssertEqual(namedIPad.symbolName, "ipad")
    }

    func testExplicitIPadOSPlatformIsSupported() {
        let explicitIPad = ConnectedDevice(
            udid: "TABLET-3",
            name: "Tablet",
            model: nil,
            platform: "iPadOS",
            transportType: "wired",
            isInstallReady: true
        )

        XCTAssertEqual(explicitIPad.mobileDeviceFamily, .iPad)
        XCTAssertTrue(explicitIPad.supportsIOSAppInstallation)
    }

    func testUnknownLegacyCompatibilityAllowsIPhoneAndIPad() throws {
        let project = try JSONDecoder().decode(
            ManagedProject.self,
            from: JSONEncoder().encode(makeProject(families: nil))
        )

        XCTAssertTrue(project.supports(iPhone))
        XCTAssertTrue(project.supports(iPad))
    }

    func testBuildSettingsDetectIPhoneOnly() {
        XCTAssertEqual(
            ProjectDiscoveryService.supportedDeviceFamilies(
                fromBuildSettingsJSON: buildSettingsJSON(targetedDeviceFamily: "1")
            ),
            [.iPhone]
        )
    }

    func testBuildSettingsDetectIPadOnly() {
        XCTAssertEqual(
            ProjectDiscoveryService.supportedDeviceFamilies(
                fromBuildSettingsJSON: buildSettingsJSON(targetedDeviceFamily: "2")
            ),
            [.iPad]
        )
    }

    func testBuildSettingsDetectUniversalApplication() {
        XCTAssertEqual(
            ProjectDiscoveryService.supportedDeviceFamilies(
                fromBuildSettingsJSON: buildSettingsJSON(targetedDeviceFamily: "1, 2")
            ),
            [.iPhone, .iPad]
        )
    }

    func testBuildSettingsDetectApplicationBundleIdentifier() {
        XCTAssertEqual(
            ProjectDiscoveryService.applicationMetadata(
                fromBuildSettingsJSON: buildSettingsJSON(targetedDeviceFamily: "1, 2")
            )?.bundleIdentifier,
            "com.example.Sample"
        )
    }

    func testBuildSettingsIgnoreXcodeWarningsAroundJSON() {
        let output = """
        2026-08-01 [MT] warning: Supported platforms for the buildables is empty.
        \(buildSettingsJSON(targetedDeviceFamily: "1, 2"))
        """

        XCTAssertEqual(
            ProjectDiscoveryService.applicationMetadata(
                fromBuildSettingsJSON: output
            ),
            ProjectApplicationMetadata(
                supportedDeviceFamilies: [.iPhone, .iPad],
                bundleIdentifier: "com.example.Sample",
                projectSigningTeamID: ""
            )
        )
    }

    func testBuildSettingsTreatMissingDevelopmentTeamAsEmpty() {
        XCTAssertEqual(
            ProjectDiscoveryService.applicationMetadata(
                fromBuildSettingsJSON: buildSettingsJSON(targetedDeviceFamily: "1, 2")
            )?.projectSigningTeamID,
            ""
        )
    }

    func testBuildSettingsIgnoreWatchApplicationBeforeIOSApplication() {
        let json = #"""
        [
          {
            "buildSettings": {
              "PRODUCT_TYPE": "com.apple.product-type.application",
              "SUPPORTED_PLATFORMS": "watchos watchsimulator",
              "TARGETED_DEVICE_FAMILY": "4",
              "WRAPPER_EXTENSION": "app"
            }
          },
          {
            "buildSettings": {
              "PRODUCT_TYPE": "com.apple.product-type.application",
              "PRODUCT_BUNDLE_IDENTIFIER": "com.example.Sample",
              "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
              "TARGETED_DEVICE_FAMILY": "1,2",
              "WRAPPER_EXTENSION": "app"
            }
          }
        ]
        """#

        XCTAssertEqual(
            ProjectDiscoveryService.supportedDeviceFamilies(fromBuildSettingsJSON: json),
            [.iPhone, .iPad]
        )
    }

    private func makeProject(families: Set<MobileDeviceFamily>?) -> ManagedProject {
        ManagedProject(
            id: UUID(),
            displayName: "Example",
            folderPath: "/tmp/Example",
            containerPath: "/tmp/Example/Example.xcodeproj",
            containerKind: .project,
            scheme: "Example",
            configuration: "Debug",
            availableSchemes: ["Example"],
            availableConfigurations: ["Debug"],
            installMethod: .xcodebuild,
            installScriptPath: nil,
            isEnabled: true,
            marketingVersion: nil,
            buildNumber: nil,
            supportedDeviceFamilies: families
        )
    }

    private func buildSettingsJSON(targetedDeviceFamily: String) -> String {
        #"""
        [
          {
            "buildSettings": {
              "PRODUCT_TYPE": "com.apple.product-type.application",
              "PRODUCT_BUNDLE_IDENTIFIER": "com.example.Sample",
              "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
              "TARGETED_DEVICE_FAMILY": "\#(targetedDeviceFamily)",
              "WRAPPER_EXTENSION": "app"
            }
          }
        ]
        """#
    }
}
