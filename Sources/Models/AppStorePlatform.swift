import Foundation

enum AppStorePlatform: String, Codable, CaseIterable, Sendable {
    case iOS = "IOS"
    case macOS = "MAC_OS"

    var destination: String { self == .macOS ? "generic/platform=macOS" : "generic/platform=iOS" }
    var artifactExtension: String { self == .macOS ? "pkg" : "ipa" }
    var profileType: String { self == .macOS ? "MAC_APP_STORE" : "IOS_APP_STORE" }
    var title: String { self == .macOS ? "macOS" : "iOS, iPadOS, watchOS" }
}

extension ManagedProject {
    var supportsAppStorePublishing: Bool {
        effectiveApplicationPlatform == .iOS || effectiveApplicationPlatform == .macOS
    }
    var appStorePlatform: AppStorePlatform { isMacOSApplication ? .macOS : .iOS }
}
