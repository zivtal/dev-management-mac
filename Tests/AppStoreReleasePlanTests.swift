import CryptoKit
import XCTest
@testable import DevManagement

final class AppStoreReleasePlanTests: XCTestCase {
    func testPartialMacOverridesInheritSharedContactAndMetadata() throws {
        let json = #"{"schemaVersion":2,"publication":{"copyright":"2026 Example","metadata":{"description":"Shared","keywords":"router","promotionalText":"","whatsNew":"Updates"},"review":{"contactFirstName":"Pat","contactEmail":"review@example.com"}},"platforms":{"IOS":{"scheme":"Phone"},"MAC_OS":{"scheme":"MacStore","publication":{"metadata":{"description":"Mac description"},"review":{"notes":"Mac instructions"},"releaseAutomatically":false,"screenshotPaths":["MacShots"]}}}}"#
        let manifest = try JSONDecoder().decode(AppStorePublishingManifest.self, from: Data(json.utf8))
        let mac = try XCTUnwrap(manifest.publication(for: .macOS))
        XCTAssertEqual(mac.metadata?.description, "Mac description")
        XCTAssertEqual(mac.metadata?.keywords, "router")
        XCTAssertEqual(mac.review?.contactFirstName, "Pat")
        XCTAssertEqual(mac.review?.notes, "Mac instructions")
        XCTAssertEqual(mac.releaseAutomatically, false)
        XCTAssertEqual(try manifest.publication(for: .iOS)?.metadata?.description, "Shared")
        let encoded = try JSONEncoder().encode(manifest)
        XCTAssertEqual(try JSONDecoder().decode(AppStorePublishingManifest.self, from: encoded), manifest)
    }

    func testUnsupportedPlatformsAndEmptySelectionFailInsteadOfFallingBackToIOS() throws {
        var manifest = AppStorePublishingManifest(schemaVersion: 2)
        manifest.platforms = ["MACOS": .init(scheme: "Mac")]
        XCTAssertThrowsError(try manifest.validatePlatforms())
        manifest.platforms = ["MAC_OS": .init(scheme: "Mac")]
        manifest.defaultPlatforms = ["IOS"]
        XCTAssertThrowsError(try manifest.validatePlatforms())
        XCTAssertThrowsError(try PublishingCommand.parsePlatforms("MACOS"))
        XCTAssertThrowsError(try PublishingCommand.parsePlatforms(""))
        XCTAssertEqual(try PublishingCommand.parsePlatforms("MAC_OS"), [.macOS])
    }

    func testSchemeResolutionUsesMacVersionInsteadOfSavedIOSVersion() throws {
        let json = #"[{"buildSettings":{"PRODUCT_TYPE":"com.apple.product-type.application","WRAPPER_EXTENSION":"app","SUPPORTED_PLATFORMS":"macosx","SDKROOT":"macosx","PRODUCT_BUNDLE_IDENTIFIER":"com.example.mac","DEVELOPMENT_TEAM":"TEAM","MARKETING_VERSION":"2.3","CURRENT_PROJECT_VERSION":"42"}}]"#
        let resolved = try AppStoreReleaseCoordinator.resolvedProject(project(), buildSettings: json, platform: .macOS)
        XCTAssertEqual(resolved.appStorePlatform, .macOS)
        XCTAssertEqual(resolved.marketingVersion, "2.3")
        XCTAssertEqual(resolved.buildNumber, "42")
        XCTAssertEqual(resolved.bundleIdentifier, "com.example.mac")
        XCTAssertThrowsError(try AppStoreReleaseCoordinator.resolvedProject(project(), buildSettings: json, platform: .iOS))
    }

    func testMacOnlySelectionNeverInspectsIOS() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var p = project(); p.folderPath = root.path
        let manifest = AppStorePublishingManifest(schemaVersion: 2, platforms: [
            "IOS": .init(scheme: "Phone"), "MAC_OS": .init(scheme: "MacStore")], defaultPlatforms: ["MAC_OS"])
        try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("app-store-publishing.json"))
        var config = configuration(); config.selectedPlatforms = [.macOS]
        let targets = try await AppStoreReleaseCoordinator.targets(project: p, configuration: config, runner: MacSettingsRunner())
        XCTAssertEqual(targets.map(\.project.scheme), ["MacStore"])
        XCTAssertEqual(targets.map(\.project.appStorePlatform), [.macOS])
        config.selectedPlatforms = []
        do { _ = try await AppStoreReleaseCoordinator.targets(project: p, configuration: config, runner: MacSettingsRunner()); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("Select at least one")) }
    }

    func testPlatformFailureStopsRemainingTargetsAndReportsCompletedOnes() async throws {
        let p = project()
        let targets = ["Phone", "Mac", "Other"].map { scheme -> AppStoreReleaseTarget in
            var copy = p; copy.scheme = scheme
            return .init(project: copy, configuration: configuration())
        }
        var attempted: [String] = []
        do {
            _ = try await AppStoreReleaseCoordinator.run(targets, output: { _ in }) { target in
                attempted.append(target.project.scheme)
                if target.project.scheme == "Mac" { throw AppStoreReleaseError.invalid("export failed") }
                return .init(version: "1", buildNumber: "1", intent: .publish, reusedExistingBuild: false, deferredStorefrontSetup: false)
            }
            XCTFail("A platform failure must fail the whole release")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("export failed"))
            XCTAssertTrue(error.localizedDescription.contains("Completed platforms: IOS / Phone"))
        }
        XCTAssertEqual(attempted, ["Phone", "Mac"])
    }

    func testHardwareDemoIsRequiredAndIncludedExactlyOnce() throws {
        let p = AppStorePublicationConfiguration(review: .init(notes: "Router setup", demoVideoURL: "https://example.com/demo", demoVideoRequired: true))
        let configured = try configuration().applying(p)
        XCTAssertEqual(configured.review.notes.components(separatedBy: "https://example.com/demo").count, 2)
        XCTAssertEqual(try configured.applying(p).review.notes, configured.review.notes)
        XCTAssertThrowsError(try configuration().applying(.init(review: .init(demoVideoRequired: true))))
        XCTAssertThrowsError(try configuration().applying(.init(review: .init(demoVideoURL: "file:///secret"))))
    }

    func testMacArchiveAndExportUseDedicatedInstallerAndNeverIOSOnlyCertificate() {
        XCTAssertFalse(DistributionCertificatePurpose.macApplication.acceptedTypes.contains("IOS_DISTRIBUTION"))
        XCTAssertEqual(DistributionCertificatePurpose.macApplication.namePrefixes, ["Apple Distribution:"])
        let archive = AppStorePublishingService.archiveArguments(containerArguments: ["-project", "Example.xcodeproj"],
            schemeName: "MacStore", configuration: "Release", archiveURL: URL(fileURLWithPath: "/tmp/App.xcarchive"),
            teamID: "TEAM", authenticationArguments: [], platform: .macOS)
        XCTAssertTrue(archive.contains("generic/platform=macOS"))
        XCTAssertEqual(archive.last, "archive")
        let options = AppStorePublishingService.exportOptions(teamID: "TEAM",
            signingIdentity: .init(teamID: "TEAM", commonName: "Apple Distribution: Example", sha1Fingerprint: "APP"),
            provisioningProfiles: ["com.example": "PROFILE"],
            installerIdentity: .init(teamID: "TEAM", commonName: "Mac Installer Distribution: Example", sha1Fingerprint: "INSTALLER"))
        XCTAssertEqual(options["method"] as? String, "app-store-connect")
        XCTAssertEqual(options["installerSigningCertificate"] as? String, "INSTALLER")
        XCTAssertEqual(options["manageAppVersionAndBuildNumber"] as? Bool, false)
        XCTAssertEqual(AppStorePlatform.macOS.artifactExtension, "pkg")
        for (w, h) in [(2880, 1800), (2560, 1600), (1440, 900), (1280, 800)] {
            XCTAssertEqual(AppStorePublishingService.screenshotDisplayType(width: w, height: h, platform: .mac), "APP_DESKTOP")
        }
        XCTAssertNil(AppStorePublishingService.screenshotDisplayType(width: 1800, height: 2880, platform: .mac))
    }

    func testMacNetworkKeychainAndEncryptionRequirements() throws {
        let requirements = AppStoreArchiveRequirements(networkClient: true, keychainAccessGroups: ["TEAM.credentials"], encryptionDeclarationInInfoPlist: true)
        let info: [String: Any] = ["LSApplicationCategoryType": "public.app-category.utilities", "ITSAppUsesNonExemptEncryption": false]
        let entitlements: [String: Any] = ["com.apple.security.app-sandbox": true, "com.apple.security.network.client": true,
                                           "keychain-access-groups": ["TEAM.credentials"]]
        XCTAssertNoThrow(try MacStoreArchiveValidation.validate(info: info, entitlements: entitlements, requirements: requirements))
        for key in entitlements.keys {
            var missing = entitlements; missing[key] = nil
            XCTAssertThrowsError(try MacStoreArchiveValidation.validate(info: info, entitlements: missing, requirements: requirements))
        }
        XCTAssertThrowsError(try MacStoreArchiveValidation.validate(info: ["LSApplicationCategoryType": "public.app-category.utilities"],
            entitlements: entitlements, requirements: requirements))
    }

    func testSourceReceiptsSeparatePlatformsAndIgnoreSharedVersionCounter() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["Mac.swift", "Phone.swift", "Shared.swift", "Version.xcconfig"] { try Data(name.utf8).write(to: root.appendingPathComponent(name)) }
        let manifest = AppStorePublishingManifest(schemaVersion: 2, platforms: [
            "IOS": .init(scheme: "Phone", sourcePaths: ["Phone.swift", "Shared.swift"]),
            "MAC_OS": .init(scheme: "Mac", sourcePaths: ["Mac.swift", "Shared.swift"])])
        var ios = project(); ios.folderPath = root.path; ios.scheme = "Phone"
        var mac = ios; mac.scheme = "Mac"; mac.applicationPlatform = .macOS
        let history = AppStoreReleaseHistory(root: root.appendingPathComponent("receipts"))
        let oldIOS = try history.fingerprint(project: ios, manifest: manifest)
        let oldMac = try history.fingerprint(project: mac, manifest: manifest)
        try history.save(oldIOS, project: ios, intent: .publish)
        try history.save(oldMac, project: mac, intent: .publish)
        try Data("new version".utf8).write(to: root.appendingPathComponent("Version.xcconfig"))
        XCTAssertEqual(try history.fingerprint(project: ios, manifest: manifest), oldIOS)
        try Data("Mac changed".utf8).write(to: root.appendingPathComponent("Mac.swift"))
        XCTAssertEqual(try history.fingerprint(project: ios, manifest: manifest), oldIOS)
        XCTAssertNotEqual(try history.fingerprint(project: mac, manifest: manifest), oldMac)
        XCTAssertEqual(try history.previous(project: mac, intent: .publish), oldMac)
        XCTAssertNil(try history.previous(project: mac, intent: .testFlight))
        try Data("Shared changed".utf8).write(to: root.appendingPathComponent("Shared.swift"))
        XCTAssertNotEqual(try history.fingerprint(project: ios, manifest: manifest), oldIOS)
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func project() -> ManagedProject {
        .init(id: UUID(), displayName: "App", folderPath: "/tmp/App", containerPath: "/tmp/App/App.xcodeproj",
              containerKind: .project, scheme: "Phone", configuration: "Release", availableSchemes: ["Phone", "MacStore"],
              availableConfigurations: ["Release"], isEnabled: true, marketingVersion: "1", buildNumber: "1", applicationPlatform: .iOS)
    }
    private func configuration() -> PublishingConfiguration {
        .init(intent: .publish, appStoreConnectIssuerID: "issuer", appStoreConnectKeyID: "key", appStoreConnectPrivateKey: "",
              appStorePrivacyAppleID: nil, appStorePrivacyTeamID: nil, appStorePrivacyFastlaneSession: nil,
              locale: "en-US", copyright: "2026 Example", supportURL: "https://example.com", marketingURL: nil,
              termsURL: nil, privacyPolicyURL: nil, privacyChoicesURL: nil, appName: nil, subtitle: nil, licenseAgreementText: nil,
              review: .init(contactFirstName: "Pat", contactLastName: "Lee", contactPhone: "123", contactEmail: "a@b.com", notes: "", demoAccountRequired: false, demoAccountName: nil, demoAccountPassword: nil),
              manualMetadata: nil, manualLocalizations: [], screenshotPaths: [], screenshotSimulatorUDIDs: [:], reviewAttachmentPaths: [],
              replaceScreenshots: false, releaseAutomatically: false, replaceActiveReviewVersion: false, testFlight: nil)
    }
}

private struct MacSettingsRunner: ProcessRunning {
    func run(executable: URL, arguments: [String], workingDirectory: URL?, additionalEnvironment: [String: String],
             standardInput: Data?, onOutput: ProcessRunner.OutputHandler?, terminateWhenOutput: ProcessRunner.OutputTerminationPredicate?) async throws -> CommandResult {
        XCTAssertTrue(arguments.contains("MacStore"))
        XCTAssertTrue(arguments.contains("generic/platform=macOS"))
        XCTAssertTrue(arguments.contains("-showBuildSettings"))
        return CommandResult(terminationStatus: 0, output: #"[{"buildSettings":{"PRODUCT_TYPE":"com.apple.product-type.application","WRAPPER_EXTENSION":"app","SUPPORTED_PLATFORMS":"macosx","SDKROOT":"macosx","PRODUCT_BUNDLE_IDENTIFIER":"com.example","MARKETING_VERSION":"1","CURRENT_PROJECT_VERSION":"1"}}]"#)
    }
}
