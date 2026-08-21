import Foundation

/// A certificate request whose private key was persisted before Apple was asked to
/// issue anything, so that a crash between the request and the keychain import cannot
/// strand the only copy of the key.
struct PendingSigningCertificateRequest: Codable, Equatable, Sendable {
    let id: String
    let createdAt: Date
    let expectedTeamID: String?
    /// Uppercase hexadecimal RSA modulus of the persisted private key. Recovery pairs
    /// a key with a certificate on the account by comparing this, which is the only
    /// evidence that Development Management created that certificate.
    let publicKeyModulus: String
    /// Recorded best-effort once Apple answers. Recovery never depends on it.
    var certificateID: String?
}

enum PendingSigningCertificateStoreError: LocalizedError {
    case privateKeyUnreadable(String)

    var errorDescription: String? {
        switch self {
        case .privateKeyUnreadable(let id):
            return L10n.format(
                "The saved private key for pending certificate request %@ could not be read.",
                id
            )
        }
    }
}

/// Durable storage for in-flight certificate requests.
///
/// Everything is written with owner-only permissions, and only the private key is
/// ever persisted — never a PKCS#12 or keychain password.
/// `@unchecked` only because `FileManager` is not `Sendable`: every stored property
/// here is immutable, and the file operations used are thread-safe.
struct PendingSigningCertificateStore: @unchecked Sendable {
    static let directoryName = "PendingSigningCertificates"

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

    func metadataURL(id: String) -> URL {
        directory.appendingPathComponent("\(id).json")
    }

    func privateKeyURL(id: String) -> URL {
        directory.appendingPathComponent("\(id).key.pem")
    }

    /// Persists the private key and its metadata. Must complete before the
    /// certificate is requested from Apple.
    func save(
        _ request: PendingSigningCertificateRequest,
        privateKeyPEM: String
    ) throws {
        try createDirectory()
        // Key first: metadata without a key is recoverable (it is discarded), but a
        // certificate whose key was never written is not.
        try write(Data(privateKeyPEM.utf8), to: privateKeyURL(id: request.id))
        try write(try Self.encoder.encode(request), to: metadataURL(id: request.id))
    }

    func update(_ request: PendingSigningCertificateRequest) throws {
        try createDirectory()
        try write(try Self.encoder.encode(request), to: metadataURL(id: request.id))
    }

    /// Every pending request, oldest first, skipping any whose key is missing.
    func pendingRequests() -> [PendingSigningCertificateRequest] {
        let contents = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> PendingSigningCertificateRequest? in
                guard let data = try? Data(contentsOf: url),
                      let request = try? Self.decoder.decode(
                        PendingSigningCertificateRequest.self,
                        from: data
                      ),
                      fileManager.fileExists(atPath: privateKeyURL(id: request.id).path)
                else {
                    return nil
                }
                return request
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func privateKeyPEM(id: String) throws -> String {
        guard let contents = try? String(
            contentsOf: privateKeyURL(id: id),
            encoding: .utf8
        ) else {
            throw PendingSigningCertificateStoreError.privateKeyUnreadable(id)
        }
        return contents
    }

    /// Drops a request only once its certificate is installed or a rollback has
    /// definitively released the corresponding Apple certificate. Pending private
    /// keys must never be aged out: after an interrupted network request, one may be
    /// the only recoverable key for a certificate that still occupies an Apple slot.
    func remove(id: String) {
        try? fileManager.removeItem(at: privateKeyURL(id: id))
        try? fileManager.removeItem(at: metadataURL(id: id))
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
