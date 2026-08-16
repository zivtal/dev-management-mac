import Foundation
import Security

enum PublishingCredential: String {
    case openAIAPIKey = "openai-api-key"
    case appStoreConnectPrivateKey = "app-store-connect-private-key"
    case appReviewDemoAccountName = "app-review-demo-account-name"
    case appReviewDemoAccountPassword = "app-review-demo-account-password"
}

enum KeychainCredentialError: LocalizedError {
    case unexpectedStatus(OSStatus)
    case invalidText

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "\(status)"
            return L10n.format("Keychain could not save the credential: %@", message)
        case .invalidText:
            return L10n.text("The credential is empty or invalid.")
        }
    }
}

final class KeychainCredentialStore {
    private let service: String
    private var stringCache: [String: String] = [:]

    init(service: String = "com.zivtal.DevManagement.Publishing") {
        self.service = service
    }

    func contains(_ credential: PublishingCredential) -> Bool {
        contains(account: credential.rawValue)
    }

    func string(for credential: PublishingCredential) throws -> String? {
        let account = credential.rawValue
        if let cached = stringCache[account] { return cached }
        guard let data = try data(account: account) else { return nil }
        guard let value = String(data: data, encoding: .utf8) else {
            throw KeychainCredentialError.invalidText
        }
        stringCache[account] = value
        return value
    }

    func set(_ value: String, for credential: PublishingCredential) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            throw KeychainCredentialError.invalidText
        }
        try set(data, for: credential)
        stringCache[credential.rawValue] = trimmed
    }

    func remove(_ credential: PublishingCredential) throws {
        try remove(account: credential.rawValue)
    }

    func containsAppStoreConnectPrivateKey(profileID: UUID?) -> Bool {
        contains(account: Self.appStoreConnectPrivateKeyAccount(profileID: profileID))
    }

    func appStoreConnectPrivateKey(profileID: UUID?) throws -> String? {
        let account = Self.appStoreConnectPrivateKeyAccount(profileID: profileID)
        if let cached = stringCache[account] { return cached }
        guard let data = try data(account: account) else {
            return nil
        }
        guard let value = String(data: data, encoding: .utf8) else {
            throw KeychainCredentialError.invalidText
        }
        stringCache[account] = value
        return value
    }

    func setAppStoreConnectPrivateKey(_ value: String, profileID: UUID?) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            throw KeychainCredentialError.invalidText
        }
        let account = Self.appStoreConnectPrivateKeyAccount(profileID: profileID)
        try set(data, account: account)
        stringCache[account] = trimmed
    }

    func removeAppStoreConnectPrivateKey(profileID: UUID?) throws {
        try remove(account: Self.appStoreConnectPrivateKeyAccount(profileID: profileID))
    }

    static func existenceQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
    }

    private func contains(account: String) -> Bool {
        let query = Self.existenceQuery(service: service, account: account)
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    private func remove(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainCredentialError.unexpectedStatus(status)
        }
        stringCache[account] = nil
    }

    private func data(for credential: PublishingCredential) throws -> Data? {
        try data(account: credential.rawValue)
    }

    private func data(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainCredentialError.unexpectedStatus(status)
        }
        return data
    }

    private func set(_ data: Data, for credential: PublishingCredential) throws {
        try set(data, account: credential.rawValue)
    }

    private func set(_ data: Data, account: String) throws {
        let query = baseQuery(account: account)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainCredentialError.unexpectedStatus(updateStatus)
        }
        var insertion = query
        insertion[kSecValueData as String] = data
        insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(insertion as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainCredentialError.unexpectedStatus(addStatus)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    static func appStoreConnectPrivateKeyAccount(profileID: UUID?) -> String {
        guard let profileID else { return PublishingCredential.appStoreConnectPrivateKey.rawValue }
        return "app-store-connect-private-key-\(profileID.uuidString.lowercased())"
    }
}
