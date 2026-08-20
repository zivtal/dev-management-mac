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

    func testNewProjectUsesDirectXcodeOnly() {
        let descriptor = ProjectDescriptor(
            displayName: "Example",
            folderPath: "/tmp/Example",
            containerPath: "/tmp/Example/Example.xcodeproj",
            containerKind: .project,
            schemes: ["Example"],
            configurations: ["Debug"]
        )

        XCTAssertEqual(descriptor.makeManagedProject().scheme, "Example")
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

    func testAutomaticSigningDoesNotOverrideArgumentsBeforeResolution() {
        let arguments = InstallationService.xcodeArguments(
            project: makeProject(),
            device: makeDevice(),
            derivedDataURL: URL(fileURLWithPath: "/tmp/DerivedData")
        )

        XCTAssertFalse(arguments.contains(where: { $0.hasPrefix("DEVELOPMENT_TEAM=") }))
        XCTAssertFalse(arguments.contains(where: { $0.hasPrefix("CODE_SIGN_STYLE=") }))
        XCTAssertFalse(arguments.contains(where: { $0.hasPrefix("PROVISIONING_PROFILE") }))
    }

    func testDirectIOSBuildDoesNotOverrideSwiftCompilationConditions() {
        let arguments = InstallationService.xcodeArguments(
            project: makeProject(),
            device: makeDevice(),
            derivedDataURL: URL(fileURLWithPath: "/tmp/DerivedData")
        )

        XCTAssertFalse(arguments.contains(where: {
            $0.hasPrefix("SWIFT_ACTIVE_COMPILATION_CONDITIONS=")
        }))
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

    func testDeveloperTeamsIncludeValidProvisioningProfilesWithoutLocalIdentity() {
        let now = Date(timeIntervalSince1970: 1_000)
        let teams = DeveloperTeamService.teams(
            from: [],
            provisioningProfiles: [
                makeProvisioningProfile(
                    teamID: "52HV33827A",
                    teamName: "Ziv Tal",
                    bundleIdentifier: "com.zivtal.tripflow",
                    expirationDate: Date(timeIntervalSince1970: 2_000)
                ),
                makeProvisioningProfile(
                    teamID: "EXPIRED",
                    teamName: "Expired Team",
                    bundleIdentifier: "com.example.old",
                    expirationDate: Date(timeIntervalSince1970: 500)
                )
            ],
            now: now
        )

        XCTAssertEqual(teams, [
            DeveloperTeam(id: "52HV33827A", organizationName: "Ziv Tal", accountName: nil)
        ])
    }

    func testMatchingProvisioningProfileNamespaceRecommendsTeam() {
        let profiles = [
            makeProvisioningProfile(
                teamID: "52HV33827A",
                teamName: "Ziv Tal",
                bundleIdentifier: "com.zivtal.tripflow"
            ),
            makeProvisioningProfile(
                teamID: "N55JCPASEL",
                teamName: "Hitbook Inc",
                bundleIdentifier: "com.hitbook.app"
            )
        ]

        XCTAssertEqual(
            DeveloperTeamService.recommendedTeamID(
                for: "com.zivtal.HomeCapital",
                provisioningProfiles: profiles
            ),
            "52HV33827A"
        )
    }

    func testExactProvisioningProfileOutranksNamespaceMatch() {
        let profiles = [
            makeProvisioningProfile(
                teamID: "NAMESPACE",
                teamName: nil,
                bundleIdentifier: "com.zivtal.tripflow"
            ),
            makeProvisioningProfile(
                teamID: "EXACT",
                teamName: nil,
                bundleIdentifier: "com.zivtal.HomeCapital"
            )
        ]

        XCTAssertEqual(
            DeveloperTeamService.recommendedTeamID(
                for: "com.zivtal.HomeCapital",
                provisioningProfiles: profiles
            ),
            "EXACT"
        )
    }

    func testAmbiguousProvisioningProfileNamespaceDoesNotRecommendTeam() {
        let profiles = [
            makeProvisioningProfile(
                teamID: "TEAM1",
                teamName: nil,
                bundleIdentifier: "com.example.first"
            ),
            makeProvisioningProfile(
                teamID: "TEAM2",
                teamName: nil,
                bundleIdentifier: "com.example.second"
            )
        ]

        XCTAssertNil(DeveloperTeamService.recommendedTeamID(
            for: "com.example.new",
            provisioningProfiles: profiles
        ))
    }

    func testProvisioningProfilePropertyListIsParsed() throws {
        let expirationDate = Date(timeIntervalSince1970: 2_000)
        let data = try PropertyListSerialization.data(
            fromPropertyList: [
                "TeamIdentifier": ["52HV33827A"],
                "TeamName": "Ziv Tal",
                "ExpirationDate": expirationDate,
                "Entitlements": [
                    "application-identifier": "52HV33827A.com.zivtal.HomeCapital"
                ]
            ],
            format: .xml,
            options: 0
        )

        XCTAssertEqual(
            DeveloperTeamService.provisioningProfileRecord(fromPropertyListData: data),
            makeProvisioningProfile(
                teamID: "52HV33827A",
                teamName: "Ziv Tal",
                bundleIdentifier: "com.zivtal.HomeCapital",
                expirationDate: expirationDate
            )
        )
        XCTAssertEqual(
            DeveloperTeamService.provisioningProfileExpirationDate(
                fromPropertyListData: data
            ),
            expirationDate
        )
    }

    func testExpirationDateIsReadFromBuiltApplicationProfile() throws {
        let applicationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProfileExpirationTests-\(UUID().uuidString).app", isDirectory: true)
        let profileURL = applicationURL.appendingPathComponent("embedded.mobileprovision")
        let expirationDate = Date(timeIntervalSince1970: 2_000)
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["ExpirationDate": expirationDate],
            format: .xml,
            options: 0
        )
        try FileManager.default.createDirectory(
            at: applicationURL,
            withIntermediateDirectories: true
        )
        try data.write(to: profileURL)
        defer { try? FileManager.default.removeItem(at: applicationURL) }

        XCTAssertEqual(
            DeveloperTeamService().provisioningProfileExpirationDate(in: applicationURL),
            expirationDate
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

    private func makeProvisioningProfile(
        teamID: String,
        teamName: String?,
        bundleIdentifier: String,
        expirationDate: Date? = Date.distantFuture
    ) -> ProvisioningProfileRecord {
        ProvisioningProfileRecord(
            teamID: teamID,
            teamName: teamName,
            bundleIdentifier: bundleIdentifier,
            expirationDate: expirationDate
        )
    }
}
