import XCTest
@testable import DevManagement

final class MacOSInstallationTests: XCTestCase {
    func testMacOSBuildSettingsDetectInstallableApplication() {
        let metadata = ProjectDiscoveryService.applicationMetadata(
            fromBuildSettingsJSON: macOSBuildSettingsJSON,
            expectedPlatform: .macOS
        )

        XCTAssertEqual(metadata?.applicationPlatform, .macOS)
        XCTAssertEqual(metadata?.bundleIdentifier, "com.example.SampleMac")
        XCTAssertEqual(metadata?.projectSigningTeamID, "TEAM123")
        XCTAssertNil(metadata?.supportedDeviceFamilies)
    }

    func testMacOSBuildSettingsAreNotMistakenForIOS() {
        XCTAssertNil(ProjectDiscoveryService.applicationMetadata(
            fromBuildSettingsJSON: macOSBuildSettingsJSON,
            expectedPlatform: .iOS
        ))
    }

    func testMacOSXcodeArgumentsUseGenericMacDestination() {
        var project = makeMacProject()
        project.signingTeamID = "TEAM123"

        let arguments = InstallationService.macOSXcodeArguments(
            project: project,
            derivedDataURL: URL(fileURLWithPath: "/tmp/MacDerivedData")
        )

        XCTAssertTrue(arguments.contains("generic/platform=macOS"))
        XCTAssertFalse(arguments.contains(where: { $0.contains("platform=iOS") }))
        XCTAssertTrue(arguments.contains("DEVELOPMENT_TEAM=TEAM123"))
        XCTAssertTrue(arguments.contains("/tmp/MacDerivedData"))
    }

    func testMacOSPlatformAndDMGPathSurvivePersistence() throws {
        let project = makeMacProject(displayName: "Sample: Mac/App")

        let restoredProject = try JSONDecoder().decode(
            ManagedProject.self,
            from: JSONEncoder().encode(project)
        )

        XCTAssertEqual(restoredProject.applicationPlatform, .macOS)
        XCTAssertTrue(restoredProject.isMacOSApplication)
        XCTAssertEqual(restoredProject.macOSDMGURL.path, "/tmp/SampleMac/dist/Sample- Mac-App.dmg")
    }

    func testLegacyProjectWithoutPlatformDefaultsToIOS() throws {
        let json = #"""
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "displayName": "Legacy",
          "folderPath": "/tmp/Legacy",
          "containerPath": "/tmp/Legacy/Legacy.xcodeproj",
          "containerKind": "project",
          "scheme": "Legacy",
          "configuration": "Debug",
          "availableSchemes": ["Legacy"],
          "availableConfigurations": ["Debug"],
          "installMethod": "xcodebuild",
          "isEnabled": true
        }
        """#

        let project = try JSONDecoder().decode(
            ManagedProject.self,
            from: Data(json.utf8)
        )

        XCTAssertNil(project.applicationPlatform)
        XCTAssertEqual(project.effectiveApplicationPlatform, .iOS)
    }

    func testReplacingApplicationKeepsNewBundleAndRemovesBackup() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let installationURL = root.appendingPathComponent("Sample.app", isDirectory: true)
        let newURL = root.appendingPathComponent("New.app", isDirectory: true)
        let backupURL = root.appendingPathComponent("Backup.app", isDirectory: true)
        try makeApplication(at: installationURL, marker: "old")
        try makeApplication(at: newURL, marker: "new")

        try InstallationService().replaceApplication(
            at: installationURL,
            with: newURL,
            backupURL: backupURL
        )

        XCTAssertEqual(try marker(at: installationURL), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path))
    }

    func testFailedReplacementRestoresExistingApplication() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let installationURL = root.appendingPathComponent("Sample.app", isDirectory: true)
        let missingNewURL = root.appendingPathComponent("Missing.app", isDirectory: true)
        let backupURL = root.appendingPathComponent("Backup.app", isDirectory: true)
        try makeApplication(at: installationURL, marker: "old")

        XCTAssertThrowsError(try InstallationService().replaceApplication(
            at: installationURL,
            with: missingNewURL,
            backupURL: backupURL
        ))
        XCTAssertEqual(try marker(at: installationURL), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path))
    }

    func testMacOSNotificationDescribesLocalReplacement() {
        let body = InstallationNotificationText.macOSBody(project: makeMacProject())

        XCTAssertTrue(body.contains("Sample Mac"))
        XCTAssertTrue(body.contains("Applications"))
        XCTAssertTrue(body.contains("relaunched"))
    }

    private var macOSBuildSettingsJSON: String {
        #"""
        [
          {
            "buildSettings": {
              "PRODUCT_TYPE": "com.apple.product-type.application",
              "PRODUCT_BUNDLE_IDENTIFIER": "com.example.SampleMac",
              "SUPPORTED_PLATFORMS": "macosx",
              "SDKROOT": "macosx",
              "PLATFORM_NAME": "macosx",
              "DEVELOPMENT_TEAM": "TEAM123",
              "WRAPPER_EXTENSION": "app"
            }
          }
        ]
        """#
    }

    private func makeMacProject(displayName: String = "Sample Mac") -> ManagedProject {
        ManagedProject(
            id: UUID(),
            displayName: displayName,
            folderPath: "/tmp/SampleMac",
            containerPath: "/tmp/SampleMac/SampleMac.xcodeproj",
            containerKind: .project,
            scheme: "SampleMac",
            configuration: "Release",
            availableSchemes: ["SampleMac"],
            availableConfigurations: ["Debug", "Release"],
            installMethod: .xcodebuild,
            installScriptPath: nil,
            isEnabled: true,
            marketingVersion: "1.0.0",
            buildNumber: "1",
            bundleIdentifier: "com.example.SampleMac",
            applicationPlatform: .macOS
        )
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacOSInstallationTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeApplication(at url: URL, marker: String) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(marker.utf8).write(to: url.appendingPathComponent("marker.txt"))
    }

    private func marker(at applicationURL: URL) throws -> String {
        try String(contentsOf: applicationURL.appendingPathComponent("marker.txt"), encoding: .utf8)
    }
}
