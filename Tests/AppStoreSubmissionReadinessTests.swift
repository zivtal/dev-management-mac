import CryptoKit
import XCTest
@testable import DevManagement

final class AppStoreSubmissionReadinessTests: XCTestCase {
    override func tearDown() { ReadinessProtocol.handler = nil; super.tearDown() }

    func testEmptyMacDraftProducesChecklistWithoutMutatingApple() async throws {
        let service = try service { request in
            XCTAssertEqual(request.httpMethod, "GET")
            switch request.url!.path {
            case "/v1/appStoreVersions/mac": return ["data": self.version()]
            case "/v1/appStoreVersions/mac/build", "/v1/appStoreVersions/mac/appStoreReviewDetail": return ["data": NSNull()]
            case "/v1/appStoreVersions/mac/appStoreVersionLocalizations": return ["data": []]
            default: XCTFail("Unexpected request"); return [:]
            }
        }
        let readiness = try await service.submissionReadiness(versionID: "mac")
        XCTAssertFalse(readiness.isReady)
        XCTAssertThrowsError(try readiness.requireReady())
        XCTAssertTrue(readiness.text.contains("[MISSING] Processed build attached"))
        XCTAssertTrue(readiness.text.contains("[MISSING] Processed APP_DESKTOP screenshots"))
        XCTAssertTrue(readiness.text.contains("MAC_OS 1.0: PREPARE_FOR_SUBMISSION"))
    }

    func testCompleteMacSubmissionAcceptsOptionalEmptyMarketingAndPromotionalText() async throws {
        let service = try completeService()
        let readiness = try await service.submissionReadiness(versionID: "mac", expectedVersion: "1.0", expectedBuildID: "build",
            requiredDemoVideoURL: "https://example.com/demo")
        XCTAssertTrue(readiness.isReady, readiness.text)
        XCTAssertNoThrow(try readiness.requireReady())
        XCTAssertTrue(readiness.text.contains("[OPTIONAL] en-US: promotionalText"))
    }

    func testWrongAttachedBuildAndMissingDemoVideoBlockSubmission() async throws {
        let service = try completeService()
        let readiness = try await service.submissionReadiness(versionID: "mac", expectedVersion: "2.0", expectedBuildID: "wrong",
            requiredDemoVideoURL: "https://example.com/other")
        XCTAssertThrowsError(try readiness.requireReady())
        XCTAssertTrue(readiness.text.contains("[MISSING] Attached build matches uploaded build"))
        XCTAssertTrue(readiness.text.contains("[MISSING] Hardware demo video"))
    }

    func testMissingOrBlankReviewNotesAreOptionalInSubmissionChecklist() async throws {
        for notes in [nil, "", "  \n "] as [String?] {
            let service = try completeService(notes: notes)
            let readiness = try await service.submissionReadiness(versionID: "mac")
            XCTAssertNoThrow(try readiness.requireReady(), readiness.text)
            XCTAssertTrue(readiness.text.contains("[OPTIONAL] App Review: notes"))
        }
    }

    func testBlankOptionalNotesStillBlockWhenHardwareVideoIsRequired() async throws {
        let service = try completeService(notes: nil)
        let readiness = try await service.submissionReadiness(versionID: "mac",
            requiredDemoVideoURL: "https://example.com/demo")
        XCTAssertThrowsError(try readiness.requireReady())
        XCTAssertTrue(readiness.text.contains("[MISSING] Hardware demo video in review notes"))
    }

    func testAuthenticationFailureIsNotReportedAsAnEmptyMacDraft() async throws {
        let service = try service { _ in throw URLError(.userAuthenticationRequired) }
        do { _ = try await service.doctor(appID: "app"); XCTFail("Authentication errors must propagate") }
        catch { XCTAssertTrue(error is URLError) }
    }

    func testDoctorUsesMacFilterForBuildsAndVersions() async throws {
        let service = try service { request in
            XCTAssertEqual(request.httpMethod, "GET")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            switch request.url!.path {
            case "/v1/builds": XCTAssertTrue(query.contains(.init(name: "filter[preReleaseVersion.platform]", value: "MAC_OS")))
            case "/v1/apps/app/appStoreVersions": XCTAssertTrue(query.contains(.init(name: "filter[platform]", value: "MAC_OS")))
            default: XCTFail()
            }
            return ["data": []]
        }
        let text = try await service.doctor(appID: "app")
        XCTAssertTrue(text.contains("MAC_OS: 0 TestFlight build(s)"))
        XCTAssertTrue(text.contains("[MISSING] App Store version"))
    }

    func testMacBuildNumberMustIncreaseAcrossMarketingVersions() async throws {
        let service = try service { _ in ["data": [["id": "old", "attributes": ["version": "12"]]]] }
        do { try await service.validateNewMacBuildNumber(appID: "app", buildNumber: "11"); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("across all versions")) }
        try await service.validateNewMacBuildNumber(appID: "app", buildNumber: "13")
    }

    func testSubmissionIsNotSuccessfulUntilVersionStateAndBuildAreVerified() async throws {
        let service = try service { _ in ["data": self.version()] }
        do { try await service.waitForSubmittedVersion(versionID: "mac", buildID: "build", attempts: 1, onOutput: { _ in }); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("not confirmed")) }
        let submitted = try self.service { _ in
            var v = self.version(state: "WAITING_FOR_REVIEW")
            v["relationships"] = ["build": ["data": ["id": "build"]]]
            return ["data": v]
        }
        try await submitted.waitForSubmittedVersion(versionID: "mac", buildID: "build", attempts: 1, onOutput: { _ in })
    }

    private func version(state: String = "PREPARE_FOR_SUBMISSION") -> [String: Any] {
        ["id": "mac", "attributes": ["platform": "MAC_OS", "versionString": "1.0", "appStoreState": state,
                                      "copyright": "2026 Example", "releaseType": "MANUAL"]]
    }
    private func completeService(notes: String? = "Demo: https://example.com/demo") throws -> AppStoreConnectService {
        try service { request in
            XCTAssertEqual(request.httpMethod, "GET")
            switch request.url!.path {
            case "/v1/appStoreVersions/mac": return ["data": self.version()]
            case "/v1/appStoreVersions/mac/build": return ["data": ["id": "build", "attributes": ["processingState": "VALID"]]]
            case "/v1/builds/build/preReleaseVersion": return ["data": ["attributes": ["platform": "MAC_OS", "version": "1.0"]]]
            case "/v1/appStoreVersions/mac/appStoreVersionLocalizations":
                return ["data": [["id": "english", "attributes": ["locale": "en-US", "description": "A router app", "keywords": "router", "supportUrl": "https://example.com"]]]]
            case "/v1/appStoreVersionLocalizations/english/appScreenshotSets":
                return ["data": [["id": "desktop", "attributes": ["screenshotDisplayType": "APP_DESKTOP"]]]]
            case "/v1/appScreenshotSets/desktop/appScreenshots":
                return ["data": [["attributes": ["assetDeliveryState": ["state": "COMPLETE"]]]]]
            case "/v1/appStoreVersions/mac/appStoreReviewDetail":
                return ["data": ["attributes": ["contactFirstName": "Pat", "contactLastName": "Lee", "contactEmail": "pat@example.com",
                                                "contactPhone": "123", "notes": notes as Any? ?? NSNull(), "demoAccountRequired": false]]]
            default: XCTFail("Unexpected request \(request.url!)"); return [:]
            }
        }
    }
    private func service(_ handler: @escaping (URLRequest) throws -> [String: Any]) throws -> AppStoreConnectService {
        ReadinessProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ReadinessProtocol.self]
        return try AppStoreConnectService(issuerID: "issuer", keyID: "key", privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation,
            session: URLSession(configuration: config), platform: .macOS)
    }
}

private final class ReadinessProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> [String: Any])?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let body = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: body))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
