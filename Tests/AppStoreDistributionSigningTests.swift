import Foundation
import XCTest
@testable import DevManagement

/// Covers the manual App Store signing path that replaced Xcode cloud signing:
/// export configuration, archive bundle discovery, certificate reuse and rollback,
/// profile selection, and the dedicated signing keychain.
final class AppStoreDistributionSigningTests: XCTestCase {
    private static let identity = DistributionSigningIdentity(
        teamID: "TEAM123",
        commonName: "Apple Distribution: Example (TEAM123)",
        sha1Fingerprint: "0781C813545DA2852853E4AB150A49EA5DAB7DD3"
    )

    // MARK: - Export arguments and options

    func testExportArchiveArgumentsNeverRequestCloudSigning() {
        let arguments = AppStorePublishingService.exportArchiveArguments(
            archiveURL: URL(fileURLWithPath: "/tmp/App.xcarchive"),
            exportURL: URL(fileURLWithPath: "/tmp/Export"),
            exportOptionsURL: URL(fileURLWithPath: "/tmp/ExportOptions.plist")
        )

        // The regression that produced "Cloud signing permission error": either of
        // these makes xcodebuild resolve signing through Cloud Managed Distribution.
        XCTAssertFalse(arguments.contains("-allowProvisioningUpdates"))
        XCTAssertFalse(arguments.contains("-authenticationKeyPath"))
        XCTAssertFalse(arguments.contains("-authenticationKeyID"))
        XCTAssertFalse(arguments.contains("-authenticationKeyIssuerID"))
        XCTAssertEqual(arguments, [
            "-exportArchive",
            "-archivePath", "/tmp/App.xcarchive",
            "-exportPath", "/tmp/Export",
            "-exportOptionsPlist", "/tmp/ExportOptions.plist"
        ])
    }

    func testArchiveArgumentsStillAllowProvisioningUpdatesAndAuthentication() {
        let arguments = AppStorePublishingService.archiveArguments(
            containerArguments: ["-project", "/tmp/App.xcodeproj"],
            schemeName: "App",
            configuration: "Release",
            archiveURL: URL(fileURLWithPath: "/tmp/App.xcarchive"),
            teamID: "TEAM123",
            authenticationArguments: ["-authenticationKeyPath", "/tmp/key.p8"]
        )

        XCTAssertTrue(arguments.contains("-allowProvisioningUpdates"))
        XCTAssertTrue(arguments.contains("-authenticationKeyPath"))
        XCTAssertTrue(arguments.contains("DEVELOPMENT_TEAM=TEAM123"))
        XCTAssertEqual(arguments.last, "archive")
        XCTAssertEqual(arguments.firstIndex(of: "-project"), 0)
    }

    func testArchiveArgumentsOmitBlankDevelopmentTeam() {
        let arguments = AppStorePublishingService.archiveArguments(
            containerArguments: [],
            schemeName: "App",
            configuration: "Release",
            archiveURL: URL(fileURLWithPath: "/tmp/App.xcarchive"),
            teamID: "   ",
            authenticationArguments: []
        )

        XCTAssertFalse(arguments.contains { $0.hasPrefix("DEVELOPMENT_TEAM=") })
    }

    func testExportOptionsPinManualSigningAndPreserveVersions() throws {
        let options = AppStorePublishingService.exportOptions(
            teamID: "TEAM123",
            signingIdentity: Self.identity,
            provisioningProfiles: [
                "com.example.app": "Development Management App Store com.example.app",
                "com.example.app.widget": "Development Management App Store com.example.app.widget"
            ]
        )

        XCTAssertEqual(options["signingStyle"] as? String, "manual")
        XCTAssertEqual(options["method"] as? String, "app-store-connect")
        XCTAssertEqual(options["destination"] as? String, "export")
        XCTAssertEqual(
            options["signingCertificate"] as? String,
            "0781C813545DA2852853E4AB150A49EA5DAB7DD3"
        )
        XCTAssertEqual(options["teamID"] as? String, "TEAM123")
        // Publishing must never renumber the managed app.
        XCTAssertEqual(options["manageAppVersionAndBuildNumber"] as? Bool, false)
        let profiles = try XCTUnwrap(options["provisioningProfiles"] as? [String: String])
        XCTAssertEqual(profiles.count, 2)
        XCTAssertEqual(
            profiles["com.example.app.widget"],
            "Development Management App Store com.example.app.widget"
        )
    }

    func testExportOptionsFallBackToCertificateTeamAndSerializeAsPlist() throws {
        let options = AppStorePublishingService.exportOptions(
            teamID: nil,
            signingIdentity: Self.identity,
            provisioningProfiles: [:]
        )

        XCTAssertEqual(options["teamID"] as? String, "TEAM123")
        // An empty map would tell xcodebuild there are no profiles at all.
        XCTAssertNil(options["provisioningProfiles"])
        XCTAssertNoThrow(try PropertyListSerialization.data(
            fromPropertyList: options,
            format: .xml,
            options: 0
        ))
    }

    // MARK: - Archive bundle discovery

    func testArchivedBundleIdentifiersIncludeExtensionsWithoutDuplicates() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArchiveBundles-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let applicationURL = root
            .appendingPathComponent("Products/Applications/App.app", isDirectory: true)
        try Self.writeBundle(at: applicationURL, identifier: "com.example.app")
        try Self.writeBundle(
            at: applicationURL.appendingPathComponent("PlugIns/Widget.appex", isDirectory: true),
            identifier: "com.example.app.widget"
        )
        try Self.writeBundle(
            at: applicationURL.appendingPathComponent("PlugIns/Share.appex", isDirectory: true),
            identifier: "com.example.app.share"
        )
        // Frameworks are signed with the app's identity and need no profile.
        try Self.writeBundle(
            at: applicationURL.appendingPathComponent("Frameworks/Kit.framework", isDirectory: true),
            identifier: "com.example.kit"
        )

        let identifiers = AppStorePublishingService.archivedBundleIdentifiers(at: root)

        XCTAssertEqual(
            Set(identifiers),
            ["com.example.app", "com.example.app.widget", "com.example.app.share"]
        )
        XCTAssertEqual(identifiers.count, Set(identifiers).count)
    }

    func testArchivedBundleIdentifiersAreEmptyForMissingArchive() {
        XCTAssertEqual(
            AppStorePublishingService.archivedBundleIdentifiers(
                at: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
            ),
            []
        )
    }

    // MARK: - Local identity selection

    func testDistributionSigningIdentityRequiresFingerprintAndMatchingTeam() {
        let records = [
            SigningCertificateRecord(
                commonName: "Apple Development: Example (USER1)",
                organizationalUnit: "TEAM123",
                organizationName: "Example",
                sha1Fingerprint: "AAAA"
            ),
            SigningCertificateRecord(
                commonName: "Apple Distribution: Example (TEAM123)",
                organizationalUnit: "TEAM123",
                organizationName: "Example",
                sha1Fingerprint: "BBBB"
            )
        ]

        let identity = DeveloperTeamService.distributionSigningIdentity(
            certificateRecords: records,
            teamID: "TEAM123"
        )
        XCTAssertEqual(identity?.sha1Fingerprint, "BBBB")
        XCTAssertEqual(identity?.commonName, "Apple Distribution: Example (TEAM123)")
        XCTAssertNil(DeveloperTeamService.distributionSigningIdentity(
            certificateRecords: records,
            teamID: "OTHERTEAM"
        ))
    }

    func testDistributionSigningIdentityIsUnavailableWithoutAFingerprint() {
        // A record parsed from subject components alone cannot be pinned by manual
        // export, so it must not masquerade as a usable identity.
        let records = [
            SigningCertificateRecord(
                commonName: "Apple Distribution: Example (TEAM123)",
                organizationalUnit: "TEAM123",
                organizationName: "Example"
            )
        ]

        XCTAssertNil(DeveloperTeamService.distributionSigningIdentity(
            certificateRecords: records,
            teamID: "TEAM123"
        ))
        // The looser presence check still reports the certificate.
        XCTAssertTrue(DeveloperTeamService.hasDistributionSigningIdentity(
            certificateRecords: records,
            teamID: "TEAM123"
        ))
    }

    func testDistributionSigningIdentityRejectsExpiredCertificates() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let records = [
            SigningCertificateRecord(
                commonName: "Apple Distribution: Example (TEAM123)",
                organizationalUnit: "TEAM123",
                organizationName: "Example",
                sha1Fingerprint: "EXPIRED",
                expirationDate: now.addingTimeInterval(-1)
            )
        ]

        XCTAssertNil(DeveloperTeamService.distributionSigningIdentity(
            certificateRecords: records,
            teamID: "TEAM123",
            now: now
        ))
    }

    func testDistributionSigningIdentityPrefersTheLongestLivedRenewal() {
        // Renewals accumulate under one common name; pinning an older hash in the
        // export options would fail even though a valid certificate is present.
        let now = Date(timeIntervalSince1970: 1_000_000)
        let records = [
            Self.distributionRecord(fingerprint: "OLDEST", expires: now.addingTimeInterval(-5)),
            Self.distributionRecord(fingerprint: "SOON", expires: now.addingTimeInterval(100)),
            Self.distributionRecord(fingerprint: "LATEST", expires: now.addingTimeInterval(10_000))
        ]

        XCTAssertEqual(
            DeveloperTeamService.distributionSigningIdentity(
                certificateRecords: records,
                teamID: "TEAM123",
                now: now
            )?.sha1Fingerprint,
            "LATEST"
        )
    }

    func testDistributionSigningIdentitiesRetainOlderValidRenewalsForAccountMatching() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let identities = DeveloperTeamService.distributionSigningIdentities(
            certificateRecords: [
                Self.distributionRecord(
                    fingerprint: "OLDER-STILL-ACTIVE",
                    expires: now.addingTimeInterval(100)
                ),
                Self.distributionRecord(
                    fingerprint: "NEWER-BUT-REVOKED",
                    expires: now.addingTimeInterval(10_000)
                )
            ],
            teamID: "TEAM123",
            now: now
        )

        XCTAssertEqual(
            identities.map(\.sha1Fingerprint),
            ["NEWER-BUT-REVOKED", "OLDER-STILL-ACTIVE"]
        )
    }

    func testCertificateRecordWithoutExpiryIsTreatedAsValid() {
        XCTAssertEqual(
            DeveloperTeamService.distributionSigningIdentity(
                certificateRecords: [Self.distributionRecord(fingerprint: "BBBB", expires: nil)],
                teamID: "TEAM123",
                now: Date()
            )?.sha1Fingerprint,
            "BBBB"
        )
    }

    func testSHA1FingerprintIsUppercaseHexadecimal() {
        XCTAssertEqual(
            DeveloperTeamService.sha1Fingerprint(ofCertificateData: Data("abc".utf8)),
            "A9993E364706816ABA3E25717850C26C9CD0D89D"
        )
    }

    // MARK: - Certificate provisioning

    func testActiveDistributionCertificatesIgnoreExpiredRevokedAndDevelopment() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let certificates = [
            Self.certificate(id: "dev", type: "DEVELOPMENT", expires: now.addingTimeInterval(1_000)),
            Self.certificate(id: "expired", type: "DISTRIBUTION", expires: now.addingTimeInterval(-1)),
            Self.certificate(
                id: "revoked",
                type: "DISTRIBUTION",
                expires: now.addingTimeInterval(1_000),
                activated: false
            ),
            Self.certificate(id: "good", type: "DISTRIBUTION", expires: now.addingTimeInterval(1_000)),
            Self.certificate(id: "legacy", type: "IOS_DISTRIBUTION", expires: nil)
        ]

        let active = DistributionCertificateProvisioningService.activeDistributionCertificates(
            certificates,
            now: now
        )

        XCTAssertEqual(active.map(\.id), ["good", "legacy"])
    }

    func testAccountCertificateMustBeActiveIOSDistributionCertificate() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let content = Data("same-certificate".utf8)
        let fingerprint = DeveloperTeamService.sha1Fingerprint(ofCertificateData: content)
        let certificates = [
            AppStoreConnectCertificate(
                id: "development",
                certificateType: "DEVELOPMENT",
                displayName: nil,
                certificateContent: content,
                expirationDate: now.addingTimeInterval(1_000),
                activated: true
            ),
            AppStoreConnectCertificate(
                id: "expired",
                certificateType: "DISTRIBUTION",
                displayName: nil,
                certificateContent: content,
                expirationDate: now.addingTimeInterval(-1),
                activated: true
            )
        ]

        XCTAssertNil(DistributionCertificateProvisioningService.accountCertificate(
            in: certificates,
            sha1Fingerprint: fingerprint,
            now: now
        ))
    }

    func testMismatchedTeamIDIsNilWhenExpectedTeamIsPresentOrUnknown() {
        XCTAssertNil(DistributionCertificateProvisioningService.mismatchedTeamID([], expectedTeamID: "TEAM123"))
        XCTAssertNil(DistributionCertificateProvisioningService.mismatchedTeamID(
            [Self.certificate(id: "a", type: "DISTRIBUTION", expires: nil)],
            expectedTeamID: nil
        ))
        XCTAssertNil(DistributionCertificateProvisioningService.mismatchedTeamID(
            [Self.certificate(id: "a", type: "DISTRIBUTION", expires: nil)],
            expectedTeamID: ""
        ))
    }

    func testUnusableCertificatesAreSortedAndDescribeExpiry() {
        let certificates = [
            Self.certificate(id: "2", type: "DISTRIBUTION", expires: nil, displayName: "Zeta"),
            Self.certificate(
                id: "1",
                type: "DISTRIBUTION",
                expires: Date(timeIntervalSince1970: 0),
                displayName: "Alpha"
            )
        ]

        let unusable = DistributionCertificateProvisioningService.unusableCertificates(certificates)

        XCTAssertEqual(unusable.map(\.displayName), ["Alpha", "Zeta"])
        XCTAssertTrue(unusable[0].descriptionText.contains("Alpha"))
        XCTAssertNotEqual(unusable[0].descriptionText, "Alpha", "an expiry date should be shown")
        XCTAssertEqual(unusable[1].descriptionText, "Zeta")
    }

    func testSlotExhaustionErrorNamesTheBlockingCertificatesAndPromisesNoRevoke() throws {
        let error = DistributionCertificateProvisioningError.certificateSlotsExhausted([
            UnusableDistributionCertificate(id: "1", displayName: "Alpha", expirationDate: nil)
        ])

        let message = try XCTUnwrap(error.errorDescription)
        XCTAssertTrue(message.contains("Alpha"))
        XCTAssertTrue(message.contains("never revokes"))
        XCTAssertTrue(message.contains("No archive was uploaded."))
    }

    func testCreationFailureErrorsDoNotPreAnnounceTheRollbackOutcome() throws {
        // Rollback is best-effort, so these must not claim the slot was released;
        // the rollback reports what actually happened in the publishing log.
        for error: DistributionCertificateProvisioningError in [
            .invalidCertificate,
            .importedIdentityUnavailable("TEAM123")
        ] {
            let message = try XCTUnwrap(error.errorDescription)
            XCTAssertFalse(
                message.contains("revoked"),
                "error text must not assert a rollback outcome: \(message)"
            )
            XCTAssertTrue(message.contains("No archive was uploaded."))
        }
    }

    func testTeamMismatchErrorNamesBothTeams() throws {
        let message = try XCTUnwrap(
            DistributionCertificateProvisioningError
                .teamMismatch(expected: "TEAM123", actual: "OTHER456")
                .errorDescription
        )

        XCTAssertTrue(message.contains("TEAM123"))
        XCTAssertTrue(message.contains("OTHER456"))
    }

    func testMismatchedTeamIDIsDeterministicAcrossOrdering() {
        // The previous implementation read `Set.first`, so it reported an arbitrary
        // team. Ordering must not change the answer.
        XCTAssertEqual(
            DistributionCertificateProvisioningService.mismatchedTeamID(
                teamIDs: ["ZTEAM", "ATEAM", "MTEAM"],
                expectedTeamID: "TEAM123"
            ),
            "ATEAM"
        )
        XCTAssertEqual(
            DistributionCertificateProvisioningService.mismatchedTeamID(
                teamIDs: ["MTEAM", "ZTEAM", "ATEAM"],
                expectedTeamID: "TEAM123"
            ),
            "ATEAM"
        )
    }

    func testMismatchedTeamIDIgnoresBlankTeamsAndMatchingTeams() {
        XCTAssertNil(DistributionCertificateProvisioningService.mismatchedTeamID(
            teamIDs: ["  ", ""],
            expectedTeamID: "TEAM123"
        ))
        XCTAssertNil(DistributionCertificateProvisioningService.mismatchedTeamID(
            teamIDs: ["OTHER", " TEAM123 "],
            expectedTeamID: "TEAM123"
        ))
    }

    // MARK: - App Store Connect profile payloads

    func testAppStoreProfileCreateBodyUsesAppleProvisioningShape() throws {
        let body = AppStoreConnectService.appStoreProfileCreateBody(
            name: "Development Management App Store com.example.app",
            bundleIDResourceID: "BUNDLE1",
            certificateID: "CERT1"
        )

        let data = try XCTUnwrap(body["data"] as? [String: Any])
        XCTAssertEqual(data["type"] as? String, "profiles")
        let attributes = try XCTUnwrap(data["attributes"] as? [String: Any])
        XCTAssertEqual(attributes["profileType"] as? String, "IOS_APP_STORE")
        XCTAssertEqual(
            attributes["name"] as? String,
            "Development Management App Store com.example.app"
        )
        let relationships = try XCTUnwrap(data["relationships"] as? [String: Any])
        let bundle = try XCTUnwrap(
            (relationships["bundleId"] as? [String: Any])?["data"] as? [String: Any]
        )
        XCTAssertEqual(bundle["id"] as? String, "BUNDLE1")
        let certificates = try XCTUnwrap(
            (relationships["certificates"] as? [String: Any])?["data"] as? [[String: Any]]
        )
        XCTAssertEqual(certificates.map { $0["id"] as? String }, ["CERT1"])
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: body))
    }

    func testProfileParsingResolvesBundleIdentifierAndCertificates() throws {
        let resource: [String: Any] = [
            "id": "PROFILE1",
            "attributes": [
                "name": "Store Profile",
                "profileType": "IOS_APP_STORE",
                "profileState": "ACTIVE",
                "uuid": "1111-2222",
                "profileContent": Data("profile".utf8).base64EncodedString(),
                "expirationDate": "2027-08-15T17:37:13.000+00:00"
            ],
            "relationships": [
                "bundleId": ["data": ["type": "bundleIds", "id": "BUNDLE1"]],
                "certificates": ["data": [["type": "certificates", "id": "CERT1"]]]
            ]
        ]

        let profile = try XCTUnwrap(AppStoreConnectService.profile(
            resource,
            bundleIdentifiersByID: ["BUNDLE1": "com.example.app"]
        ))

        XCTAssertEqual(profile.bundleIdentifier, "com.example.app")
        XCTAssertEqual(profile.certificateIDs, ["CERT1"])
        XCTAssertEqual(profile.uuid, "1111-2222")
        XCTAssertEqual(profile.profileContent, Data("profile".utf8))
        XCTAssertNotNil(profile.expirationDate)
        XCTAssertTrue(profile.isActive(at: Date(timeIntervalSince1970: 0)))
    }

    func testProfileIsInactiveWhenInvalidatedOrExpired() {
        XCTAssertFalse(Self.profile(state: "INVALID", expires: nil).isActive())
        XCTAssertFalse(
            Self.profile(state: "ACTIVE", expires: Date(timeIntervalSince1970: 0))
                .isActive(at: Date(timeIntervalSince1970: 1))
        )
    }

    func testBundleIDParsingRequiresAnIdentifier() {
        XCTAssertNil(AppStoreConnectService.bundleID(["id": "B1", "attributes": ["identifier": ""]]))
        XCTAssertEqual(
            AppStoreConnectService.bundleID([
                "id": "B1",
                "attributes": ["identifier": "com.example.app", "name": "Example"]
            ]),
            AppStoreConnectBundleID(id: "B1", identifier: "com.example.app", name: "Example")
        )
    }

    // MARK: - Profile selection

    func testInstalledProfileMustBeAppStoreForTheTeamBundleAndCertificate() {
        let future = Date().addingTimeInterval(60 * 60 * 24 * 365)
        let matching = Self.installedProfile(
            bundleIdentifier: "com.example.app",
            teamID: "TEAM123",
            fingerprints: ["BBBB"],
            expires: future,
            hasDevices: false
        )
        let candidates = [
            // Right bundle, but a development profile.
            Self.installedProfile(
                bundleIdentifier: "com.example.app",
                teamID: "TEAM123",
                fingerprints: ["BBBB"],
                expires: future,
                hasDevices: true
            ),
            // Right bundle and type, but authorizes a different certificate.
            Self.installedProfile(
                bundleIdentifier: "com.example.app",
                teamID: "TEAM123",
                fingerprints: ["CCCC"],
                expires: future,
                hasDevices: false
            ),
            // Right everything, but expired.
            Self.installedProfile(
                bundleIdentifier: "com.example.app",
                teamID: "TEAM123",
                fingerprints: ["BBBB"],
                expires: Date(timeIntervalSince1970: 0),
                hasDevices: false
            ),
            // Right everything, but another team.
            Self.installedProfile(
                bundleIdentifier: "com.example.app",
                teamID: "OTHER",
                fingerprints: ["BBBB"],
                expires: future,
                hasDevices: false
            ),
            // Enterprise in-house: no device list either, but signing an App Store
            // upload with it produces an IPA Apple rejects.
            Self.installedProfile(
                bundleIdentifier: "com.example.app",
                teamID: "TEAM123",
                fingerprints: ["BBBB"],
                expires: future,
                hasDevices: false,
                provisionsAllDevices: true,
                betaReportsActive: false
            ),
            // App Store profiles are the only ones carrying beta-reports-active.
            Self.installedProfile(
                bundleIdentifier: "com.example.app",
                teamID: "TEAM123",
                fingerprints: ["BBBB"],
                expires: future,
                hasDevices: false,
                betaReportsActive: false
            ),
            matching
        ]

        XCTAssertEqual(
            AppStoreProvisioningProfileService.installedAppStoreProfile(
                in: candidates,
                bundleIdentifier: "com.example.app",
                teamID: "TEAM123",
                certificateSHA1: "BBBB"
            ),
            matching
        )
        XCTAssertNil(AppStoreProvisioningProfileService.installedAppStoreProfile(
            in: candidates,
            bundleIdentifier: "com.example.app.widget",
            teamID: "TEAM123",
            certificateSHA1: "BBBB"
        ))
    }

    func testWildcardInstalledProfileIsNeverReusedForAConcreteBundle() {
        let wildcard = Self.installedProfile(
            bundleIdentifier: "com.example.*",
            teamID: "TEAM123",
            fingerprints: ["BBBB"],
            expires: Date().addingTimeInterval(60 * 60 * 24 * 365),
            hasDevices: false
        )

        XCTAssertTrue(wildcard.hasWildcardBundleIdentifier)
        // Not even for the identifier it literally stores.
        XCTAssertNil(AppStoreProvisioningProfileService.installedAppStoreProfile(
            in: [wildcard],
            bundleIdentifier: "com.example.*",
            teamID: "TEAM123",
            certificateSHA1: "BBBB"
        ))
        XCTAssertNil(AppStoreProvisioningProfileService.installedAppStoreProfile(
            in: [wildcard],
            bundleIdentifier: "com.example.app",
            teamID: "TEAM123",
            certificateSHA1: "BBBB"
        ))
    }

    func testWildcardAccountProfileIsNeverReused() {
        let wildcard = AppStoreConnectProfile(
            id: "P1",
            name: "Wildcard",
            profileType: AppStoreConnectProfile.appStoreProfileType,
            profileState: "ACTIVE",
            uuid: "U1",
            profileContent: Data("profile".utf8),
            expirationDate: Date().addingTimeInterval(60 * 60 * 24 * 365),
            bundleIdentifier: "com.example.*",
            certificateIDs: ["CERT1"]
        )

        XCTAssertNil(AppStoreProvisioningProfileService.reusableAccountProfile(
            in: [wildcard],
            bundleIdentifier: "com.example.*",
            certificateID: "CERT1"
        ))
    }

    func testReusableAccountProfileRequiresMatchingCertificateAndContent() {
        let usable = Self.profile(
            state: "ACTIVE",
            expires: nil,
            bundleIdentifier: "com.example.app",
            certificateIDs: ["CERT1"],
            content: Data("profile".utf8)
        )
        let candidates = [
            Self.profile(
                state: "ACTIVE",
                expires: nil,
                bundleIdentifier: "com.example.app",
                certificateIDs: ["OTHER"],
                content: Data("profile".utf8)
            ),
            // Apple omits profileContent unless it is requested; an empty profile
            // cannot be installed, so it must not be reused.
            Self.profile(
                state: "ACTIVE",
                expires: nil,
                bundleIdentifier: "com.example.app",
                certificateIDs: ["CERT1"],
                content: nil
            ),
            usable
        ]

        XCTAssertEqual(
            AppStoreProvisioningProfileService.reusableAccountProfile(
                in: candidates,
                bundleIdentifier: "com.example.app",
                certificateID: "CERT1"
            ),
            usable
        )
    }

    func testMatchingCertificateIDComparesFingerprints() {
        let content = Data("certificate".utf8)
        let fingerprint = DeveloperTeamService.sha1Fingerprint(ofCertificateData: content)
        let certificates = [
            Self.certificate(id: "other", type: "DISTRIBUTION", expires: nil, content: Data("x".utf8)),
            Self.certificate(id: "wanted", type: "DISTRIBUTION", expires: nil, content: content)
        ]

        XCTAssertEqual(
            AppStoreProvisioningProfileService.matchingCertificateID(
                in: certificates,
                sha1Fingerprint: fingerprint
            ),
            "wanted"
        )
        XCTAssertNil(AppStoreProvisioningProfileService.matchingCertificateID(
            in: certificates,
            sha1Fingerprint: "MISSING"
        ))
    }

    func testProfileNameAvoidsCollisionsInsteadOfDeletingExistingProfiles() {
        let base = "Development Management App Store com.example.app"

        XCTAssertEqual(
            AppStoreProvisioningProfileService.profileName(
                bundleIdentifier: "com.example.app",
                existingNames: []
            ),
            base
        )
        XCTAssertEqual(
            AppStoreProvisioningProfileService.profileName(
                bundleIdentifier: "com.example.app",
                existingNames: [base, "\(base) 2"]
            ),
            "\(base) 3"
        )
    }

    func testUniqueIdentifiersTrimAndDeduplicatePreservingOrder() {
        XCTAssertEqual(
            AppStoreProvisioningProfileService.uniqueIdentifiers([
                "com.example.app", "  ", "com.example.app.widget", "com.example.app", " com.example.app "
            ]),
            ["com.example.app", "com.example.app.widget"]
        )
    }

    // MARK: - Signing keychain

    func testKeychainSearchListParsingAndMembership() {
        let output = """
            \"/Users/example/Library/Keychains/login.keychain-db\"
            \"/Library/Keychains/System.keychain\"
        """

        let entries = SigningKeychainService.parseKeychainSearchList(output)

        XCTAssertEqual(entries, [
            "/Users/example/Library/Keychains/login.keychain-db",
            "/Library/Keychains/System.keychain"
        ])
        XCTAssertTrue(SigningKeychainService.searchList(
            entries,
            contains: "/Library/Keychains/System.keychain"
        ))
        // macOS reports the same keychain with and without the -db suffix.
        XCTAssertTrue(SigningKeychainService.searchList(
            entries,
            contains: "/Users/example/Library/Keychains/login.keychain"
        ))
        XCTAssertFalse(SigningKeychainService.searchList(
            entries,
            contains: "/Users/example/Library/Keychains/DevManagement-Signing.keychain-db"
        ))
    }

    func testPartitionListAuthorizesAppleSigningTools() {
        // Without codesign in the partition list the key stays behind a UI prompt
        // that an LSUIElement menu-bar app can never answer.
        XCTAssertTrue(SigningKeychainService.partitionList.contains("codesign:"))
        XCTAssertTrue(SigningKeychainService.partitionList.contains("apple-tool:"))
    }

    // MARK: - Fixtures

    private static func distributionRecord(
        fingerprint: String,
        expires: Date?
    ) -> SigningCertificateRecord {
        SigningCertificateRecord(
            commonName: "Apple Distribution: Example (TEAM123)",
            organizationalUnit: "TEAM123",
            organizationName: "Example",
            sha1Fingerprint: fingerprint,
            expirationDate: expires
        )
    }

    private static func writeBundle(at url: URL, identifier: String) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": identifier,
                "CFBundleShortVersionString": "1.0",
                "CFBundleVersion": "1"
            ],
            format: .xml,
            options: 0
        )
        try plist.write(to: url.appendingPathComponent("Info.plist"))
    }

    private static func certificate(
        id: String,
        type: String,
        expires: Date?,
        activated: Bool? = nil,
        displayName: String? = nil,
        content: Data? = nil
    ) -> AppStoreConnectCertificate {
        AppStoreConnectCertificate(
            id: id,
            certificateType: type,
            displayName: displayName ?? id,
            certificateContent: content,
            expirationDate: expires,
            activated: activated
        )
    }

    private static func profile(
        state: String?,
        expires: Date?,
        bundleIdentifier: String? = nil,
        certificateIDs: [String] = [],
        content: Data? = nil
    ) -> AppStoreConnectProfile {
        AppStoreConnectProfile(
            id: "PROFILE",
            name: "Profile",
            profileType: "IOS_APP_STORE",
            profileState: state,
            uuid: nil,
            profileContent: content,
            expirationDate: expires,
            bundleIdentifier: bundleIdentifier,
            certificateIDs: certificateIDs
        )
    }

    private static func installedProfile(
        bundleIdentifier: String,
        teamID: String,
        fingerprints: [String],
        expires: Date?,
        hasDevices: Bool,
        provisionsAllDevices: Bool = false,
        betaReportsActive: Bool = true
    ) -> ProvisioningProfileRecord {
        ProvisioningProfileRecord(
            teamID: teamID,
            teamName: "Example",
            bundleIdentifier: bundleIdentifier,
            expirationDate: expires,
            uuid: UUID().uuidString,
            name: "Profile \(bundleIdentifier) \(teamID) \(fingerprints.joined()) \(hasDevices)",
            certificateSHA1Fingerprints: fingerprints,
            hasProvisionedDevices: hasDevices,
            provisionsAllDevices: provisionsAllDevices,
            isBetaReportsActive: betaReportsActive
        )
    }
}
