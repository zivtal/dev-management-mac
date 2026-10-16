import AppKit
import ScreenCaptureKit

/// Captures only the selected app's window, never the user's desktop or other apps.
@MainActor
final class MacStoreScreenshotService {
    static func preview(project: ManagedProject, existing: [AppStoreScreenshotAsset], outputDirectory: URL, options: AppStoreScreenshotCaptureOptions = .init()) async throws -> AppStoreScreenshotPreview {
        let existing = existing.filter { $0.platform == .mac }
        if !existing.isEmpty { return result(existing, error: nil) }
        do {
            let asset = try await capture(project: project, outputDirectory: outputDirectory, options: options)
            return result([asset], error: nil)
        } catch {
            return result([], error: error.localizedDescription)
        }
    }

    private static func result(_ assets: [AppStoreScreenshotAsset], error: String?) -> AppStoreScreenshotPreview {
        AppStoreScreenshotPreview(devices: [AppStoreScreenshotCaptureDevice(
            platform: .mac, name: Host.current().localizedName ?? "Mac", runtime: ProcessInfo.processInfo.operatingSystemVersionString,
            state: error.map { .failed($0) } ?? .captured
        )], screenshots: assets)
    }

    private static func capture(project: ManagedProject, outputDirectory: URL, options: AppStoreScreenshotCaptureOptions) async throws -> AppStoreScreenshotAsset {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw failure("Allow Screen Recording for Development Management, then retry screenshots.")
        }
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DevManagement/MacScreenshots/\(project.id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await XcodeGenProjectPreparationService().prepare(project: project, onOutput: { _ in })
        let prepared = try XcodeSchemeBuildPreparationService().prepare(project: project)
        defer { prepared.removeTemporaryFile(fileManager: .default) }
        let container = project.containerURL.pathExtension == "xcworkspace" ? "-workspace" : "-project"
        let previewProject = try await AppStoreReleaseCoordinator.screenshotProject(project)
        let configuration = previewProject.configuration
        let buildRoot = root.appendingPathComponent("Build")
        _ = try await ProcessRunner().runAndRequireSuccess(executable: URL(fileURLWithPath: "/usr/bin/xcodebuild"),
            arguments: [container, project.containerPath, "-scheme", prepared.name,
                        "-configuration", configuration, "-destination", "platform=macOS",
                        "-derivedDataPath", buildRoot.path, "build"], workingDirectory: project.folderURL)
        let products = buildRoot.appendingPathComponent("Build/Products/\(configuration)")
        let apps = try FileManager.default.contentsOfDirectory(at: products, includingPropertiesForKeys: nil)
        guard let url = apps.first(where: {
            guard $0.pathExtension == "app", let bundle = Bundle(url: $0) else { return false }
            return bundle.bundleIdentifier == previewProject.bundleIdentifier
        }) else { throw failure("The Mac screenshot build did not contain the selected app.") }
        let launch = NSWorkspace.OpenConfiguration()
        launch.arguments = options.launchArguments
        launch.activates = true
        launch.createsNewApplicationInstance = true
        let app = try await NSWorkspace.shared.openApplication(at: url, configuration: launch)
        defer { app.terminate() }
        try await Task.sleep(for: .seconds(2))
        var content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        var windows = content.windows.filter { $0.owningApplication?.processID == app.processIdentifier && $0.frame.width > 100 && $0.frame.height > 100 }
        if windows.isEmpty {
            try openMenuBarPanel(pid: app.processIdentifier)
            try await Task.sleep(for: .seconds(2))
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            windows = content.windows.filter { $0.owningApplication?.processID == app.processIdentifier && $0.frame.width > 100 && $0.frame.height > 100 }
        }
        guard let window = windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
            throw failure("Open the app’s main window or menu-bar panel, then retry screenshots.")
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * 2)
        config.height = Int(window.frame.height * 2)
        config.showsCursor = false
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let output = outputDirectory.appendingPathComponent("mac-window.png")
        return try await AppStoreScreenshotCapture.waitForContent(options: options) {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let metrics = try AppStoreScreenshotValidator.metrics(image)
            guard !metrics.isNearUniform else {
                throw AppStoreScreenshotValidationError(issues: [L10n.text("The Mac app window is blank. Prepare a demo content screen before capture.")])
            }
            try canvas(image).write(to: output, options: .atomic)
            return AppStoreScreenshotAsset(url: output, displayType: "APP_DESKTOP", platform: .mac,
                                           automaticallyCaptured: true)
        }
    }

    private static func openMenuBarPanel(pid: pid_t) throws {
        guard AXIsProcessTrusted() else {
            throw failure("Allow Accessibility for Development Management to open this app’s menu-bar panel, or open the panel yourself and retry.")
        }
        let app = AXUIElementCreateApplication(pid)
        var menu: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXExtrasMenuBarAttribute as CFString, &menu) == .success,
              let menu else { return }
        var children: CFTypeRef?
        AXUIElementCopyAttributeValue(menu as! AXUIElement, kAXChildrenAttribute as CFString, &children)
        if let first = (children as? [AXUIElement])?.first { AXUIElementPerformAction(first, kAXPressAction as CFString) }
    }

    /// Fit the real window on an opaque 16:10 canvas accepted by the Mac App Store.
    static func canvas(_ image: CGImage) throws -> Data {
        // AppKit cannot create a drawing context for a packed 24-bit RGB bitmap on all systems.
        // Use a supported 32-bit opaque context; the PNG still has no alpha channel.
        guard let context = CGContext(data: nil, width: 2560, height: 1600,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw failure("Could not render the Mac screenshot.") }
        context.setFillColor(CGColor(gray: 0.12, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2560, height: 1600))
        let scale = min(2400 / CGFloat(image.width), 1440 / CGFloat(image.height), 1)
        let size = NSSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        context.draw(image, in: CGRect(x: (2560-size.width)/2, y: (1600-size.height)/2, width: size.width, height: size.height))
        guard let rendered = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: rendered).representation(using: .png, properties: [:]) else { throw failure("Could not save the Mac screenshot.") }
        return data
    }

    private static func failure(_ message: String) -> Error { AppStoreConnectError.requestFailed(0, L10n.text(message)) }
}

extension AppStorePublishingService {
    func prepareMacScreenshotPreview(project: ManagedProject, configuredPaths: [String]) async throws -> AppStoreScreenshotPreview {
        let candidates = localScreenshotAssets(project: project, configuredPaths: configuredPaths).filter { $0.platform == .mac }
        let options = try AppStorePublishingManifest.load(from: project.folderURL)?
            .publication(for: project.appStorePlatform)?.screenshotCapture?["mac"] ?? .init()
        let assets = try AppStoreScreenshotRecovery.validatedAssets(candidates,
            cacheDirectory: screenshotCacheDirectory(for: project), options: ["mac": options], primaryLocale: "en-US")
        for asset in assets { try AppStoreScreenshotValidator.validate(asset, readyText: options.readyText) }
        let preview = try await MacStoreScreenshotService.preview(project: project, existing: assets,
            outputDirectory: screenshotCacheDirectory(for: project), options: options)
        try AppStoreScreenshotValidator.validateSet(preview.screenshots)
        return preview
    }
}
