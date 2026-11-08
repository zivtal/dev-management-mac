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
                       locale: String? = nil, accent: CGColor? = nil) throws -> AppStoreScreenshotAsset {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(color ?? CGColor(red: 0.1, green: 0.3, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if color == nil {
            context.setFillColor(accent ?? CGColor(red: 0.8, green: 0.6, blue: 0.2, alpha: 1))
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

    /// watchOS screens are a black canvas with sparse text; the real Ultra capture was 96% black.
    private func watchAsset(contentPixels: Int, width: Int = 422, height: Int = 514,
                            displayType: String = "APP_WATCH_ULTRA") throws -> AppStoreScreenshotAsset {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        let bandWidth = min(width - 20, max(1, contentPixels / 20))
        context.fill(CGRect(x: 10, y: height / 2, width: bandWidth, height: 20))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        files.append(url)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return AppStoreScreenshotAsset(url: url, displayType: displayType)
    }

    func testWatchScreenWithSparseTextOnBlackCanvasIsValid() throws {
        let metrics = try AppStoreScreenshotValidator.validate(watchAsset(contentPixels: 8_000))
        XCTAssertGreaterThan(metrics.blackFraction, 0.95)
        XCTAssertLessThan(metrics.blackFraction, 0.99)
        XCTAssertFalse(metrics.isNearUniform(for: .appleWatch))
        XCTAssertTrue(metrics.isNearUniform(for: .iPhone))
    }

    func testWatchLaunchFrameWithOnlyClockIsStillBlank() throws {
        XCTAssertThrowsError(try AppStoreScreenshotValidator.validate(watchAsset(contentPixels: 800))) { error in
            XCTAssertTrue(error.localizedDescription.contains("APP_WATCH_ULTRA"))
            XCTAssertTrue(error.localizedDescription.contains("variance"))
        }
        XCTAssertThrowsError(try AppStoreScreenshotValidator.validate(watchAsset(contentPixels: 0)))
    }

    func testPhoneAndPadKeepTheStrictUniformThreshold() throws {
        let pad = try watchAsset(contentPixels: 220_000, width: 2064, height: 2752, displayType: "APP_IPAD_PRO_3GEN_129")
        XCTAssertThrowsError(try AppStoreScreenshotValidator.validate(pad)) { error in
            XCTAssertTrue(error.localizedDescription.contains("variance"))
        }
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

    @MainActor func testMacCanvasScalesASmallWindowUpToFillTheFrame() throws {
        // KeyPassX opened a 580 × 500 point window; at 2× that is 1160 × 1000 pixels on a 2560 × 1600 canvas.
        XCTAssertEqual(MacStoreScreenshotService.canvasRect(for: CGSize(width: 1160, height: 1000)),
                       CGRect(x: 352, y: 0, width: 1856, height: 1600))
        XCTAssertEqual(MacStoreScreenshotService.canvasRect(for: CGSize(width: 2560, height: 1600)),
                       CGRect(x: 0, y: 0, width: 2560, height: 1600))
        let input = try asset(width: 1160, height: 1000)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(input.url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let png = try MacStoreScreenshotService.canvas(image)
        let renderedSource = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let rendered = try XCTUnwrap(CGImageSourceCreateImageAtIndex(renderedSource, 0, nil))
        // The canvas background is gray 0.12; before scaling it covered ~72% of the frame.
        let metrics = try AppStoreScreenshotValidator.metrics(rendered)
        XCTAssertLessThan(metrics.dominantFraction, 0.6)
        XCTAssertFalse(metrics.isNearUniform(for: .mac))
    }

    @MainActor func testStoreCaptureWindowSizeIsSixteenByTenAndFitsTheScreen() {
        XCTAssertEqual(MacStoreScreenshotService.storeCaptureWindowSize(visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1079)),
                       CGSize(width: 1280, height: 800))
        XCTAssertEqual(MacStoreScreenshotService.storeCaptureWindowSize(visibleFrame: CGRect(x: 0, y: 0, width: 1280, height: 720)),
                       CGSize(width: 1152, height: 720))
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

    func testReadyTextGatesAutomaticCapturesOnly() throws {
        let plain = try asset()
        let supplied = AppStoreScreenshotAsset(url: plain.url, displayType: plain.displayType, platform: .iPad)
        let captured = AppStoreScreenshotAsset(url: plain.url, displayType: plain.displayType, platform: .iPad,
                                               automaticallyCaptured: true)
        let options = ["iPad": AppStoreScreenshotCaptureOptions(readyText: "Email")]
        XCTAssertEqual(try AppStoreScreenshotRecovery.validatedAssets([supplied],
            cacheDirectory: URL(fileURLWithPath: "/different-cache"), options: options, primaryLocale: "en-US"), [supplied])
        XCTAssertThrowsError(try AppStoreScreenshotRecovery.validatedAssets([captured],
            cacheDirectory: URL(fileURLWithPath: "/different-cache"), options: options, primaryLocale: "en-US"))
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
            case ("GET", "/v1/appScreenshotSets/new-set/appScreenshots"):
                return ["data": [["id": "new-shot", "attributes": ["assetDeliveryState": ["state": "COMPLETE"]]]]]
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

    // MARK: - Platform selection

    func testMacProjectIgnoresPhoneAndPadScreenshotsFoundInTheProjectFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        files.append(root)
        func place(_ source: AppStoreScreenshotAsset, at relativePath: String) throws {
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: source.url, to: url)
        }
        try place(try asset(width: 2064, height: 2752), at: "Screenshots/en-US/iPad-13/01-vault.png")
        try place(try asset(width: 1320, height: 2868), at: "Screenshots/en-US/iPhone-69/01-vault.png")
        try place(try asset(width: 2880, height: 1800), at: "Screenshots/mac/mac-window.png")
        let project = ManagedProject(id: UUID(), displayName: "App", folderPath: root.path,
            containerPath: root.appendingPathComponent("App.xcodeproj").path, containerKind: .project, scheme: "Mac",
            configuration: "Release", availableSchemes: ["Mac"], availableConfigurations: ["Release"], isEnabled: true,
            marketingVersion: "1", buildNumber: "1", applicationPlatform: .macOS)
        let service = AppStorePublishingService()

        for paths in [[String](), ["Screenshots"]] {
            let assets = service.localScreenshotAssets(project: project, configuredPaths: paths)
            XCTAssertEqual(assets.map(\.displayType), ["APP_DESKTOP"], "configured paths \(paths)")
            XCTAssertEqual(assets.map(\.url.lastPathComponent), ["mac-window.png"], "configured paths \(paths)")
        }
    }

    // MARK: - Batch processing

    /// Builds a service whose App Store Connect mock creates one set per locale/display type,
    /// reserves screenshots into them, and reports per-poll delivery states from
    /// `states(pollsSinceLastReservation, fileName)`. Sleeps are recorded, not awaited.
    private func batchService(
        timeout: Duration = .seconds(600),
        stallWindow: Duration = .seconds(120),
        requests: RequestRecorder,
        sleeps: RequestRecorder,
        reservations: RequestRecorder,
        states: @escaping @Sendable (Int, String) -> String
    ) throws -> AppStoreConnectService {
        let polls = RequestRecorder()
        let sets = RequestRecorder()
        let service = try service { request in
            let path = request.url!.path
            requests.append("\(request.httpMethod!) \(path)")
            switch (request.httpMethod!, path) {
            case ("GET", _) where path.hasPrefix("/v1/appStoreVersionLocalizations/") && path.hasSuffix("/appScreenshotSets"):
                return ["data": []]
            case ("POST", "/v1/appScreenshotSets"):
                let id = sets.values.isEmpty ? "new-set" : "set-\(sets.values.count + 1)"
                sets.append(id)
                return ["data": ["id": id]]
            case ("POST", "/v1/appScreenshots"):
                let body = try JSONSerialization.jsonObject(with: request.bodyData()) as? [String: Any]
                let data = body?["data"] as? [String: Any]
                let fileName = (data?["attributes"] as? [String: Any])?["fileName"] as? String ?? "?"
                let setID = (((data?["relationships"] as? [String: Any])?["appScreenshotSet"] as? [String: Any])?["data"] as? [String: Any])?["id"] as? String ?? "?"
                let id = "shot-\(reservations.values.count + 1)"
                reservations.append("\(id)=\(fileName)=\(setID)")
                polls.append("reset")
                return ["data": ["id": id, "attributes": ["uploadOperations": []]]]
            case ("GET", _) where path.hasPrefix("/v1/appScreenshotSets/") && path.hasSuffix("/appScreenshots"):
                let setID = String(path.split(separator: "/")[2])
                polls.append("poll")
                let sinceReservation = polls.values.reversed().firstIndex(of: "reset") ?? polls.values.count
                let deleted = Set(requests.values.compactMap { $0.hasPrefix("DELETE /v1/appScreenshots/") ? String($0.split(separator: "/").last!) : nil })
                let live = reservations.values.map { $0.split(separator: "=", maxSplits: 2).map(String.init) }
                    .filter { $0[2] == setID && !deleted.contains($0[0]) }
                return ["data": live.map { parts -> [String: Any] in
                    ["type": "appScreenshots", "id": parts[0],
                     "attributes": ["fileName": parts[1], "assetDeliveryState": ["state": states(sinceReservation, parts[1])]]]
                }]
            case ("PATCH", _) where path.hasPrefix("/v1/appScreenshotSets/") && path.hasSuffix("/relationships/appScreenshots"):
                let body = try JSONSerialization.jsonObject(with: request.bodyData()) as? [String: Any]
                let ids = (body?["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
                requests.append("ORDER \(path.split(separator: "/")[2]) \(ids.joined(separator: ","))")
                return [:]
            case ("PATCH", _) where path.hasPrefix("/v1/appScreenshots/"): return ["data": ["id": String(path.split(separator: "/").last!)]]
            case ("DELETE", _) where path.hasPrefix("/v1/appScreenshots/"): return [:]
            default: XCTFail("Unexpected request \(request.httpMethod!) \(path)"); return [:]
            }
        }
        service.screenshotProcessingPollInterval = .seconds(5)
        service.screenshotProcessingTimeout = timeout
        service.screenshotProcessingStallWindow = stallWindow
        service.screenshotProcessingSleep = { duration in sleeps.append("\(duration)") }
        return service
    }

    /// A distinct, valid screenshot saved under `name` so set-level duplicate detection does not trip.
    private func namedAsset(_ name: String, locale: String? = nil) throws -> AppStoreScreenshotAsset {
        let hue = CGFloat(name.unicodeScalars.reduce(0) { $0 + Int($1.value) } % 97) / 97
        let source = try asset(accent: CGColor(red: 0.5 + hue / 2, green: 0.9 - hue / 2, blue: 0.2 + hue / 3, alpha: 1))
        let url = source.url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: source.url, to: url)
        files.append(url)
        return AppStoreScreenshotAsset(url: url, displayType: source.displayType, locale: locale)
    }

    func testAllScreenshotsOfEverySetAreUploadedBeforeWaitingForProcessing() async throws {
        let requests = RequestRecorder(), sleeps = RequestRecorder(), reservations = RequestRecorder()
        let service = try batchService(requests: requests, sleeps: sleeps, reservations: reservations) { _, _ in "COMPLETE" }
        let output = RequestRecorder()
        try await service.uploadScreenshots([
            try namedAsset("01.png", locale: "en-US"), try namedAsset("02.png", locale: "en-US"),
            try namedAsset("01.png", locale: "he"), try namedAsset("02.png", locale: "he")
        ], localizationIDsByLocale: ["en-us": "loc", "he": "loc-he"], primaryLocale: "en-US", replaceExisting: true,
            onOutput: { output.append($0) })

        let values = requests.values
        let lastReservation = values.lastIndex(of: "POST /v1/appScreenshots")!
        let firstPoll = values.firstIndex { $0.hasPrefix("GET /v1/appScreenshotSets/") }!
        XCTAssertLessThan(lastReservation, firstPoll, "both locales' sets must be sent before the first processing poll")
        XCTAssertEqual(values.filter { $0 == "POST /v1/appScreenshotSets" }.count, 2)
        XCTAssertEqual(values.filter { $0 == "POST /v1/appScreenshots" }.count, 4)
        XCTAssertFalse(values.contains { $0.hasPrefix("DELETE") || $0.hasPrefix("ORDER") })
        XCTAssertEqual(output.values.filter { $0.hasPrefix("Uploaded screenshot") }.count, 4)
        XCTAssertEqual(sleeps.values.count, 0)
    }

    func testUniformlySlowProcessingSucceedsWithGrowingPatience() async throws {
        let requests = RequestRecorder(), sleeps = RequestRecorder(), reservations = RequestRecorder()
        // Every upload needs 350 s (70 polls) to finish. Attempt 1 gives up after the 120 s stall
        // window, attempt 2 after 240 s, and attempt 3 waits long enough.
        let service = try batchService(requests: requests, sleeps: sleeps, reservations: reservations) { sinceReservation, _ in
            sinceReservation < 70 ? "UPLOAD_COMPLETE" : "COMPLETE"
        }
        try await service.uploadScreenshots([try namedAsset("slow.png")], localizationIDsByLocale: ["en-us": "loc"],
            primaryLocale: "en-US", replaceExisting: true, onOutput: { _ in })
        XCTAssertEqual(reservations.values.count, 3)
        XCTAssertEqual(requests.values.filter { $0.hasPrefix("DELETE /v1/appScreenshots/") }.count, 2)
    }

    func testStalledScreenshotIsReplacedSoonAfterTheOthersFinish() async throws {
        let requests = RequestRecorder(), sleeps = RequestRecorder(), reservations = RequestRecorder()
        // 01 completes at once; 02 never leaves UPLOAD_COMPLETE until it is re-sent as shot-3.
        let service = try batchService(requests: requests, sleeps: sleeps, reservations: reservations) { _, name in
            let stuck = reservations.values.contains { $0.hasPrefix("shot-2=\(name)=") } && !reservations.values.contains { $0.hasPrefix("shot-3=") }
            return stuck ? "UPLOAD_COMPLETE" : "COMPLETE"
        }
        let output = RequestRecorder()
        try await service.uploadScreenshots([try namedAsset("01.png"), try namedAsset("02.png")],
            localizationIDsByLocale: ["en-us": "loc"], primaryLocale: "en-US", replaceExisting: true, onOutput: { output.append($0) })

        XCTAssertEqual(reservations.values, ["shot-1=01.png=new-set", "shot-2=02.png=new-set", "shot-3=02.png=new-set"])
        XCTAssertTrue(requests.values.contains("DELETE /v1/appScreenshots/shot-2"))
        XCTAssertFalse(requests.values.contains("DELETE /v1/appScreenshots/shot-1"))
        XCTAssertEqual(requests.values.filter { $0.hasPrefix("ORDER ") }, ["ORDER new-set shot-1,shot-3"])
        XCTAssertTrue(output.values.contains { $0.contains("02.png") && $0.contains("UPLOAD_COMPLETE") })
        // 120 s stall window at 5 s polls = 24 sleeps, far short of the 600 s timeout.
        XCTAssertEqual(sleeps.values.count, 24)
    }

    func testScreenshotStuckAfterEveryAttemptReportsItsLastState() async throws {
        let requests = RequestRecorder(), sleeps = RequestRecorder(), reservations = RequestRecorder()
        let service = try batchService(timeout: .seconds(10), requests: requests, sleeps: sleeps, reservations: reservations) { _, _ in "UPLOAD_COMPLETE" }
        do {
            try await service.uploadScreenshots([try namedAsset("stuck.png")], localizationIDsByLocale: ["en-us": "loc"],
                primaryLocale: "en-US", replaceExisting: true, onOutput: { _ in })
            XCTFail("expected a processing failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("stuck.png"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("UPLOAD_COMPLETE"), error.localizedDescription)
        }
        XCTAssertEqual(reservations.values.count, 3, "three upload attempts before giving up")
        XCTAssertEqual(requests.values.filter { $0.hasPrefix("DELETE /v1/appScreenshots/") }.count, 3, "no stuck placeholder is left behind")
    }

    func testFailedProcessingIsRetriedOnceBeforeSurfacingAppleError() async throws {
        let requests = RequestRecorder(), sleeps = RequestRecorder(), reservations = RequestRecorder()
        let service = try batchService(requests: requests, sleeps: sleeps, reservations: reservations) { _, _ in
            reservations.values.count < 2 ? "FAILED" : "COMPLETE"
        }
        try await service.uploadScreenshots([try namedAsset("retry.png")], localizationIDsByLocale: ["en-us": "loc"],
            primaryLocale: "en-US", replaceExisting: true, onOutput: { _ in })
        XCTAssertEqual(reservations.values.count, 2)
        XCTAssertTrue(requests.values.contains("DELETE /v1/appScreenshots/shot-1"))
        XCTAssertEqual(sleeps.values.count, 0, "a FAILED state is acted on immediately")
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

private extension URLRequest {
    func bodyData() throws -> Data {
        if let httpBody { return httpBody }
        let stream = try XCTUnwrap(httpBodyStream)
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? AppStoreConnectError.invalidResponse }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
