import CryptoKit
import XCTest
@testable import DevManagement

final class StandalonePublishingTests: XCTestCase {
    func testFirstRecordContainsBothPlatformsAndOneAppInfo() throws {
        let payload = try AppStoreAppRecord(name: "Slate WiFi", bundleID: "app.slatewifi.ios",
            sku: "slate-wifi", locale: "en-US", version: "1.0.6", platforms: [.iOS, .macOS]).payload()
        let data = try XCTUnwrap(payload["data"] as? [String: Any])
        let attributes = try XCTUnwrap(data["attributes"] as? [String: String])
        XCTAssertEqual(attributes["bundleId"], "app.slatewifi.ios")
        let included = try XCTUnwrap(payload["included"] as? [[String: Any]])
        let versions = included.filter { $0["type"] as? String == "appStoreVersions" }
        XCTAssertEqual(Set(versions.compactMap { ($0["attributes"] as? [String: String])?["platform"] }),
                       ["IOS", "MAC_OS"])
        XCTAssertEqual(included.filter { $0["type"] as? String == "appInfos" }.count, 1)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: payload))
    }

    func testInvalidAppRecordCannotBeSent() {
        XCTAssertThrowsError(try AppStoreAppRecord(name: "", bundleID: "*", sku: "", locale: "invalid",
            version: "", platforms: []).payload())
    }

    @MainActor
    func testAppleSignInRejectsLookalikeHostsAndInsecureNavigation() throws {
        for address in ["https://apple.com.attacker.test/", "http://apple.com/", "file:///tmp/page", "https://notapple.com/"] {
            XCTAssertFalse(AppleWebSession.allows(try XCTUnwrap(URL(string: address))))
        }
        XCTAssertTrue(AppleWebSession.allows(URL(string: "https://idmsa.apple.com/appleauth/auth")!))
        XCTAssertTrue(AppleWebSession.allows(URL(string: "https://appstoreconnect.apple.com/apps")!))
    }

    func testMacBuildUploadLookupCannotReuseIOSBuildWithSameVersion() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        func upload(_ id: String, _ platform: String) -> [String: Any] {
            ["id": id, "attributes": ["cfBundleShortVersionString": "1.0.6", "cfBundleVersion": "7",
                "platform": platform, "state": ["state": "COMPLETE"]]]
        }
        StubURLProtocol.enqueue(.init(match: { $0.url?.path == "/v1/apps/app/buildUploads" },
            statusCode: 200, body: ["data": [upload("ios", "IOS"), upload("mac", "MAC_OS")]]))
        let service = try AppStoreConnectService(issuerID: "issuer", keyID: "key",
            privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation,
            session: StubURLProtocol.session(), platform: .macOS)
        let build = try await service.buildUpload(appID: "app", marketingVersion: "1.0.6", buildNumber: "7")
        XCTAssertEqual(build?.id, "mac")
        let url = try XCTUnwrap(StubURLProtocol.requests.first?.url)
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "filter[platform]" }?.value, "MAC_OS")
    }

    func testMacExportPinsSeparateInstallerIdentityAndPreservesVersion() throws {
        let app = DistributionSigningIdentity(teamID: "TEAM", commonName: "Apple Distribution", sha1Fingerprint: "APP")
        let installer = DistributionSigningIdentity(teamID: "TEAM", commonName: "Installer", sha1Fingerprint: "INSTALLER")
        let options = AppStorePublishingService.exportOptions(teamID: "TEAM", signingIdentity: app,
            provisioningProfiles: ["app.example": "profile"], installerIdentity: installer)
        XCTAssertEqual(options["signingCertificate"] as? String, "APP")
        XCTAssertEqual(options["installerSigningCertificate"] as? String, "INSTALLER")
        XCTAssertEqual(options["manageAppVersionAndBuildNumber"] as? Bool, false)
        XCTAssertEqual(options["signingStyle"] as? String, "manual")
        let certificate = AppStoreConnectService.distributionCertificateCreateBody(csrContent: "csr", purpose: .macInstaller)
        let data = try XCTUnwrap(certificate["data"] as? [String: Any])
        XCTAssertEqual((data["attributes"] as? [String: String])?["certificateType"], "MAC_INSTALLER_DISTRIBUTION")
        let profile = AppStoreConnectService.appStoreProfileCreateBody(name: "Mac", bundleIDResourceID: "bundle",
            certificateID: "cert", platform: .macOS)
        XCTAssertEqual(((profile["data"] as? [String: Any])?["attributes"] as? [String: String])?["profileType"], "MAC_APP_STORE")
        XCTAssertFalse(DistributionCertificatePurpose.macInstaller.acceptedTypes.contains("DISTRIBUTION"))
    }

    func testMacArchiveReadsContentsInfoPlist() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let contents = root.appendingPathComponent("Products/Applications/Example.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "app.example",
            "CFBundleShortVersionString": "1.0.6", "CFBundleVersion": "7"], format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        let metadata = try AppStorePublishingService.archiveMetadata(at: root, expectedBundleIdentifier: "app.example")
        XCTAssertEqual(metadata.version, "1.0.6")
        XCTAssertEqual(metadata.buildNumber, "7")
        XCTAssertEqual(AppStorePublishingService.archivedBundleIdentifiers(at: root), ["app.example"])
    }

    func testMacDevelopmentOnlyEntitlementsDoNotBlockDistributionProfiles() {
        XCTAssertEqual(AppStorePublishingService.requiredProfileEntitlementKeys(from: [
            "com.apple.security.app-sandbox": true, "com.apple.security.get-task-allow": true,
            "com.apple.security.network.client": true, "com.apple.developer.icloud-services": ["CloudKit"]
        ]), ["com.apple.developer.icloud-services"])
    }

    func testPortableMacArchiveCannotBePublishedAsStoreApp() {
        XCTAssertThrowsError(try MacStoreArchiveValidation.validate(
            info: ["LSApplicationCategoryType": "public.app-category.utilities"], entitlements: [:]))
        XCTAssertThrowsError(try MacStoreArchiveValidation.validate(
            info: [:], entitlements: ["com.apple.security.app-sandbox": true]))
        XCTAssertNoThrow(try MacStoreArchiveValidation.validate(
            info: ["LSApplicationCategoryType": "public.app-category.utilities"],
            entitlements: ["com.apple.security.app-sandbox": true]))
    }

    func testMacScreenshotsRequireLandscapeStoreDimensions() {
        XCTAssertEqual(AppStorePublishingService.screenshotDisplayType(width: 2560, height: 1600, platform: .mac), "APP_DESKTOP")
        XCTAssertNil(AppStorePublishingService.screenshotDisplayType(width: 1600, height: 2560, platform: .mac))
        XCTAssertNil(AppStorePublishingService.screenshotDisplayType(width: 1320, height: 2868, platform: .mac))
    }
}
