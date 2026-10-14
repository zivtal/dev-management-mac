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

    /// Used only by explicit recovery, after a verified backup of the database.
    static func removeBackedUpKeychain(_ url: URL) throws {
        try perform {
            var keychain: SecKeychain?
            let opened = SecKeychainOpen(url.path, &keychain)
            guard opened == errSecSuccess, let keychain else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(opened))
            }
            let status = SecKeychainDelete(keychain)
            guard status == errSecSuccess else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            }
        }
    }
}
