import Security
import XCTest
@testable import DevManagement

final class AppStoreConnectCredentialTests: XCTestCase {
    func testCredentialProfilesUseDistinctKeychainAccounts() {
        let firstID = UUID()
        let secondID = UUID()

        XCTAssertEqual(
            KeychainCredentialStore.appStoreConnectPrivateKeyAccount(profileID: nil),
            PublishingCredential.appStoreConnectPrivateKey.rawValue
        )
        XCTAssertNotEqual(
            KeychainCredentialStore.appStoreConnectPrivateKeyAccount(profileID: firstID),
            KeychainCredentialStore.appStoreConnectPrivateKeyAccount(profileID: secondID)
        )
    }

    func testExistenceQueryDoesNotRequestSecretData() {
        let query = KeychainCredentialStore.existenceQuery(
            service: "test.service",
            account: "test-account"
        )

        XCTAssertNil(query[kSecReturnData as String])
        XCTAssertEqual(query[kSecReturnAttributes as String] as? Bool, true)
        XCTAssertEqual(query[kSecMatchLimit as String] as? String, kSecMatchLimitOne as String)
    }

    func testCredentialProfileRoundTripsThroughJSON() throws {
        let profile = AppStoreConnectCredentialProfile(
            name: "Client Team",
            issuerID: "issuer",
            keyID: "key"
        )

        let data = try JSONEncoder().encode(profile)
        XCTAssertEqual(try JSONDecoder().decode(AppStoreConnectCredentialProfile.self, from: data), profile)
    }

    func testManagedProjectKeepsItsSelectedCredentialProfile() throws {
        let profileID = UUID()
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
            installMethod: .xcodebuild,
            installScriptPath: nil,
            isEnabled: true,
            marketingVersion: "1.0.0",
            buildNumber: "1",
            appStoreConnectCredentialProfileID: profileID
        )

        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(ManagedProject.self, from: data)

        XCTAssertEqual(decoded.appStoreConnectCredentialProfileID, profileID)
    }

    func testLegacyPreferencesDecodeWithoutCredentialProfiles() throws {
        let data = Data(
            """
            {
              "automationEnabled": true,
              "reinstallAfterDays": 3,
              "launchAtLogin": true,
              "pollIntervalSeconds": 300
            }
            """.utf8
        )

        let preferences = try JSONDecoder().decode(AppPreferences.self, from: data)

        XCTAssertNil(preferences.appStoreConnectCredentialProfiles)
    }
}
