import Foundation

enum DistributionCertificateProvisioningError: LocalizedError {
    case invalidCertificate
    case teamMismatch(expected: String, actual: String)
    case importedIdentityUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidCertificate:
            return L10n.text("Apple created a distribution certificate, but its certificate data could not be verified or installed. No archive was created.")
        case .teamMismatch(let expected, let actual):
            return L10n.format(
                "The App Store Connect API key belongs to Apple team %@, but this app is configured for team %@. Select matching credentials or change the app's signing team. No archive was created.",
                actual,
                expected
            )
        case .importedIdentityUnavailable(let teamID):
            return L10n.format(
                "The Apple Distribution certificate was imported, but Xcode cannot find its private key for team %@ in Keychain. No archive was created.",
                teamID
            )
        }
    }
}

actor DistributionCertificateProvisioningService {
    static let shared = DistributionCertificateProvisioningService()

    private let processRunner: ProcessRunner
    private let fileManager: FileManager
    private let developerTeamService: DeveloperTeamService

    init(
        processRunner: ProcessRunner = ProcessRunner(),
        fileManager: FileManager = .default,
        developerTeamService: DeveloperTeamService = DeveloperTeamService()
    ) {
        self.processRunner = processRunner
        self.fileManager = fileManager
        self.developerTeamService = developerTeamService
    }

    @discardableResult
    func prepareLocalIdentity(
        teamID: String?,
        issuerID: String,
        keyID: String,
        privateKeyPEM: String,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> Bool {
        if developerTeamService.hasDistributionSigningIdentity(teamID: teamID) {
            onOutput(L10n.text("Found a local Apple Distribution signing identity.\n"))
            return true
        }

        let normalizedTeamID = teamID?.trimmingCharacters(in: .whitespacesAndNewlines)
        onOutput(L10n.text(
            "No local Apple Distribution identity was found; preparing one before archiving…\n"
        ))
        let appStoreConnect = try AppStoreConnectService(
            issuerID: issuerID,
            keyID: keyID,
            privateKeyPEM: privateKeyPEM
        )
        let certificates: [AppStoreConnectCertificate]
        do {
            certificates = try await appStoreConnect.certificates()
        } catch AppStoreConnectError.requestFailed(let status, _) where status == 401 || status == 403 {
            onOutput(L10n.text(
                "The API key cannot manage local distribution certificates; Xcode cloud signing will be attempted.\n"
            ))
            return false
        }

        let knownTeamIDs = Set(certificates.compactMap { certificate in
            certificate.certificateContent.flatMap {
                DeveloperTeamService.signingCertificateRecord(certificateData: $0)
            }?
                .organizationalUnit
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })
        if let normalizedTeamID,
           !normalizedTeamID.isEmpty,
           let actualTeamID = knownTeamIDs.first,
           !knownTeamIDs.contains(normalizedTeamID) {
            throw DistributionCertificateProvisioningError.teamMismatch(
                expected: normalizedTeamID,
                actual: actualTeamID
            )
        }

        let temporaryDirectory = fileManager.temporaryDirectory.appendingPathComponent(
            "DevManagement-Distribution-Certificate-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let privateKeyURL = temporaryDirectory.appendingPathComponent("distribution-private-key.pem")
        let csrURL = temporaryDirectory.appendingPathComponent("distribution.certSigningRequest")
        _ = try await processRunner.runAndRequireSuccess(
            executable: URL(fileURLWithPath: "/usr/bin/openssl"),
            arguments: [
                "req",
                "-new",
                "-newkey", "rsa:2048",
                "-nodes",
                "-sha256",
                "-subj", "/CN=Development Management Apple Distribution",
                "-keyout", privateKeyURL.path,
                "-out", csrURL.path
            ]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: privateKeyURL.path
        )
        let csrContent = try String(contentsOf: csrURL, encoding: .utf8)

        let certificate: AppStoreConnectCertificate
        do {
            certificate = try await appStoreConnect.createDistributionCertificate(
                csrContent: csrContent
            )
        } catch AppStoreConnectError.requestFailed(let status, _) where status == 401 || status == 403 {
            onOutput(L10n.text(
                "The API key can read certificates but cannot create an Apple Distribution certificate; Xcode cloud signing will be attempted.\n"
            ))
            return false
        } catch AppStoreConnectError.requestFailed(let status, let message)
            where status == 409 || status == 422 {
            onOutput(L10n.format(
                "Apple did not allow another local distribution certificate (%@); Xcode cloud signing will be attempted.\n",
                message
            ))
            return false
        }

        guard let certificateData = certificate.certificateContent,
              let certificateRecord = DeveloperTeamService.signingCertificateRecord(
                certificateData: certificateData
              )
        else {
            throw DistributionCertificateProvisioningError.invalidCertificate
        }
        if let normalizedTeamID,
           !normalizedTeamID.isEmpty,
           certificateRecord.organizationalUnit != normalizedTeamID {
            throw DistributionCertificateProvisioningError.teamMismatch(
                expected: normalizedTeamID,
                actual: certificateRecord.organizationalUnit
            )
        }

        let certificateURL = temporaryDirectory.appendingPathComponent("distribution-certificate.pem")
        let passwordURL = temporaryDirectory.appendingPathComponent("pkcs12-password.txt")
        let identityURL = temporaryDirectory.appendingPathComponent("distribution-identity.p12")
        let password = UUID().uuidString + UUID().uuidString
        try Self.certificatePEM(certificateData).write(
            to: certificateURL,
            atomically: true,
            encoding: .utf8
        )
        try Data(password.utf8).write(to: passwordURL, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: passwordURL.path
        )
        _ = try await processRunner.runAndRequireSuccess(
            executable: URL(fileURLWithPath: "/usr/bin/openssl"),
            arguments: [
                "pkcs12",
                "-export",
                "-inkey", privateKeyURL.path,
                "-in", certificateURL.path,
                "-out", identityURL.path,
                "-name", certificate.displayName ?? "Apple Distribution",
                "-passout", "file:\(passwordURL.path)"
            ]
        )
        _ = try await processRunner.runAndRequireSuccess(
            executable: URL(fileURLWithPath: "/usr/bin/security"),
            arguments: [
                "import", identityURL.path,
                "-f", "pkcs12",
                "-P", password,
                "-T", "/usr/bin/codesign",
                "-T", "/usr/bin/xcodebuild"
            ]
        )

        let verifiedTeamID: String
        if let normalizedTeamID, !normalizedTeamID.isEmpty {
            verifiedTeamID = normalizedTeamID
        } else {
            verifiedTeamID = certificateRecord.organizationalUnit
        }
        guard developerTeamService.hasDistributionSigningIdentity(teamID: verifiedTeamID) else {
            throw DistributionCertificateProvisioningError.importedIdentityUnavailable(
                verifiedTeamID
            )
        }
        onOutput(L10n.format(
            "Created and installed an Apple Distribution signing identity for team %@.\n",
            verifiedTeamID
        ))
        return true
    }

    static func certificatePEM(_ certificateData: Data) -> String {
        let encoded = certificateData.base64EncodedString(options: [.lineLength64Characters])
        return "-----BEGIN CERTIFICATE-----\n\(encoded)\n-----END CERTIFICATE-----\n"
    }
}
