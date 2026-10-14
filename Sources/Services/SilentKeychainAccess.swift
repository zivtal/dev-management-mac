import Foundation
import Security

/// Legacy keychain APIs otherwise display a SecurityAgent password dialog even for
/// some status queries. Keep this operation synchronous and restore the prior state.
enum SilentKeychainAccess {
    private static let lock = NSRecursiveLock()

    static func perform<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        var allowed = DarwinBoolean(true)
        SecKeychainGetUserInteractionAllowed(&allowed)
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(allowed.boolValue) }
        return try operation()
    }

    static func isUnlocked(_ url: URL) -> Bool {
        perform {
            var keychain: SecKeychain?
            guard SecKeychainOpen(url.path, &keychain) == errSecSuccess, let keychain else { return false }
            var status = SecKeychainStatus()
            guard SecKeychainGetStatus(keychain, &status) == errSecSuccess else { return false }
            return status & SecKeychainStatus(kSecUnlockStateStatus) != 0
        }
    }
}
