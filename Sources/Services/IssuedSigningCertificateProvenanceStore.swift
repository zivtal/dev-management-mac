import CryptoKit
import Foundation

/// Durable proof that Development Management, rather than the developer or another
/// tool, asked Apple to issue a particular distribution certificate.
///
/// The pending private key is the only other evidence of ownership, and it is deleted
/// as soon as the certificate is installed. After that nothing on this Mac can say
/// which of the team's certificates Development Management created — which is exactly
/// the state that makes an orphaned certificate impossible to reason about later.
/// This record outlives the key, so ownership stays provable and a confirmed
/// revocation stays auditable.
struct IssuedSigningCertificateRecord: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        /// Apple confirmed the certificate exists. Nothing local uses it yet.
        case issued
        /// The identity was confirmed present in the signing keychain.
        case installed
        /// Apple confirmed the revocation. The certificate no longer holds a slot.
        case revoked
    }

    let certificateID: String
    /// Uppercase hexadecimal RSA modulus of the key the certificate was issued from.
    /// Only a certificate signed from that exact key can match it, so this is what
    /// lets later code prove ownership without keeping the private key around.
    let publicKeyModulus: String
    let expectedTeamID: String?
    let issuedAt: Date
    var status: Status
    var statusChangedAt: Date
}

/// Owner-only storage for issued-certificate provenance.
///
/// Holds no secret: a public-key modulus, an Apple certificate identifier, a team
/// identifier, and timestamps. It is still written 0600 inside a 0700 directory,
/// because knowing which certificate belongs to which Mac is nobody else's business.
/// `@unchecked` only because `FileManager` is not `Sendable`: every stored property
/// here is immutable, and the file operations used are thread-safe.
struct IssuedSigningCertificateProvenanceStore: @unchecked Sendable {
    static let directoryName = "IssuedSigningCertificates"

    private let directory: URL
    private let fileManager: FileManager

    init(fileManager: FileManager = .default, directoryOverride: URL? = nil) {
        self.fileManager = fileManager
        if let directoryOverride {
            directory = directoryOverride
        } else {
            let applicationSupport = fileManager
                .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Support")
            directory = applicationSupport
                .appendingPathComponent("DevManagement", isDirectory: true)
                .appendingPathComponent(Self.directoryName, isDirectory: true)
        }
    }

    var directoryURL: URL { directory }

    /// One file per certificate. Apple's identifiers are opaque, so the name is
    /// sanitised and disambiguated with a digest rather than trusted as a path
    /// component.
    func recordURL(certificateID: String) -> URL {
        directory.appendingPathComponent("\(Self.fileName(certificateID: certificateID)).json")
    }

    static func fileName(certificateID: String) -> String {
        let safe = certificateID.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "_"
                ? character
                : "_"
        }
        let digest = SHA256.hash(data: Data(certificateID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(16)
        return "\(String(safe).prefix(64))-\(digest)"
    }

    /// Writes `status` for a certificate, preserving the original issuance time when a
    /// record already exists.
    ///
    /// Deliberately an upsert. Requiring a prior record would mean that a failed write
    /// at issuance time also silently discards the later confirmed revocation, which is
    /// the one fact most worth keeping.
    @discardableResult
    func recordStatus(
        _ status: IssuedSigningCertificateRecord.Status,
        certificateID: String,
        publicKeyModulus: String,
        expectedTeamID: String?,
        at date: Date = Date()
    ) throws -> IssuedSigningCertificateRecord {
        let existing = record(certificateID: certificateID)
        let record = IssuedSigningCertificateRecord(
            certificateID: certificateID,
            publicKeyModulus: existing?.publicKeyModulus ?? publicKeyModulus,
            expectedTeamID: existing?.expectedTeamID ?? expectedTeamID,
            issuedAt: existing?.issuedAt ?? date,
            status: status,
            statusChangedAt: date
        )
        try createDirectory()
        try write(try Self.encoder.encode(record), to: recordURL(certificateID: certificateID))
        return record
    }

    func record(certificateID: String) -> IssuedSigningCertificateRecord? {
        guard let data = try? Data(contentsOf: recordURL(certificateID: certificateID)) else {
            return nil
        }
        return try? Self.decoder.decode(IssuedSigningCertificateRecord.self, from: data)
    }

    /// The certificate Development Management issued from this key, if any. Matching on
    /// the modulus is what makes ownership provable: no other key can produce it.
    func record(matchingPublicKeyModulus modulus: String) -> IssuedSigningCertificateRecord? {
        let normalized = modulus.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalized.isEmpty else { return nil }
        return records().first {
            $0.publicKeyModulus.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                == normalized
        }
    }

    /// Whether Development Management issued this certificate. A certificate that is
    /// absent here was created by something else and must never be revoked
    /// automatically.
    func wasIssuedByDevelopmentManagement(certificateID: String) -> Bool {
        record(certificateID: certificateID) != nil
    }

    /// Every record, oldest issuance first.
    func records() -> [IssuedSigningCertificateRecord] {
        let contents = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? Self.decoder.decode(IssuedSigningCertificateRecord.self, from: data)
            }
            .sorted { $0.issuedAt < $1.issuedAt }
    }

    private func createDirectory() throws {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // createDirectory ignores the attribute when an intermediate already exists.
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
