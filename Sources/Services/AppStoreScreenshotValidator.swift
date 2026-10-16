import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Vision

struct AppStoreScreenshotCaptureOptions: Codable, Equatable, Sendable {
    var launchArguments: [String] = []
    /// Text visible only after the demo/content screen has finished loading.
    var readyText: String? = nil
    var timeoutSeconds: Int? = nil

    init(launchArguments: [String] = [], readyText: String? = nil, timeoutSeconds: Int? = nil) {
        self.launchArguments = launchArguments; self.readyText = readyText; self.timeoutSeconds = timeoutSeconds
    }
    private enum CodingKeys: String, CodingKey { case launchArguments, readyText, timeoutSeconds }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        launchArguments = try values.decodeIfPresent([String].self, forKey: .launchArguments) ?? []
        readyText = try values.decodeIfPresent(String.self, forKey: .readyText)
        timeoutSeconds = try values.decodeIfPresent(Int.self, forKey: .timeoutSeconds)
    }
}

struct AppStoreScreenshotValidationError: LocalizedError {
    let issues: [String]
    var errorDescription: String? { issues.joined(separator: "\n") }
}

/// Checks the actual decoded image, not PNG metadata or ASC's delivery status.
enum AppStoreScreenshotValidator {
    struct Metrics {
        let mean: Double
        let variance: Double
        let blackFraction: Double
        let whiteFraction: Double
        let dominantFraction: Double
        let digest: String
        var isNearUniform: Bool {
            variance < 4 || blackFraction >= 0.95 || whiteFraction >= 0.95 || dominantFraction >= 0.95
        }
    }

    static func metrics(_ image: CGImage) throws -> Metrics {
        let side = 256, count = side * side
        var pixels = [UInt8](repeating: 255, count: count * 4)
        guard let context = CGContext(data: &pixels, width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw AppStoreScreenshotValidationError(issues: [L10n.text("Could not decode screenshot pixels.")])
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        var sum = 0.0, squares = 0.0, black = 0, white = 0
        var colors: [Int: Int] = [:]
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
            let y = 0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
            sum += y; squares += y * y
            if max(r, g, b) <= 12 { black += 1 }
            if min(r, g, b) >= 243 { white += 1 }
            colors[(r / 16) << 8 | (g / 16) << 4 | (b / 16), default: 0] += 1
        }
        let n = Double(count), mean = sum / n
        return Metrics(mean: mean, variance: max(0, squares / n - mean * mean),
            blackFraction: Double(black) / n, whiteFraction: Double(white) / n,
            dominantFraction: Double(colors.values.max() ?? 0) / n,
            digest: SHA256.hash(data: Data(pixels)).map { String(format: "%02x", $0) }.joined())
    }

    @discardableResult
    static func validate(_ asset: AppStoreScreenshotAsset, readyText: String? = nil) throws -> Metrics {
        func fail(_ reason: String) -> AppStoreScreenshotValidationError {
            AppStoreScreenshotValidationError(issues: [L10n.format("Screenshot %@ [%@]: %@", asset.url.path, asset.displayType, reason)])
        }
        guard let source = CGImageSourceCreateWithURL(asset.url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw fail(L10n.text("Could not decode screenshot pixels."))
        }
        guard AppStorePublishingService.screenshotDisplayType(width: image.width, height: image.height,
            platform: asset.platform) == asset.displayType,
              AppStoreScreenshotPlatform(displayType: asset.displayType) == asset.platform else {
            throw fail(L10n.format("Invalid dimensions: %d × %d.", image.width, image.height))
        }
        let values = try metrics(image)
        guard !values.isNearUniform else {
            throw fail(L10n.format("Blank or near-uniform image (mean %.2f, variance %.2f, dominant color %.2f%%).",
                values.mean, values.variance, values.dominantFraction * 100))
        }
        let text = try recognizedText(image)
        guard !isKnownEmptyScreen(text) else {
            throw fail(L10n.text("A welcome or locked-vault screen is visible. Prepare a demo content screen."))
        }
        if let readyText = readyText?.nilIfEmpty, !text.localizedCaseInsensitiveContains(readyText) {
            throw fail(L10n.format("Waiting for demo content text: %@", readyText))
        }
        return values
    }

    static func recognizedText(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    static func isKnownEmptyScreen(_ text: String) -> Bool {
        let text = text.lowercased()
        return text.contains("no vaults yet") || text.contains("open a keepass vault to get started")
            || (text.contains("master password") && (text.contains("unlock vault") || text.contains("unlock")))
    }

    static func validateSet(_ assets: [AppStoreScreenshotAsset], primaryLocale: String = "en-US") throws {
        var issues: [String] = [], digests: [String: Set<String>] = [:]
        for asset in assets {
            do {
                let result = try validate(asset)
                let locale = AppStoreLocale.canonicalIdentifier(asset.locale ?? primaryLocale) ?? primaryLocale
                let key = "\(locale)|\(asset.displayType)"
                if !digests[key, default: []].insert(result.digest).inserted {
                    issues.append(L10n.format("Screenshot %@ [%@]: %@", asset.url.path, asset.displayType,
                        L10n.text("Duplicate image within the screenshot set.")))
                }
            } catch { issues.append(error.localizedDescription) }
        }
        if !issues.isEmpty { throw AppStoreScreenshotValidationError(issues: issues) }
    }
}

/// Two consecutive validated frames, with a bounded retry for boot/launch/privacy transitions.
enum AppStoreScreenshotCapture {
    static func waitForContent(options: AppStoreScreenshotCaptureOptions,
        capture: () async throws -> AppStoreScreenshotAsset,
        pause: () async throws -> Void = { try await Task.sleep(for: .seconds(2)) },
        onOutput: (String) -> Void = { _ in }
    ) async throws -> AppStoreScreenshotAsset {
        let attempts = max(2, min(60, options.timeoutSeconds ?? 30) / 2)
        var consecutive = 0
        var lastError: Error = AppStoreScreenshotValidationError(issues: [L10n.text("No screenshot content became ready.")])
        for _ in 0..<attempts {
            try Task.checkCancellation()
            try await pause()
            let asset = try await capture()
            do {
                try AppStoreScreenshotValidator.validate(asset, readyText: options.readyText)
                consecutive += 1
                if consecutive >= 2 { return asset }
            } catch {
                consecutive = 0
                lastError = error
                onOutput(error.localizedDescription + "\n")
            }
        }
        throw lastError
    }
}
