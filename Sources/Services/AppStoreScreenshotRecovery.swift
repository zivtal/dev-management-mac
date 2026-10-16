import Foundation

/// Generated cache files are disposable; invalid user-supplied assets remain blocking errors.
enum AppStoreScreenshotRecovery {
    static func validatedAssets(_ assets: [AppStoreScreenshotAsset], cacheDirectory: URL,
        options: [String: AppStoreScreenshotCaptureOptions], primaryLocale: String,
        onOutput: (String) -> Void = { _ in }
    ) throws -> [AppStoreScreenshotAsset] {
        var valid: [AppStoreScreenshotAsset] = []
        for asset in assets {
            do {
                try AppStoreScreenshotValidator.validate(asset, readyText: options[asset.platform.rawValue]?.readyText)
                valid.append(asset)
            } catch {
                guard asset.url.deletingLastPathComponent().standardizedFileURL == cacheDirectory.standardizedFileURL else {
                    throw error
                }
                try FileManager.default.removeItem(at: asset.url)
                onOutput(L10n.format("Regenerating invalid cached screenshot: %@\n", error.localizedDescription))
            }
        }
        try AppStoreScreenshotValidator.validateSet(valid, primaryLocale: primaryLocale)
        return valid
    }
}

/// Watch appconduit can cancel installation during boot. Retry this specific race, never erase data.
enum ScreenshotSimulatorInstallation {
    static func run(install: () async throws -> Void,
        pause: () async throws -> Void = { try await Task.sleep(for: .seconds(3)) },
        onOutput: (String) -> Void = { _ in }
    ) async throws {
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do { try await install(); return }
            catch {
                guard attempt < 2,
                      case ProcessRunnerError.commandFailed(_, _, let output) = error,
                      output.contains("IXErrorDomain"), output.contains("Uninstall requested") else { throw error }
                onOutput(L10n.text("Simulator installation was interrupted by appconduit; retrying without removing app data.\n"))
                try await pause()
            }
        }
    }
}
