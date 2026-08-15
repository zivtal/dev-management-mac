import Foundation
import Security

enum PublishingCredential: String {
    case openAIAPIKey = "openai-api-key"
    case appStoreConnectPrivateKey = "app-store-connect-private-key"
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

    init(service: String = "com.zivtal.DevManagement.Publishing") {
        self.service = service
    }

    func contains(_ credential: PublishingCredential) -> Bool {
        (try? data(for: credential)) != nil
    }

    func string(for credential: PublishingCredential) throws -> String? {
        guard let data = try data(for: credential) else { return nil }
        guard let value = String(data: data, encoding: .utf8) else {
            throw KeychainCredentialError.invalidText
        }
        return value
    }

    func set(_ value: String, for credential: PublishingCredential) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            throw KeychainCredentialError.invalidText
        }
        try set(data, for: credential)
    }

    func remove(_ credential: PublishingCredential) throws {
        let status = SecItemDelete(baseQuery(for: credential) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainCredentialError.unexpectedStatus(status)
        }
    }

    private func data(for credential: PublishingCredential) throws -> Data? {
        var query = baseQuery(for: credential)
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
        let query = baseQuery(for: credential)
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

    private func baseQuery(for credential: PublishingCredential) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credential.rawValue
        ]
    }
}
