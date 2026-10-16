import Foundation

/// Explicit macOS exceptions, never applied to iOS. Unknown capabilities still require
/// a profile; do not exclude all com.apple.security.* or com.apple.developer.* keys.
/// https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles
enum MacProvisioningEntitlements {
    static let unrestricted: Set<String> = Set([
        "app-sandbox", "inherit", "application-groups",
        "network.client", "network.server",
        "files.user-selected.read-only", "files.user-selected.read-write",
        "files.user-selected.executable", "files.downloads.read-only", "files.downloads.read-write",
        "files.bookmarks.app-scope", "files.bookmarks.document-scope",
        "assets.pictures.read-only", "assets.pictures.read-write",
        "assets.music.read-only", "assets.music.read-write",
        "assets.movies.read-only", "assets.movies.read-write",
        "device.camera", "device.microphone", "device.audio-input", "device.usb",
        "device.bluetooth", "device.serial", "device.firewire", "print",
        "personal-information.addressbook", "personal-information.calendars",
        "personal-information.location", "automation.apple-events",
        "cs.allow-jit", "cs.allow-unsigned-executable-memory",
        "cs.allow-dyld-environment-variables", "cs.disable-library-validation",
        "cs.disable-executable-page-protection", "cs.debugger"
    ].map { "com.apple.security." + $0 })
}
