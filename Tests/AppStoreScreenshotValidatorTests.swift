import AppKit
import CryptoKit
import ImageIO
import XCTest
@testable import DevManagement

final class AppStoreScreenshotValidatorTests: XCTestCase {
    private var files: [URL] = []
    override func tearDown() {
        for url in files { try? FileManager.default.removeItem(at: url) }
        ScreenshotProtocol.handler = nil
        super.tearDown()
    }

    private func asset(color: CGColor? = nil, width: Int = 2064, height: Int = 2752,
                       locale: String? = nil) throws -> AppStoreScreenshotAsset {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(color ?? CGColor(red: 0.1, green: 0.3, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if color == nil {
            context.setFillColor(CGColor(red: 0.8, green: 0.6, blue: 0.2, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        files.append(url)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return AppStoreScreenshotAsset(url: url, displayType: "APP_IPAD_PRO_3GEN_129", locale: locale)
    }

    func testRejectsBlackWhiteAndUniformColoredImages() throws {
        for color in [CGColor(gray: 0, alpha: 1), CGColor(gray: 1, alpha: 1),
                      CGColor(red: 0.3, green: 0.6, blue: 0.7, alpha: 1)] {
            let image = try asset(color: color)
            XCTAssertThrowsError(try AppStoreScreenshotValidator.validate(image)) { error in
                XCTAssertTrue(error.localizedDescription.contains(image.url.path))
                XCTAssertTrue(error.localizedDescription.contains(image.displayType))
                XCTAssertTrue(error.localizedDescription.contains("variance"))
            }
        }
    }

    func testTinySpinnerCannotMakeBlackFramePass() throws {
        let context = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8,
            bytesPerRow: 1024, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 125, y: 125, width: 6, height: 6))
        let metrics = try AppStoreScreenshotValidator.metrics(context.makeImage()!)
        XCTAssertGreaterThan(metrics.blackFraction, 0.99)
        XCTAssertTrue(metrics.isNearUniform)
    }

    func testValidContentHasLuminanceVariation() throws {
        let metrics = try AppStoreScreenshotValidator.validate(asset())
        XCTAssertGreaterThan(metrics.variance, 4)
        XCTAssertLessThan(metrics.dominantFraction, 0.95)
    }

    func testRejectsWrongSizeAndWrongDeviceFamily() throws {
        XCTAssertThrowsError(try AppStoreScreenshotValidator.validate(asset(width: 100, height: 100)))
        let ipad = try asset()
        let phone = AppStoreScreenshotAsset(url: ipad.url, displayType: "APP_IPHONE_67", platform: .iPhone)
        XCTAssertThrowsError(try AppStoreScreenshotValidator.validate(phone))
    }

    func testRejectsDuplicatesInSameSetButAllowsLocalizedReuse() throws {
        let first = try asset(), second = try asset()
        XCTAssertThrowsError(try AppStoreScreenshotValidator.validateSet([first, second]))
        let hebrew = AppStoreScreenshotAsset(url: first.url, displayType: first.displayType, locale: "he")
        XCTAssertNoThrow(try AppStoreScreenshotValidator.validateSet([first, hebrew]))
        let english = AppStoreScreenshotAsset(url: second.url, displayType: second.displayType, locale: "en-US")
        XCTAssertThrowsError(try AppStoreScreenshotValidator.validateSet([first, english], primaryLocale: "en-US"))
    }

    func testKnownWelcomeAndUnlockScreensAreBlocked() {
        XCTAssertTrue(AppStoreScreenshotValidator.isKnownEmptyScreen("Your vault. Your keys.\nNo vaults yet. Import a KeePass vault"))
        XCTAssertTrue(AppStoreScreenshotValidator.isKnownEmptyScreen("Master password\nUnlock"))
        XCTAssertTrue(AppStoreScreenshotValidator.isKnownEmptyScreen("Your Watch vault. Wrist Detection is required."))
        XCTAssertFalse(AppStoreScreenshotValidator.isKnownEmptyScreen("Vault entries\nEmail\nBank"))
    }

    func testConfiguredReadyTextMustBeVisible() throws {
        XCTAssertThrowsError(try AppStoreScreenshotValidator.validate(asset(), readyText: "Sample vault ready"))
        let options = try JSONDecoder().decode(AppStoreScreenshotCaptureOptions.self,
            from: Data(#"{"readyText":"Fixture"}"#.utf8))
        XCTAssertEqual(options.launchArguments, [])
        XCTAssertEqual(options.readyText, "Fixture")
    }

    func testIPadCaptureRetriesBlackFirstFramesAndRequiresTwoValidFrames() async throws {
        let black = try asset(color: CGColor(gray: 0, alpha: 1)), content = try asset()
        var captures = 0, failures = 0
        let result = try await AppStoreScreenshotCapture.waitForContent(options: .init(timeoutSeconds: 12), capture: {
            captures += 1
            return captures < 3 ? black : content
        }, pause: {}, onOutput: { _ in failures += 1 })
        XCTAssertEqual(result.displayType, "APP_IPAD_PRO_3GEN_129")
        XCTAssertEqual(result.url, content.url)
        XCTAssertEqual(captures, 4)
        XCTAssertEqual(failures, 2)
    }

    func testIPadCaptureAbortsIfEveryFrameIsBlack() async throws {
        let black = try asset(color: CGColor(gray: 0, alpha: 1))
        var captures = 0
        do {
            _ = try await AppStoreScreenshotCapture.waitForContent(options: .init(timeoutSeconds: 4), capture: {
                captures += 1; return black
            }, pause: {})
            XCTFail("Black capture must not become a successful screenshot")
        } catch { XCTAssertTrue(error.localizedDescription.contains("APP_IPAD_PRO_3GEN_129")) }
        XCTAssertEqual(captures, 2)
    }

    func testMacRawWindowValidationRetriesBeforeCanvasRendering() async throws {
        let content = try asset()
        var captures = 0
        _ = try await AppStoreScreenshotCapture.waitForContent(options: .init(timeoutSeconds: 8), capture: {
            captures += 1
            if captures == 1 { throw AppStoreScreenshotValidationError(issues: ["Blank Mac window"]) }
            return content
        }, pause: {})
        XCTAssertEqual(captures, 3)
    }

    @MainActor func testMacCanvasProducesOpaqueValidDesktopPNGWithRealContent() throws {
        let input = try asset(width: 1600, height: 1000)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(input.url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let png = try MacStoreScreenshotService.canvas(image)
        let renderedSource = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let rendered = try XCTUnwrap(CGImageSourceCreateImageAtIndex(renderedSource, 0, nil))
        XCTAssertEqual(rendered.width, 2560)
        XCTAssertEqual(rendered.height, 1600)
        XCTAssertTrue([CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(rendered.alphaInfo))
        XCTAssertFalse(try AppStoreScreenshotValidator.metrics(rendered).isNearUniform)
        let output = input.url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".png")
        files.append(output)
        try png.write(to: output)
        XCTAssertNoThrow(try AppStoreScreenshotValidator.validate(.init(url: output, displayType: "APP_DESKTOP", platform: .mac)))
    }

    func testInvalidGeneratedCacheIsRemovedButInvalidSuppliedImageIsPreserved() throws {
        let cached = try asset(color: CGColor(gray: 0, alpha: 1))
        let valid = try asset()
        let result = try AppStoreScreenshotRecovery.validatedAssets([cached, valid],
            cacheDirectory: cached.url.deletingLastPathComponent(), options: [:], primaryLocale: "en-US")
        XCTAssertEqual(result, [valid])
        XCTAssertFalse(FileManager.default.fileExists(atPath: cached.url.path))
        let supplied = try asset(color: CGColor(gray: 1, alpha: 1))
        XCTAssertThrowsError(try AppStoreScreenshotRecovery.validatedAssets([supplied],
            cacheDirectory: URL(fileURLWithPath: "/different-cache"), options: [:], primaryLocale: "en-US"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: supplied.url.path))
    }

    func testSimulatorInstallRetriesAppconduitRaceAndStopsAtLimit() async throws {
        let transient = ProcessRunnerError.commandFailed(executable: "xcrun", status: 24,
            output: "IXErrorDomain: Uninstall requested error")
        var attempts = 0
        try await ScreenshotSimulatorInstallation.run(install: {
            attempts += 1
            if attempts < 2 { throw transient }
        }, pause: {})
        XCTAssertEqual(attempts, 2)
        attempts = 0
        do {
            try await ScreenshotSimulatorInstallation.run(install: { attempts += 1; throw transient }, pause: {})
            XCTFail("Persistent installation errors must fail")
        } catch { XCTAssertEqual(attempts, 3) }
    }

    func testSimulatorInstallDoesNotRetryUnrelatedErrors() async throws {
        var attempts = 0
        do {
            try await ScreenshotSimulatorInstallation.run(install: {
                attempts += 1
                throw ProcessRunnerError.commandFailed(executable: "xcrun", status: 1, output: "Invalid signature")
            }, pause: {})
            XCTFail()
        } catch { XCTAssertEqual(attempts, 1) }
    }

    func testIPadLaunchUsesSelectedUDIDAndDemoArguments() {
        XCTAssertEqual(AppStorePublishingService.screenshotLaunchArguments(udid: "ipad-udid",
            bundleIdentifier: "test.app", launchArguments: ["-demo", "YES"], preservePreparedScreen: false),
            ["simctl", "launch", "--terminate-running-process", "ipad-udid", "test.app", "-demo", "YES"])
        XCTAssertEqual(AppStorePublishingService.screenshotLaunchArguments(udid: "prepared-ipad",
            bundleIdentifier: "test.app", launchArguments: [], preservePreparedScreen: true),
            ["simctl", "launch", "prepared-ipad", "test.app"])
    }

    func testFailedIPadBlocksPreviewEvenWithValidPhone() {
        let preview = AppStoreScreenshotPreview(devices: [
            .init(platform: .iPhone, name: nil, runtime: nil, state: .captured),
            .init(platform: .iPad, name: nil, runtime: nil, state: .failed("black image"))
        ], screenshots: [])
        XCTAssertEqual(preview.blockingIssues, ["iPad: black image"])
    }

    func testInvalidScreenshotFailsBeforeAnyASCRequestOrDeletion() async throws {
        let service = try service { _ in XCTFail("Invalid pixels must fail before network access"); return [:] }
        let black = try asset(color: CGColor(gray: 0, alpha: 1))
        let valid = try asset()
        do {
            try await service.uploadScreenshots([valid, black], localizationIDsByLocale: ["en-us": "loc"],
                primaryLocale: "en-US", replaceExisting: true, onOutput: { _ in })
            XCTFail()
        } catch { XCTAssertTrue(error.localizedDescription.contains("variance")) }
        do {
            try await service.replaceScreenshots(bundleIdentifier: "test.app", version: "0.1.34",
                displayType: black.displayType, screenshots: [black], onOutput: { _ in })
            XCTFail()
        } catch { XCTAssertTrue(error.localizedDescription.contains("variance")) }
    }

    func testRepairDeletesOnlySelectedSetAndPreservesExistingVersionBuild() async throws {
        let screenshot = try asset()
        let requests = RequestRecorder()
        let service = try service { request in
            let path = request.url!.path
            requests.append("\(request.httpMethod!) \(path)")
            switch (request.httpMethod!, path) {
            case ("GET", "/v1/apps"): return ["data": [["id": "app"]]]
            case ("GET", "/v1/apps/app/appStoreVersions"):
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                XCTAssertTrue(query.contains(.init(name: "filter[platform]", value: "IOS")))
                XCTAssertTrue(query.contains(.init(name: "filter[versionString]", value: "0.1.34")))
                return ["data": [["id": "old-version", "attributes": ["versionString": "0.1.34", "platform": "IOS", "appStoreState": "REJECTED"]]]]
            case ("GET", "/v1/appStoreVersions/old-version/appStoreVersionLocalizations"):
                return ["data": [["id": "loc", "attributes": ["locale": "en-US"]]]]
            case ("GET", "/v1/appStoreVersionLocalizations/loc/appScreenshotSets"):
                return ["data": [["id": "ipad-set", "attributes": ["screenshotDisplayType": "APP_IPAD_PRO_3GEN_129"]]]]
            case ("DELETE", "/v1/appScreenshotSets/ipad-set"): return [:]
            case ("POST", "/v1/appScreenshotSets"): return ["data": ["id": "new-set"]]
            case ("POST", "/v1/appScreenshots"): return ["data": ["id": "new-shot", "attributes": ["uploadOperations": []]]]
            case ("PATCH", "/v1/appScreenshots/new-shot"): return ["data": ["id": "new-shot"]]
            case ("GET", "/v1/appScreenshots/new-shot"):
                return ["data": ["id": "new-shot", "attributes": ["assetDeliveryState": ["state": "COMPLETE"]]]]
            default: XCTFail("Unexpected mutation/request \(request)"); return [:]
            }
        }
        try await service.replaceScreenshots(bundleIdentifier: "test.app", version: "0.1.34",
            displayType: screenshot.displayType, screenshots: [screenshot], onOutput: { _ in })
        XCTAssertTrue(requests.values.contains("DELETE /v1/appScreenshotSets/ipad-set"))
        XCTAssertFalse(requests.values.contains { $0.contains("/build") || $0.contains("reviewSubmission") })
    }

    func testRepairRefusesVersionInReviewBeforeDeletingAnything() async throws {
        let screenshot = try asset()
        let service = try service { request in
            XCTAssertEqual(request.httpMethod, "GET")
            if request.url!.path == "/v1/apps" { return ["data": [["id": "app"]]] }
            return ["data": [["id": "version", "attributes": ["versionString": "0.1.34", "platform": "IOS", "appStoreState": "IN_REVIEW"]]]]
        }
        do {
            try await service.replaceScreenshots(bundleIdentifier: "test.app", version: "0.1.34",
                displayType: screenshot.displayType, screenshots: [screenshot], onOutput: { _ in })
            XCTFail()
        } catch { XCTAssertTrue(error.localizedDescription.contains("editable")) }
    }

    private func service(_ handler: @escaping (URLRequest) throws -> [String: Any]) throws -> AppStoreConnectService {
        ScreenshotProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScreenshotProtocol.self]
        return try AppStoreConnectService(issuerID: "issuer", keyID: "key",
            privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation, session: URLSession(configuration: configuration))
    }
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var values: [String] { lock.lock(); defer { lock.unlock() }; return stored }
    func append(_ value: String) { lock.lock(); defer { lock.unlock() }; stored.append(value) }
}
private final class ScreenshotProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> [String: Any])?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let result = try Self.handler!(request)
            let data = try JSONSerialization.data(withJSONObject: result)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
