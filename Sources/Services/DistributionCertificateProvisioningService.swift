import Foundation

/// A distribution certificate that exists on the Apple account but has no matching
/// private key on this Mac, described well enough for the user to act on it.
struct UnusableDistributionCertificate: Equatable, Sendable {
    let id: String
    let displayName: String
    let expirationDate: Date?

    var descriptionText: String {
        guard let expirationDate else { return displayName }
        return L10n.format(
            "%@ (expires %@)",
            displayName,
            DateFormatter.localizedString(
                from: expirationDate,
                dateStyle: .medium,
                timeStyle: .none
            )
        )
    }
}

enum DistributionCertificateProvisioningError: LocalizedError {
    case invalidCertificate
    case teamMismatch(expected: String, actual: String)
    case importedIdentityUnavailable(String)
    case certificateAccessDenied
    case certificateSlotsExhausted([UnusableDistributionCertificate])
    case privateKeyModulusUnavailable
    case recoveredCertificateUnusable(String)

    var errorDescription: String? {
        switch self {
        // These describe only the failure. Whether the certificate slot was actually
        // released is reported separately by the rollback, which is best-effort and
        // must not be pre-announced here.
        case .invalidCertificate:
            return L10n.text("Apple created a distribution certificate, but its certificate data could not be verified or installed. No archive was uploaded.")
        case .teamMismatch(let expected, let actual):
            return L10n.format(
                "The App Store Connect API key belongs to Apple team %@, but this app is configured for team %@. Select matching credentials or change the app's signing team. No archive was uploaded.",
                actual,
                expected
            )
        case .importedIdentityUnavailable(let teamID):
            return L10n.format(
                "The Apple Distribution certificate was imported, but its private key is not usable for signing team %@. No archive was uploaded.",
                teamID
            )
        case .certificateAccessDenied:
            return L10n.text("The App Store Connect API key cannot manage Apple Distribution certificates. Use an Account Holder or Admin key with Certificates, Identifiers & Profiles access. No archive was uploaded.")
        case .certificateSlotsExhausted(let certificates):
            let list = certificates.isEmpty
                ? L10n.text("none reported by Apple")
                : certificates.map(\.descriptionText).joined(separator: ", ")
            return L10n.format(
                "Apple will not issue another Apple Distribution certificate because this team already has the maximum number, and none of them has a private key on this Mac: %@. Revoke one in the Apple Developer portal under Certificates, or import its .p12 with the private key, then publish again. Development Management never revokes a certificate it did not just create. No archive was uploaded.",
                list
            )
        case .privateKeyModulusUnavailable:
            return L10n.text("The generated signing key could not be fingerprinted, so a certificate was not requested from Apple. No archive was uploaded.")
        case .recoveredCertificateUnusable(let reason):
            return L10n.format(
                "An Apple Distribution certificate left over from an interrupted attempt could not be installed (%@). No archive was uploaded.",
                reason
            )
        }
    }
}

actor DistributionCertificateProvisioningService {
    static let shared = DistributionCertificateProvisioningService()

    private let processRunner: any ProcessRunning
    private let fileManager: FileManager
    private let developerTeamService: DeveloperTeamService
    private let signingKeychainService: SigningKeychainService
    private let pendingStore: PendingSigningCertificateStore

    init(
        processRunner: any ProcessRunning = ProcessRunner(),
        fileManager: FileManager = .default,
        developerTeamService: DeveloperTeamService = DeveloperTeamService(),
        signingKeychainService: SigningKeychainService = .shared,
        pendingStore: PendingSigningCertificateStore = PendingSigningCertificateStore()
    ) {
        self.processRunner = processRunner
        self.fileManager = fileManager
        self.developerTeamService = developerTeamService
        self.signingKeychainService = signingKeychainService
        self.pendingStore = pendingStore
    }

    /// Produces a local Apple Distribution identity for `teamID`, reusing an existing
    /// one when possible and creating one only as a last resort.
    ///
    /// Unlike the previous cloud-signing fallback this never returns "not available":
    /// manual export needs a real local identity, so failure is an error the caller
    /// must surface before spending time on an archive.
    func prepareLocalIdentity(
        teamID: String?,
        issuerID: String,
        keyID: String,
        privateKeyPEM: String,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> DistributionSigningIdentity {
        // Before the identity is looked for, not only before an import: a keychain
        // relocks across restarts, and a locked one makes `codesign` raise an
        // authorization prompt this accessory app can never answer. Nothing is created
        // here — only an existing keychain is reopened.
        //
        // A failure is held rather than thrown: a developer whose Apple Distribution
        // identity lives in their login keychain does not need this one at all, and
        // must not be blocked by it. It is rethrown below only if the identity that
        // would be reused actually lives in the keychain that would not open, and by
        // `importIdentity` if a new certificate has to be stored there.
        var keychainFailure: Error?
        do {
            try await signingKeychainService.prepareKeychain(
                createIfMissing: false,
                onOutput: onOutput
            )
        } catch {
            keychainFailure = error
        }

        let normalizedTeamID = teamID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let appStoreConnect = try AppStoreConnectService(
            issuerID: issuerID,
            keyID: keyID,
            privateKeyPEM: privateKeyPEM
        )
        let certificates: [AppStoreConnectCertificate]
        do {
            certificates = try await appStoreConnect.certificates()
        } catch AppStoreConnectError.requestFailed(let status, _) where status == 401 || status == 403 {
            throw DistributionCertificateProvisioningError.certificateAccessDenied
        }

        // Checked against every certificate, not only distribution ones: a key issued
        // for the wrong team is worth catching even when that team has no
        // distribution certificate yet.
        if let expectedTeamID = normalizedTeamID,
           let actualTeamID = Self.mismatchedTeamID(
               certificates,
               expectedTeamID: expectedTeamID
           ) {
            throw DistributionCertificateProvisioningError.teamMismatch(
                expected: expectedTeamID,
                actual: actualTeamID
            )
        }

        // A local identity is only worth reusing while Apple still recognises it.
        // Reusing a revoked one would burn a whole archive before the export failed,
        // and would never let the create path run again.
        let localIdentities = developerTeamService.distributionSigningIdentities(teamID: teamID)
        if let existing = localIdentities.first(where: { identity in
            Self.accountCertificate(
                in: certificates,
                sha1Fingerprint: identity.sha1Fingerprint
            ) != nil
        }) {
            if let keychainFailure {
                let livesInDedicatedKeychain: Bool
                do {
                    livesInDedicatedKeychain = try await signingKeychainService.containsIdentity(
                        sha1Fingerprint: existing.sha1Fingerprint
                    )
                } catch {
                    // If the dedicated keychain cannot even be inspected, proceeding
                    // could make codesign raise an authorization dialog. Stop instead.
                    throw keychainFailure
                }
                if livesInDedicatedKeychain {
                    // The one identity worth reusing is inside the keychain that
                    // would not open, so the export could never use it.
                    throw keychainFailure
                }
            }
            onOutput(L10n.format(
                "Using the local Apple Distribution identity %@.\n",
                existing.commonName
            ))
            return existing
        }
        if let newestLocalIdentity = localIdentities.first {
            onOutput(L10n.format(
                "The local Apple Distribution identity %@ is no longer on the App Store Connect account, so a replacement will be prepared.\n",
                newestLocalIdentity.commonName
            ))
        }

        if let recovered = try await recoverPendingCertificate(
            certificates: Self.activeDistributionCertificates(certificates),
            normalizedTeamID: normalizedTeamID,
            appStoreConnect: appStoreConnect,
            onOutput: onOutput
        ) {
            return recovered
        }

        onOutput(L10n.text(
            "No local Apple Distribution identity was found; preparing one before archiving…\n"
        ))
        return try await createIdentity(
            appStoreConnect: appStoreConnect,
            existingDistributionCertificates: Self.activeDistributionCertificates(certificates),
            normalizedTeamID: normalizedTeamID,
            onOutput: onOutput
        )
    }

    // MARK: - Crash recovery

    /// Installs a certificate Apple issued during an attempt that died before the
    /// keychain import, so a crash can never strand the only copy of a private key
    /// while its certificate keeps occupying a slot on the account.
    private func recoverPendingCertificate(
        certificates: [AppStoreConnectCertificate],
        normalizedTeamID: String?,
        appStoreConnect: AppStoreConnectService,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> DistributionSigningIdentity? {
        let pending = pendingStore.pendingRequests()
        guard !pending.isEmpty else { return nil }

        for request in pending {
            guard let certificate = try await matchingCertificate(
                for: request,
                in: certificates
            ) else {
                continue
            }
            onOutput(L10n.format(
                "Recovering the Apple Distribution certificate %@ that an interrupted attempt had already created.\n",
                certificate.displayName ?? certificate.id
            ))
            let privateKeyPEM: String
            do {
                privateKeyPEM = try pendingStore.privateKeyPEM(id: request.id)
            } catch {
                // A permissions or transient filesystem problem must not destroy the
                // only recoverable copy of a key for a certificate Apple already
                // issued. Preserve both files and surface the precise failure.
                throw error
            }
            do {
                let installed = try await installCertificate(
                    certificate,
                    privateKeyPEM: privateKeyPEM,
                    normalizedTeamID: normalizedTeamID ?? request.expectedTeamID,
                    onOutput: onOutput
                )
                pendingStore.remove(id: request.id)
                onOutput(L10n.format(
                    "Recovered and installed the Apple Distribution signing identity for team %@.\n",
                    installed.teamID
                ))
                return installed
            } catch {
                if !Self.shouldRollBackCertificate(for: error) {
                    // Nothing is wrong with the certificate, so it keeps its slot and
                    // its key stays saved for the next attempt.
                    throw error
                }
                // The certificate itself cannot be used. It was provably created by
                // Development Management, so releasing its slot is safe.
                await rollBack(
                    certificateID: certificate.id,
                    sha1Fingerprint: Self.sha1Fingerprint(of: certificate),
                    requestID: request.id,
                    appStoreConnect: appStoreConnect,
                    onOutput: onOutput
                )
                throw DistributionCertificateProvisioningError.recoveredCertificateUnusable(
                    error.localizedDescription
                )
            }
        }
        return nil
    }

    /// The account certificate issued from a pending request's private key, matched
    /// on RSA modulus. Only a certificate signed from that exact key can match, which
    /// is what makes recovery incapable of touching a pre-existing certificate.
    private func matchingCertificate(
        for request: PendingSigningCertificateRequest,
        in certificates: [AppStoreConnectCertificate]
    ) async throws -> AppStoreConnectCertificate? {
        for certificate in certificates {
            guard let data = certificate.certificateContent else { continue }
            guard let modulus = try? await certificateModulus(data) else { continue }
            if modulus == request.publicKeyModulus { return certificate }
        }
        return nil
    }

    // MARK: - Creation

    private func createIdentity(
        appStoreConnect: AppStoreConnectService,
        existingDistributionCertificates: [AppStoreConnectCertificate],
        normalizedTeamID: String?,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> DistributionSigningIdentity {
        let temporaryDirectory = try makeTemporaryDirectory(
            name: "DevManagement-Distribution-Certificate"
        )
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let privateKeyURL = temporaryDirectory.appendingPathComponent("distribution-private-key.pem")
        let csrURL = temporaryDirectory.appendingPathComponent("distribution.certSigningRequest")
        _ = try await processRunner.runAndRequireSuccess(
            executable: Self.openssl,
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
        let privateKeyPEM = try String(contentsOf: privateKeyURL, encoding: .utf8)
        guard let modulus = try? await privateKeyModulus(privateKeyURL) else {
            throw DistributionCertificateProvisioningError.privateKeyModulusUnavailable
        }

        // Persisted *before* Apple is asked to issue anything. From here on, a crash
        // at any point still leaves the key on disk and recoverable next launch.
        var request = PendingSigningCertificateRequest(
            id: UUID().uuidString,
            createdAt: Date(),
            expectedTeamID: normalizedTeamID,
            publicKeyModulus: modulus,
            certificateID: nil
        )
        try pendingStore.save(request, privateKeyPEM: privateKeyPEM)

        let issuedCertificate: AppStoreConnectCertificate
        do {
            issuedCertificate = try await appStoreConnect.createDistributionCertificate(
                csrContent: csrContent
            )
        } catch AppStoreConnectError.requestFailed(let status, _) where status == 401 || status == 403 {
            pendingStore.remove(id: request.id)
            throw DistributionCertificateProvisioningError.certificateAccessDenied
        } catch AppStoreConnectError.requestFailed(let status, _)
            where status == 409 || status == 422 {
            pendingStore.remove(id: request.id)
            throw DistributionCertificateProvisioningError.certificateSlotsExhausted(
                Self.unusableCertificates(existingDistributionCertificates)
            )
        } catch {
            // A transport failure may still have created a certificate, so the key
            // stays saved and the next run recovers it instead of burning a slot.
            throw error
        }

        // From this line onward Apple has definitely issued a certificate. Record its
        // ID before any follow-up request so no later authorization or network failure
        // can make us discard the only private key for it.
        request.certificateID = issuedCertificate.id
        try? pendingStore.update(request)

        let certificate: AppStoreConnectCertificate
        if issuedCertificate.certificateContent == nil {
            certificate = try await appStoreConnect.certificate(id: issuedCertificate.id)
        } else {
            certificate = issuedCertificate
        }

        do {
            let identity = try await installCertificate(
                certificate,
                privateKeyPEM: privateKeyPEM,
                normalizedTeamID: normalizedTeamID,
                onOutput: onOutput
            )
            pendingStore.remove(id: request.id)
            onOutput(L10n.format(
                "Created and installed an Apple Distribution signing identity for team %@.\n",
                identity.teamID
            ))
            return identity
        } catch {
            // Keychain, filesystem, or helper-tool failures do not prove the Apple
            // certificate is bad. Keep its pending private key so the next publish can
            // recover it. Only malformed or wrong-team certificates are revoked.
            if Self.shouldRollBackCertificate(for: error) {
                await rollBack(
                    certificateID: certificate.id,
                    sha1Fingerprint: Self.sha1Fingerprint(of: certificate),
                    requestID: request.id,
                    appStoreConnect: appStoreConnect,
                    onOutput: onOutput
                )
            }
            throw error
        }
    }

    /// Builds a PKCS#12 from a certificate and its private key and imports it into the
    /// dedicated signing keychain. Neither password ever reaches a command line or
    /// touches the disk.
    private func installCertificate(
        _ certificate: AppStoreConnectCertificate,
        privateKeyPEM: String,
        normalizedTeamID: String?,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> DistributionSigningIdentity {
        guard let certificateData = certificate.certificateContent,
              let certificateRecord = DeveloperTeamService.signingCertificateRecord(
                certificateData: certificateData
              ),
              let fingerprint = certificateRecord.sha1Fingerprint
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

        let temporaryDirectory = try makeTemporaryDirectory(name: "DevManagement-Signing-Identity")
        defer { try? fileManager.removeItem(at: temporaryDirectory) }
        let certificateURL = temporaryDirectory.appendingPathComponent("distribution-certificate.pem")
        let keyURL = temporaryDirectory.appendingPathComponent("distribution-private-key.pem")
        let identityURL = temporaryDirectory.appendingPathComponent("distribution-identity.p12")
        let password = UUID().uuidString + UUID().uuidString

        try Self.certificatePEM(certificateData).write(
            to: certificateURL,
            atomically: true,
            encoding: .utf8
        )
        try Data(privateKeyPEM.utf8).write(to: keyURL, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)

        // `-passout stdin` keeps the export password out of both argv and the disk.
        _ = try await processRunner.runAndRequireSuccess(
            executable: Self.openssl,
            arguments: [
                "pkcs12",
                "-export",
                "-inkey", keyURL.path,
                "-in", certificateURL.path,
                "-out", identityURL.path,
                "-name", certificate.displayName ?? "Apple Distribution",
                "-passout", "stdin"
            ],
            standardInput: Data(password.utf8)
        )
        try await signingKeychainService.importIdentity(
            pkcs12URL: identityURL,
            pkcs12Password: password,
            expectedSHA1Fingerprint: fingerprint,
            onOutput: onOutput
        )

        let verifiedTeamID = normalizedTeamID?.nilIfEmpty ?? certificateRecord.organizationalUnit
        // The identity is built from the certificate that was just imported and
        // verified inside the keychain, rather than from a keychain search that this
        // process may not see yet. Treating a stale search list as a failure used to
        // revoke a perfectly good certificate.
        if developerTeamService.distributionSigningIdentity(teamID: verifiedTeamID) == nil {
            onOutput(L10n.format(
                "The Apple Distribution identity for team %@ is installed but not visible to this process yet; the export will still use it explicitly.\n",
                verifiedTeamID
            ))
        }
        return DistributionSigningIdentity(
            teamID: verifiedTeamID,
            commonName: certificateRecord.commonName,
            sha1Fingerprint: fingerprint
        )
    }

    // MARK: - Rollback

    /// Undoes a certificate this attempt created: local key material first, then the
    /// certificate itself. Never runs for a certificate Development Management did not
    /// create, and never deletes a pre-existing identity — only the exact fingerprint
    /// of the certificate at hand, and only from Development Management's own keychain.
    private func rollBack(
        certificateID: String,
        sha1Fingerprint: String?,
        requestID: String,
        appStoreConnect: AppStoreConnectService,
        onOutput: @escaping @Sendable (String) -> Void
    ) async {
        var localMaterialRemoved = true
        if let sha1Fingerprint {
            do {
                if try await signingKeychainService.containsIdentity(
                    sha1Fingerprint: sha1Fingerprint
                ) {
                    try await signingKeychainService.removeIdentity(
                        sha1Fingerprint: sha1Fingerprint
                    )
                    localMaterialRemoved = try await !signingKeychainService.containsIdentity(
                        sha1Fingerprint: sha1Fingerprint
                    )
                }
            } catch {
                localMaterialRemoved = false
            }
        }

        guard localMaterialRemoved else {
            // Revoking now would leave a revoked certificate installed locally, which
            // is the one state that blocks every future publish. The certificate stays
            // active instead, so the next run can simply reuse it.
            pendingStore.remove(id: requestID)
            onOutput(L10n.text(
                "The distribution certificate created for this attempt could not be removed from the Development Management signing keychain, so it was left active on the Apple account rather than revoked. No certificate slot was lost.\n"
            ))
            return
        }

        do {
            try await appStoreConnect.revokeCertificate(id: certificateID)
            pendingStore.remove(id: requestID)
            onOutput(L10n.text(
                "The distribution certificate created for this attempt could not be used, so its local key was removed and the certificate was revoked again, releasing its certificate slot.\n"
            ))
        } catch {
            // The certificate still exists and its key is still saved, so the next run
            // recovers it rather than requesting another one.
            onOutput(L10n.format(
                "The distribution certificate created for this attempt could not be used and could not be revoked automatically (%@). Its private key was kept so the next publish can reuse that certificate instead of requesting another one.\n",
                error.localizedDescription
            ))
        }
    }

    // MARK: - OpenSSL helpers

    private static let openssl = URL(fileURLWithPath: "/usr/bin/openssl")

    private func privateKeyModulus(_ url: URL) async throws -> String {
        let result = try await processRunner.runAndRequireSuccess(
            executable: Self.openssl,
            arguments: ["rsa", "-in", url.path, "-noout", "-modulus"]
        )
        guard let modulus = Self.parseModulus(result.output) else {
            throw DistributionCertificateProvisioningError.privateKeyModulusUnavailable
        }
        return modulus
    }

    private func certificateModulus(_ certificateData: Data) async throws -> String {
        let result = try await processRunner.runAndRequireSuccess(
            executable: Self.openssl,
            arguments: ["x509", "-noout", "-modulus"],
            standardInput: Data(Self.certificatePEM(certificateData).utf8)
        )
        guard let modulus = Self.parseModulus(result.output) else {
            throw DistributionCertificateProvisioningError.privateKeyModulusUnavailable
        }
        return modulus
    }

    /// `openssl … -modulus` prints `Modulus=<uppercase hex>`.
    static func parseModulus(_ output: String) -> String? {
        for line in output.split(whereSeparator: \Character.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("Modulus=") else { continue }
            let value = String(trimmed.dropFirst("Modulus=".count)).uppercased()
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private func makeTemporaryDirectory(name: String) throws -> URL {
        let url = fileManager.temporaryDirectory.appendingPathComponent(
            "\(name)-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return url
    }

    // MARK: - Certificate selection

    /// Revocation is safe only when the returned certificate itself is proven unusable.
    /// Helper-tool, keychain, filesystem, and transport failures leave the private key
    /// pending for recovery instead of consuming another certificate slot.
    static func shouldRollBackCertificate(for error: Error) -> Bool {
        guard let error = error as? DistributionCertificateProvisioningError else {
            return false
        }
        switch error {
        case .invalidCertificate, .teamMismatch:
            return true
        case .importedIdentityUnavailable,
             .certificateAccessDenied,
             .certificateSlotsExhausted,
             .privateKeyModulusUnavailable,
             .recoveredCertificateUnusable:
            return false
        }
    }

    static func sha1Fingerprint(of certificate: AppStoreConnectCertificate) -> String? {
        certificate.certificateContent
            .map { DeveloperTeamService.sha1Fingerprint(ofCertificateData: $0) }
    }

    static func accountCertificate(
        in certificates: [AppStoreConnectCertificate],
        sha1Fingerprint fingerprint: String,
        now: Date = Date()
    ) -> AppStoreConnectCertificate? {
        certificates.first {
            iOSDistributionCertificateTypes.contains($0.certificateType.uppercased())
                && $0.isActive(at: now)
                && Self.sha1Fingerprint(of: $0) == fingerprint
        }
    }

    /// Only the types that occupy an iOS distribution slot. A substring match would
    /// also catch `MAC_APP_DISTRIBUTION` and `MAC_INSTALLER_DISTRIBUTION`, which would
    /// send the user off to revoke a certificate that frees nothing.
    static let iOSDistributionCertificateTypes: Set<String> = [
        "DISTRIBUTION",
        "IOS_DISTRIBUTION"
    ]

    static func activeDistributionCertificates(
        _ certificates: [AppStoreConnectCertificate],
        now: Date = Date()
    ) -> [AppStoreConnectCertificate] {
        certificates.filter {
            iOSDistributionCertificateTypes.contains($0.certificateType.uppercased())
                && $0.isActive(at: now)
        }
    }

    /// The Apple team IDs the account's certificates belong to, read from each
    /// certificate's organizational unit.
    static func certificateTeamIDs(
        _ certificates: [AppStoreConnectCertificate]
    ) -> [String] {
        certificates.compactMap { certificate in
            certificate.certificateContent
                .flatMap(DeveloperTeamService.signingCertificateRecord(certificateData:))?
                .organizationalUnit
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    static func mismatchedTeamID(
        _ certificates: [AppStoreConnectCertificate],
        expectedTeamID: String?
    ) -> String? {
        mismatchedTeamID(
            teamIDs: certificateTeamIDs(certificates),
            expectedTeamID: expectedTeamID
        )
    }

    /// Deterministic: the reported team is the lowest sorted one, so it never depends
    /// on collection ordering the way the previous `Set.first` did.
    static func mismatchedTeamID(
        teamIDs: [String],
        expectedTeamID: String?
    ) -> String? {
        guard let expectedTeamID, !expectedTeamID.isEmpty else { return nil }
        let knownTeamIDs = teamIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !knownTeamIDs.isEmpty, !knownTeamIDs.contains(expectedTeamID) else { return nil }
        return knownTeamIDs.sorted().first
    }

    static func unusableCertificates(
        _ certificates: [AppStoreConnectCertificate]
    ) -> [UnusableDistributionCertificate] {
        certificates
            .map {
                UnusableDistributionCertificate(
                    id: $0.id,
                    displayName: $0.displayName ?? $0.id,
                    expirationDate: $0.expirationDate
                )
            }
            .sorted { $0.displayName < $1.displayName }
    }

    static func certificatePEM(_ certificateData: Data) -> String {
        let encoded = certificateData.base64EncodedString(options: [.lineLength64Characters])
        return "-----BEGIN CERTIFICATE-----\n\(encoded)\n-----END CERTIFICATE-----\n"
    }
}
