import CommonCrypto
import CryptoKit
import Foundation

/// Every Keychain secret that belongs to a settings backup.
struct SettingsArchiveCredentials: Codable, Equatable {
    var openAIAPIKey: String?
    var appStoreConnectPrivateKey: String?
    /// Keyed by the credential profile UUID string.
    var appStoreConnectProfilePrivateKeys: [String: String] = [:]
    var appReviewDemoAccountName: String?
    var appReviewDemoAccountPassword: String?
    var appStorePrivacyFastlaneSession: String?
}

/// The complete, portable configuration of Development Management: preferences,
/// managed applications with their per-application settings, installation history,
/// publishing settings, and the credentials that back them.
struct SettingsArchive: Codable, Equatable {
    var exportedAt: Date
    var appVersion: String?
    var preferences: AppPreferences
    var projects: [ManagedProject]
    var installationRecords: [InstallationRecord]
    var credentials: SettingsArchiveCredentials
}

enum SettingsTransferError: LocalizedError, Equatable {
    case unrecognizedFile
    case unsupportedVersion(Int)
    case passwordRequired
    case incorrectPassword
    case corruptedFile

    var errorDescription: String? {
        switch self {
        case .unrecognizedFile:
            L10n.text("The selected file is not a Development Management settings export.")
        case .unsupportedVersion(let version):
            L10n.format(
                "This settings file was created by a newer version of Development Management (format %d). Update the app before importing it.",
                version
            )
        case .passwordRequired:
            L10n.text("This settings file is encrypted. Enter its password to import it.")
        case .incorrectPassword:
            L10n.text("The password does not match this settings file.")
        case .corruptedFile:
            L10n.text("The settings file is damaged and could not be read.")
        }
    }
}

/// Encodes and decodes settings backups. A backup is a JSON envelope that either
/// embeds the archive directly or an AES-GCM ciphertext whose key is derived from a
/// password with PBKDF2-HMAC-SHA256.
enum SettingsTransferService {
    static let formatIdentifier = "com.zivtal.DevManagement.settings"
    static let formatVersion = 1
    static let keyDerivationIterations = 600_000

    private struct Probe: Decodable {
        let format: String?
        let formatVersion: Int?
    }

    private struct PlaintextEnvelope: Codable {
        var format = SettingsTransferService.formatIdentifier
        var formatVersion = SettingsTransferService.formatVersion
        var payload: SettingsArchive
    }

    private struct EncryptionParameters: Codable {
        var algorithm = "AES-256-GCM"
        var keyDerivation = "PBKDF2-HMAC-SHA256"
        var iterations: Int
        var salt: Data
    }

    private struct EncryptedEnvelope: Codable {
        var format = SettingsTransferService.formatIdentifier
        var formatVersion = SettingsTransferService.formatVersion
        var encryption: EncryptionParameters
        var ciphertext: Data
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// A blank password produces a plaintext export.
    static func encode(_ archive: SettingsArchive, password: String?) throws -> Data {
        guard let password = normalizedPassword(password) else {
            return try encoder.encode(PlaintextEnvelope(payload: archive))
        }
        let payload = try encoder.encode(archive)
        var salt = Data(count: 16)
        let status = salt.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw SettingsTransferError.corruptedFile
        }
        let key = try deriveKey(password: password, salt: salt, iterations: keyDerivationIterations)
        let sealed = try AES.GCM.seal(payload, using: key)
        guard let combined = sealed.combined else { throw SettingsTransferError.corruptedFile }
        return try encoder.encode(EncryptedEnvelope(
            encryption: EncryptionParameters(iterations: keyDerivationIterations, salt: salt),
            ciphertext: combined
        ))
    }

    static func isEncrypted(_ data: Data) -> Bool {
        (try? decoder.decode(EncryptedEnvelope.self, from: data)) != nil
    }

    static func decode(_ data: Data, password: String?) throws -> SettingsArchive {
        guard let probe = try? decoder.decode(Probe.self, from: data),
              probe.format == formatIdentifier,
              let version = probe.formatVersion
        else {
            throw SettingsTransferError.unrecognizedFile
        }
        guard version <= formatVersion else {
            throw SettingsTransferError.unsupportedVersion(version)
        }

        if let encrypted = try? decoder.decode(EncryptedEnvelope.self, from: data) {
            guard let password = normalizedPassword(password) else {
                throw SettingsTransferError.passwordRequired
            }
            let key = try deriveKey(
                password: password,
                salt: encrypted.encryption.salt,
                iterations: encrypted.encryption.iterations
            )
            let payload: Data
            do {
                let box = try AES.GCM.SealedBox(combined: encrypted.ciphertext)
                payload = try AES.GCM.open(box, using: key)
            } catch {
                throw SettingsTransferError.incorrectPassword
            }
            do {
                return try decoder.decode(SettingsArchive.self, from: payload)
            } catch {
                throw SettingsTransferError.corruptedFile
            }
        }

        do {
            return try decoder.decode(PlaintextEnvelope.self, from: data).payload
        } catch {
            throw SettingsTransferError.corruptedFile
        }
    }

    static func defaultExportFilename(date: Date = Date(), timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return "Development Management Settings \(formatter.string(from: date)).json"
    }

    private static func normalizedPassword(_ password: String?) -> String? {
        guard let password, !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return password
    }

    private static func deriveKey(password: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        guard iterations > 0 else { throw SettingsTransferError.corruptedFile }
        let passwordBytes = Array(password.utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltBuffer in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                password,
                passwordBytes.count,
                saltBuffer.bindMemory(to: UInt8.self).baseAddress,
                salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                UInt32(iterations),
                &derived,
                derived.count
            )
        }
        guard status == kCCSuccess else { throw SettingsTransferError.corruptedFile }
        return SymmetricKey(data: derived)
    }
}

enum SettingsImportError: LocalizedError {
    case busy

    var errorDescription: String? {
        switch self {
        case .busy:
            L10n.text("Wait for the current installation or publication to finish before importing settings.")
        }
    }
}
