import Foundation

/// Checks the archived iOS application's interface orientations before the package is
/// validated or uploaded. App Store Connect rejects a bundle that declares no
/// `UISupportedInterfaceOrientations` (ITMS-90474) and an iPad-capable bundle that
/// does not support all four orientations unless it opts out of multitasking with
/// `UIRequiresFullScreen` (ITMS-90475). Apple reports both only after altool has
/// contacted its servers, and the publishing flow has already written App Store
/// metadata by then.
enum AppStoreArchiveOrientationCheck {
    enum Failure: Equatable, Sendable {
        case noOrientations(bundleIdentifier: String)
        case incompleteIPadOrientations(bundleIdentifier: String, missing: [String])
    }

    static let requiredIPadOrientations = [
        "UIInterfaceOrientationPortrait",
        "UIInterfaceOrientationPortraitUpsideDown",
        "UIInterfaceOrientationLandscapeLeft",
        "UIInterfaceOrientationLandscapeRight"
    ]

    private static let iPadDeviceFamily = 2

    /// Returns the first orientation problem in the archive's application, or nil when
    /// the declaration is acceptable or the archive cannot be read. Unreadable archives
    /// are reported by the metadata and upload steps with their own errors.
    static func failure(
        at archiveURL: URL,
        platform: AppStorePlatform,
        fileManager: FileManager = .default
    ) -> Failure? {
        guard platform == .iOS, let info = applicationInfo(at: archiveURL, fileManager: fileManager) else {
            return nil
        }
        return failure(info: info)
    }

    static func failure(info: [String: Any]) -> Failure? {
        let bundleIdentifier = info["CFBundleIdentifier"] as? String ?? ""
        let general = orientations(info["UISupportedInterfaceOrientations"])
        let iPad = orientations(info["UISupportedInterfaceOrientations~ipad"])
        if general.isEmpty, iPad.isEmpty {
            return .noOrientations(bundleIdentifier: bundleIdentifier)
        }
        guard supportsIPad(info), !requiresFullScreen(info) else { return nil }
        let effective = iPad.isEmpty ? general : iPad
        let missing = requiredIPadOrientations.filter { !effective.contains($0) }
        return missing.isEmpty
            ? nil
            : .incompleteIPadOrientations(bundleIdentifier: bundleIdentifier, missing: missing)
    }

    private static func applicationInfo(at archiveURL: URL, fileManager: FileManager) -> [String: Any]? {
        let applicationsURL = archiveURL
            .appendingPathComponent("Products", isDirectory: true)
            .appendingPathComponent("Applications", isDirectory: true)
        let applications = (try? fileManager.contentsOfDirectory(
            at: applicationsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for application in applications where application.pathExtension.lowercased() == "app" {
            guard let data = try? Data(contentsOf: AppStorePublishingService.bundleInfoURL(application)),
                  let values = try? PropertyListSerialization.propertyList(
                    from: data, options: [], format: nil
                  ) as? [String: Any]
            else { continue }
            return values
        }
        return nil
    }

    private static func orientations(_ value: Any?) -> Set<String> {
        if let list = value as? [String] { return Set(list) }
        if let single = value as? String { return Set(single.split(separator: " ").map(String.init)) }
        return []
    }

    private static func supportsIPad(_ info: [String: Any]) -> Bool {
        let families: [Int]
        if let list = info["UIDeviceFamily"] as? [Int] {
            families = list
        } else if let single = info["UIDeviceFamily"] as? Int {
            families = [single]
        } else {
            families = []
        }
        return families.contains(iPadDeviceFamily)
    }

    private static func requiresFullScreen(_ info: [String: Any]) -> Bool {
        if let flag = info["UIRequiresFullScreen"] as? Bool { return flag }
        if let number = info["UIRequiresFullScreen"] as? NSNumber { return number.boolValue }
        return false
    }
}
