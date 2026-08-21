import Foundation

/// A distribution certificate that exists on the Apple account but has no matching
/// private key on this Mac, described well enough for the user to act on it.
struct UnusableDistributionCertificate: Equatable, Sendable {
    let id: String
    let displayName: String
    let expirationDate: Date?
    /// Uppercase SHA-1 of the certificate, when Apple returned its content. A team's
    /// renewals routinely share a display name and even an expiry date; the
    /// fingerprint is what tells two of them apart in Keychain Access.
    let sha1Fingerprint: String?

    init(
        id: String,
        displayName: String,
        expirationDate: Date?,
        sha1Fingerprint: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.expirationDate = expirationDate
        self.sha1Fingerprint = sha1Fingerprint
    }

    /// Names the certificate precisely enough to act on. Listing several
    /// indistinguishable "Apple Distribution: Example Ltd." lines is worse than
    /// useless: revoking the wrong one costs another slot. Everything included here is
    /// public certificate metadata — an Apple resource identifier and a certificate
    /// digest — never key material.
    var descriptionText: String {
        var details: [String] = []
        if let expirationDate {
            details.append(L10n.format(
                "expires %@",
                DateFormatter.localizedString(
                    from: expirationDate,
                    dateStyle: .medium,
                    timeStyle: .none
                )
            ))
        }
        if !id.isEmpty {
            details.append(L10n.format("ID %@", id))
        }
        if let shortFingerprint = Self.shortFingerprint(sha1Fingerprint) {
            details.append(L10n.format("SHA-1 %@", shortFingerprint))
        }
        guard !details.isEmpty else { return displayName }
        return L10n.format("%@ (%@)", displayName, details.joined(separator: ", "))
    }

    /// The leading bytes of the SHA-1, grouped in pairs the way Keychain Access and the
    /// Developer portal show them. Long enough to disambiguate a team's certificates,
    /// short enough to read out loud.
    static func shortFingerprint(_ fingerprint: String?) -> String? {
        guard let fingerprint else { return nil }
        let digits = Array(fingerprint.uppercased().filter(\.isHexDigit).prefix(16))
        guard digits.count >= 8 else { return nil }
        return stride(from: 0, to: digits.count, by: 2)
            .map { String(digits[$0..<min($0 + 2, digits.count)]) }
            .joined(separator: ":")
    }
}

enum DistributionCertificateProvisioningError: LocalizedError {
    case invalidCertificate
    case teamMismatch(expected: String, actual: String)
    case importedIdentityUnavailable(String)
    case certificateAccessDenied
    case certificateSlotsExhausted([UnusableDistributionCertificate])
    case privateKeyModulusUnavailable
    case certificateParserUnavailable(String)
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
        case .certificateParserUnavailable(let reason):
            return L10n.format(
                "This Mac could not read a distribution certificate that Development Management generated locally (%@), so no certificate was requested from Apple and no certificate slot was used. No archive was uploaded.",
                reason
            )
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
    private let provenanceStore: IssuedSigningCertificateProvenanceStore
    private let urlSession: URLSession

    init(
        processRunner: any ProcessRunning = ProcessRunner(),
        fileManager: FileManager = .default,
        developerTeamService: DeveloperTeamService = DeveloperTeamService(),
        signingKeychainService: SigningKeychainService = .shared,
        pendingStore: PendingSigningCertificateStore = PendingSigningCertificateStore(),
        provenanceStore: IssuedSigningCertificateProvenanceStore =
            IssuedSigningCertificateProvenanceStore(),
        urlSession: URLSession = .shared
    ) {
        self.processRunner = processRunner
        self.fileManager = fileManager
        self.developerTeamService = developerTeamService
        self.signingKeychainService = signingKeychainService
        self.pendingStore = pendingStore
        self.provenanceStore = provenanceStore
        self.urlSession = urlSession
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
            privateKeyPEM: privateKeyPEM,
            session: urlSession
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
                // The install is confirmed, so the pending key may go — but only once
                // ownership is durably recorded somewhere that outlives it.
                releasePendingKeyAfterConfirmedInstall(
                    request: request,
                    certificate: certificate,
                    onOutput: onOutput
                )
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
                    certificate: certificate,
                    request: request,
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

        // Run before anything exists on the Apple account. If this Mac's certificate
        // parser cannot read a certificate, that fact is worth an early failure, not a
        // consumed certificate slot holding a certificate nothing here can install.
        try await verifyCertificateParsing(privateKeyURL: privateKeyURL, in: temporaryDirectory)

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

        // Written here, before the details fetch and the import, for the same reason:
        // this is the first instant at which a certificate exists on the account, and
        // the record is what proves later that this one is ours.
        recordProvenance(
            .issued,
            certificateID: issuedCertificate.id,
            request: request,
            onOutput: onOutput
        )

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
            releasePendingKeyAfterConfirmedInstall(
                request: request,
                certificate: certificate,
                onOutput: onOutput
            )
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
                    certificate: certificate,
                    request: request,
                    appStoreConnect: appStoreConnect,
                    onOutput: onOutput
                )
            }
            throw error
        }
    }

    // MARK: - Certificate parser preflight

    /// Subject of the throwaway certificate the preflight parses. Deliberately not an
    /// Apple distribution subject: it is never installed anywhere, and it must not be
    /// mistakable for a real signing certificate if it ever outlives its temporary
    /// directory.
    static let parserPreflightCommonName = "Development Management Certificate Parser Preflight"
    static let parserPreflightOrganizationalUnit = "DEVMANAGEMENTPREFLIGHT"
    static let parserPreflightOrganizationName = "Development Management"

    static var parserPreflightSubject: String {
        "/CN=\(parserPreflightCommonName)/OU=\(parserPreflightOrganizationalUnit)"
            + "/O=\(parserPreflightOrganizationName)"
    }

    /// Proves, before Apple is asked to create anything, that this Mac can parse a real
    /// DER certificate issued from the key that was just generated.
    ///
    /// The failure this catches is otherwise unrecoverable in the worst way: Apple
    /// issues a genuine certificate, `signingCertificateRecord` returns nil, the
    /// attempt reports `invalidCertificate`, and a slot is spent on a certificate
    /// nothing on this Mac could ever install. Using the real key and the real parser
    /// is the point — a checked-in fixture would not exercise the same Security
    /// framework path on this machine.
    private func verifyCertificateParsing(privateKeyURL: URL, in directory: URL) async throws {
        let derURL = directory.appendingPathComponent("parser-preflight-certificate.der")
        defer { try? fileManager.removeItem(at: derURL) }

        do {
            _ = try await processRunner.runAndRequireSuccess(
                executable: Self.openssl,
                arguments: [
                    "req",
                    "-new",
                    "-x509",
                    "-key", privateKeyURL.path,
                    "-sha256",
                    "-days", "1",
                    "-subj", Self.parserPreflightSubject,
                    "-outform", "DER",
                    "-out", derURL.path
                ]
            )
        } catch {
            throw DistributionCertificateProvisioningError.certificateParserUnavailable(
                error.localizedDescription
            )
        }

        let certificateData: Data
        do {
            certificateData = try Data(contentsOf: derURL)
        } catch {
            throw DistributionCertificateProvisioningError.certificateParserUnavailable(
                error.localizedDescription
            )
        }
        if let reason = Self.parserPreflightFailureReason(certificateData: certificateData) {
            throw DistributionCertificateProvisioningError.certificateParserUnavailable(reason)
        }
    }

    /// Reads a DER certificate through the exact parser `installCertificate` depends on
    /// and reports what it got wrong. Nil means the parser can be trusted with whatever
    /// Apple returns.
    static func parserPreflightFailureReason(certificateData: Data) -> String? {
        guard !certificateData.isEmpty else {
            return L10n.text("the locally generated test certificate was empty")
        }
        guard let record = DeveloperTeamService.signingCertificateRecord(
            certificateData: certificateData
        ) else {
            return L10n.text("a locally generated certificate could not be read at all")
        }
        guard record.commonName == parserPreflightCommonName else {
            return L10n.format(
                "the certificate's common name was read as %@",
                record.commonName
            )
        }
        guard record.organizationalUnit == parserPreflightOrganizationalUnit else {
            return L10n.format("the certificate's team was read as %@", record.organizationalUnit)
        }
        return nil
    }

    // MARK: - Provenance

    /// Records what is now known about a certificate Apple issued for this Mac.
    ///
    /// Returns whether the record is durable. A failure is never fatal — the
    /// certificate exists either way — but it does mean the pending private key has to
    /// stay, because that key then becomes the only remaining proof of ownership.
    @discardableResult
    private func recordProvenance(
        _ status: IssuedSigningCertificateRecord.Status,
        certificateID: String,
        request: PendingSigningCertificateRequest,
        onOutput: @escaping @Sendable (String) -> Void
    ) -> Bool {
        do {
            try provenanceStore.recordStatus(
                status,
                certificateID: certificateID,
                publicKeyModulus: request.publicKeyModulus,
                expectedTeamID: request.expectedTeamID
            )
            return true
        } catch {
            onOutput(L10n.format(
                "The ownership record for Apple Distribution certificate %@ could not be saved (%@).\n",
                certificateID,
                error.localizedDescription
            ))
            return false
        }
    }

    /// Drops the pending private key now that the identity is confirmed installed —
    /// unless the ownership record could not be written, in which case the key is the
    /// last thing that can identify this certificate as ours and is kept instead.
    private func releasePendingKeyAfterConfirmedInstall(
        request: PendingSigningCertificateRequest,
        certificate: AppStoreConnectCertificate,
        onOutput: @escaping @Sendable (String) -> Void
    ) {
        guard recordProvenance(
            .installed,
            certificateID: certificate.id,
            request: request,
            onOutput: onOutput
        ) else {
            onOutput(L10n.format(
                "The Apple Distribution certificate %@ is installed, but its ownership record could not be saved, so its private key was kept on this Mac instead of being deleted.\n",
                certificate.displayName ?? certificate.id
            ))
            return
        }
        pendingStore.remove(id: request.id)
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
    ///
    /// The pending private key is deleted on exactly one path: after Apple confirms the
    /// revocation. Every other outcome leaves a live certificate on the account, and a
    /// live certificate whose key has been deleted is unusable forever — it cannot be
    /// installed, and nothing local can even identify it. Deleting the key when a
    /// keychain cleanup or inspection merely failed is what once stranded one.
    private func rollBack(
        certificate: AppStoreConnectCertificate,
        request: PendingSigningCertificateRequest,
        appStoreConnect: AppStoreConnectService,
        onOutput: @escaping @Sendable (String) -> Void
    ) async {
        let certificateName = certificate.displayName ?? certificate.id
        var localMaterialRemoved = true
        if let sha1Fingerprint = Self.sha1Fingerprint(of: certificate) {
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
                // The keychain could not be inspected or cleaned. That says nothing
                // about the certificate, and it is not a reason to destroy anything.
                localMaterialRemoved = false
            }
        }

        guard localMaterialRemoved else {
            // Revoking now would leave a revoked certificate installed locally, which
            // is the one state that blocks every future publish. The certificate stays
            // active instead, and its private key stays on disk, so the next run can
            // recover it rather than requesting another one.
            //
            // The report names the cost honestly. Its predecessor claimed "No
            // certificate slot was lost" while deleting the very key that made the
            // slot recoverable.
            onOutput(L10n.format(
                "The distribution certificate %@ created for this attempt could not be removed from the Development Management signing keychain, so it was left active on the Apple account rather than revoked. It still occupies a certificate slot, and its private key was kept on this Mac so the next publish can recover it instead of requesting another one.\n",
                certificateName
            ))
            return
        }

        do {
            try await appStoreConnect.revokeCertificate(id: certificate.id)
        } catch {
            // The certificate still exists and its key is still saved, so the next run
            // recovers it rather than requesting another one.
            onOutput(L10n.format(
                "The distribution certificate created for this attempt could not be used and could not be revoked automatically (%@). Its private key was kept so the next publish can reuse that certificate instead of requesting another one.\n",
                error.localizedDescription
            ))
            return
        }

        // Only now is the key provably worthless: Apple confirmed the certificate is
        // gone, so it holds no slot and can never be installed again. The revocation
        // is recorded first so it stays auditable after the key disappears.
        recordProvenance(
            .revoked,
            certificateID: certificate.id,
            request: request,
            onOutput: onOutput
        )
        pendingStore.remove(id: request.id)
        onOutput(L10n.text(
            "The distribution certificate created for this attempt could not be used, so its local key was removed and the certificate was revoked again, releasing its certificate slot.\n"
        ))
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
             // Raised before Apple is contacted at all, so there is nothing to revoke.
             .certificateParserUnavailable,
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
                    expirationDate: $0.expirationDate,
                    sha1Fingerprint: Self.sha1Fingerprint(of: $0)
                )
            }
            // Renewals routinely share a display name, so the identifier breaks the tie
            // and the listed order stays stable from one run to the next.
            .sorted { ($0.displayName, $0.id) < ($1.displayName, $1.id) }
    }

    static func certificatePEM(_ certificateData: Data) -> String {
        let encoded = certificateData.base64EncodedString(options: [.lineLength64Characters])
        return "-----BEGIN CERTIFICATE-----\n\(encoded)\n-----END CERTIFICATE-----\n"
    }
}
