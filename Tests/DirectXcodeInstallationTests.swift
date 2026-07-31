import XCTest
@testable import DevManagement

final class DirectXcodeInstallationTests: XCTestCase {
    func testPersonalSchemeFindsMatchingPersonalConfiguration() {
        let project = makeProject(
            scheme: "ShekelExchange",
            configuration: "Release",
            availableSchemes: ["ShekelExchange", "ShekelExchangePersonal"],
            availableConfigurations: ["Debug", "PersonalDebug", "Release"]
        )

        XCTAssertEqual(
            project.configurationMatchingScheme("ShekelExchangePersonal"),
            "PersonalDebug"
        )
        XCTAssertNil(project.configurationMatchingScheme("ShekelExchange"))
    }

    func testNewProjectUsesDirectXcodeEvenWhenInstallScriptExists() {
        let descriptor = ProjectDescriptor(
            displayName: "Example",
            folderPath: "/tmp/Example",
            containerPath: "/tmp/Example/Example.xcodeproj",
            containerKind: .project,
            schemes: ["Example"],
            configurations: ["Debug"],
            installScriptPath: "/tmp/Example/install.sh"
        )

        XCTAssertEqual(descriptor.makeManagedProject().installMethod, .xcodebuild)
    }

    func testSelectedTeamOverridesSigningForDirectBuild() {
        var project = makeProject()
        project.signingTeamID = "N55JCPASEL"
        let arguments = InstallationService.xcodeArguments(
            project: project,
            device: makeDevice(),
            derivedDataURL: URL(fileURLWithPath: "/tmp/DerivedData")
        )

        XCTAssertTrue(arguments.contains("DEVELOPMENT_TEAM=N55JCPASEL"))
        XCTAssertTrue(arguments.contains("CODE_SIGN_STYLE=Automatic"))
        XCTAssertTrue(arguments.contains("PROVISIONING_PROFILE="))
        XCTAssertTrue(arguments.contains("PROVISIONING_PROFILE_SPECIFIER="))
    }

    func testProjectDefaultDoesNotOverrideSigningSettings() {
        let arguments = InstallationService.xcodeArguments(
            project: makeProject(),
            device: makeDevice(),
            derivedDataURL: URL(fileURLWithPath: "/tmp/DerivedData")
        )

        XCTAssertFalse(arguments.contains(where: { $0.hasPrefix("DEVELOPMENT_TEAM=") }))
        XCTAssertFalse(arguments.contains(where: { $0.hasPrefix("CODE_SIGN_STYLE=") }))
        XCTAssertFalse(arguments.contains(where: { $0.hasPrefix("PROVISIONING_PROFILE") }))
    }

    func testSigningTeamPersistsWithManagedProject() throws {
        var project = makeProject()
        project.signingTeamID = "52HV33827A"

        let decoded = try JSONDecoder().decode(
            ManagedProject.self,
            from: JSONEncoder().encode(project)
        )

        XCTAssertEqual(decoded.signingTeamID, "52HV33827A")
    }

    func testDeveloperTeamsAreBuiltFromValidDevelopmentCertificates() {
        let teams = DeveloperTeamService.teams(from: [
            SigningCertificateRecord(
                commonName: "Apple Development: zivtal83@gmail.com (PFB88Y2DHG)",
                organizationalUnit: "52HV33827A",
                organizationName: "Ziv Tal"
            ),
            SigningCertificateRecord(
                commonName: "Apple Development: Ziv Tal (2XRBZ738N7)",
                organizationalUnit: "N55JCPASEL",
                organizationName: "Hitbook Inc"
            ),
            SigningCertificateRecord(
                commonName: "Developer ID Application: Ziv Tal",
                organizationalUnit: "IGNORED",
                organizationName: "Ziv Tal"
            )
        ])

        XCTAssertEqual(Set(teams.map(\.id)), ["52HV33827A", "N55JCPASEL"])
        XCTAssertEqual(
            teams.first(where: { $0.id == "N55JCPASEL" })?.displayName,
            "Hitbook Inc — Ziv Tal (N55JCPASEL)"
        )
    }

    func testNotificationAttachmentUsesCopyAndPreservesSourceIcon() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotificationAttachmentTests-\(UUID().uuidString)", isDirectory: true)
        let sourceDirectory = root.appendingPathComponent("Source", isDirectory: true)
        let sourceURL = sourceDirectory.appendingPathComponent("AppIcon.png")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try Data([1, 2, 3, 4]).write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: root) }

        let attachmentCopy = try NotificationService.copyForNotificationAttachment(
            sourceURL: sourceURL
        )
        defer { try? FileManager.default.removeItem(at: attachmentCopy.directoryURL) }

        XCTAssertNotEqual(attachmentCopy.fileURL, sourceURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertEqual(try Data(contentsOf: attachmentCopy.fileURL), Data([1, 2, 3, 4]))
    }

    private func makeProject(
        scheme: String = "Example",
        configuration: String = "Debug",
        availableSchemes: [String] = ["Example"],
        availableConfigurations: [String] = ["Debug"]
    ) -> ManagedProject {
        ManagedProject(
            id: UUID(),
            displayName: "Example",
            folderPath: "/tmp/Example",
            containerPath: "/tmp/Example/Example.xcodeproj",
            containerKind: .project,
            scheme: scheme,
            configuration: configuration,
            availableSchemes: availableSchemes,
            availableConfigurations: availableConfigurations,
            installMethod: .xcodebuild,
            installScriptPath: nil,
            isEnabled: true,
            marketingVersion: nil,
            buildNumber: nil
        )
    }

    private func makeDevice() -> ConnectedDevice {
        ConnectedDevice(
            udid: "PHONE-1",
            name: "Test iPhone",
            model: "iPhone 17 Pro",
            platform: "iOS",
            transportType: "wired",
            isInstallReady: true
        )
    }
}
