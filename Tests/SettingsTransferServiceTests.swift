import XCTest
@testable import DevManagement

final class SettingsTransferServiceTests: XCTestCase {
    private func sampleArchive() -> SettingsArchive {
        var preferences = AppPreferences()
        preferences.reinstallAfterDays = 12
        preferences.appStoreConnectIssuerID = "issuer"
        preferences.appStoreConnectKeyID = "key"
        let profile = AppStoreConnectCredentialProfile(name: "Client", issuerID: "issuer-2", keyID: "key-2")
        preferences.appStoreConnectCredentialProfiles = [profile]

        let project = ManagedProject(
            id: UUID(),
            displayName: "Example",
            folderPath: "/tmp/Example",
            containerPath: "/tmp/Example/Example.xcodeproj",
            containerKind: .project,
            scheme: "Example",
            configuration: "Release",
            availableSchemes: ["Example"],
            availableConfigurations: ["Release"],
            isEnabled: true,
            marketingVersion: "1.0.0",
            buildNumber: "1",
            selectedDeviceUDIDs: ["udid-1"],
            appStoreConnectCredentialProfileID: profile.id
        )
        let record = InstallationRecord(
            projectID: project.id,
            deviceUDID: "udid-1",
            installedAt: Date(timeIntervalSince1970: 1_700_000_000),
            installedVersion: "1.0.0 (1)"
        )
        return SettingsArchive(
            exportedAt: Date(timeIntervalSince1970: 1_700_000_500),
            appVersion: "2.4.2 (143)",
            preferences: preferences,
            projects: [project],
            installationRecords: [record],
            credentials: SettingsArchiveCredentials(
                openAIAPIKey: "sk-test",
                appStoreConnectPrivateKey: "-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----",
                appStoreConnectProfilePrivateKeys: [profile.id.uuidString: "-----BEGIN PRIVATE KEY-----\ndef\n-----END PRIVATE KEY-----"],
                appReviewDemoAccountName: "demo",
                appReviewDemoAccountPassword: "secret",
                appStorePrivacyFastlaneSession: "session"
            )
        )
    }

    func testPlaintextRoundTripPreservesEverything() throws {
        let archive = sampleArchive()
        let data = try SettingsTransferService.encode(archive, password: nil)
        XCTAssertFalse(SettingsTransferService.isEncrypted(data))

        let decoded = try SettingsTransferService.decode(data, password: nil)
        XCTAssertEqual(decoded, archive)
    }

    func testPlaintextExportContainsFormatMarkerAndReadableSecrets() throws {
        let data = try SettingsTransferService.encode(sampleArchive(), password: nil)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains(SettingsTransferService.formatIdentifier))
        XCTAssertTrue(text.contains("sk-test"))
    }

    func testEncryptedExportHidesSecretsAndRoundTrips() throws {
        let archive = sampleArchive()
        let data = try SettingsTransferService.encode(archive, password: "correct horse")
        XCTAssertTrue(SettingsTransferService.isEncrypted(data))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("sk-test"))
        XCTAssertFalse(text.contains("BEGIN PRIVATE KEY"))

        let decoded = try SettingsTransferService.decode(data, password: "correct horse")
        XCTAssertEqual(decoded, archive)
    }

    func testEncryptedExportRejectsWrongOrMissingPassword() throws {
        let data = try SettingsTransferService.encode(sampleArchive(), password: "right")
        XCTAssertThrowsError(try SettingsTransferService.decode(data, password: "wrong")) { error in
            XCTAssertEqual(error as? SettingsTransferError, .incorrectPassword)
        }
        XCTAssertThrowsError(try SettingsTransferService.decode(data, password: nil)) { error in
            XCTAssertEqual(error as? SettingsTransferError, .passwordRequired)
        }
    }

    func testBlankPasswordMeansPlaintext() throws {
        let data = try SettingsTransferService.encode(sampleArchive(), password: "   ")
        XCTAssertFalse(SettingsTransferService.isEncrypted(data))
    }

    func testUnrelatedJSONIsRejected() {
        let data = Data(#"{"hello":"world"}"#.utf8)
        XCTAssertThrowsError(try SettingsTransferService.decode(data, password: nil)) { error in
            XCTAssertEqual(error as? SettingsTransferError, .unrecognizedFile)
        }
        XCTAssertThrowsError(try SettingsTransferService.decode(Data("not json".utf8), password: nil)) { error in
            XCTAssertEqual(error as? SettingsTransferError, .unrecognizedFile)
        }
    }

    func testNewerFormatVersionIsRejected() throws {
        let json = """
        {"format":"\(SettingsTransferService.formatIdentifier)","formatVersion":\(SettingsTransferService.formatVersion + 1),"payload":{}}
        """
        XCTAssertThrowsError(try SettingsTransferService.decode(Data(json.utf8), password: nil)) { error in
            XCTAssertEqual(error as? SettingsTransferError, .unsupportedVersion(SettingsTransferService.formatVersion + 1))
        }
    }

    func testDefaultExportFilenameUsesDate() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let name = SettingsTransferService.defaultExportFilename(date: date, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(name, "Development Management Settings 2023-11-14.json")
    }
}
