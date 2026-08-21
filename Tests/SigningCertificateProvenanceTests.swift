import CryptoKit
import XCTest
@testable import DevManagement

/// Runs the certificate work for real — genuine keys, genuine DER, genuine parsing —
/// while answering `security` from a script so no test can ever touch a keychain.
///
/// Anything that is neither scripted nor explicitly allowed to run fails with a
/// recognisable status instead of being executed, so a new command reaching the
/// keychain shows up as a failing test rather than as a side effect on the machine.
final class PartiallyScriptedProcessRunner: ProcessRunning, @unchecked Sendable {
    struct Invocation: Equatable {
        let executable: String
        let arguments: [String]
        let standardInput: String?
    }

    static let blockedStatus: Int32 = 99

    private let lock = NSLock()
    private var storage: [Invocation] = []
    private var blocked: [Invocation] = []
    private let executablesAllowedToRun: Set<String>
    private let rule: @Sendable (Invocation) -> CommandResult?
    private let real = ProcessRunner()

    init(
        executablesAllowedToRun: Set<String> = ["/usr/bin/openssl"],
        rule: @escaping @Sendable (Invocation) -> CommandResult?
    ) {
        self.executablesAllowedToRun = executablesAllowedToRun
        self.rule = rule
    }

    var invocations: [Invocation] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    /// Commands that would have reached the real tool. Always expected to be empty:
    /// one of these means a test was about to mutate the developer's machine.
    var blockedInvocations: [Invocation] {
        lock.lock()
        defer { lock.unlock() }
        return blocked
    }

    func run(
        executable: URL,
        arguments: [String],
        workingDirectory: URL?,
        additionalEnvironment: [String: String],
        standardInput: Data?,
        onOutput: ProcessRunner.OutputHandler?,
        terminateWhenOutput: ProcessRunner.OutputTerminationPredicate?
    ) async throws -> CommandResult {
        let invocation = Invocation(
            executable: executable.path,
            arguments: arguments,
            standardInput: standardInput.flatMap { String(data: $0, encoding: .utf8) }
        )
        record(invocation)

        if let scripted = rule(invocation) { return scripted }
        guard executablesAllowedToRun.contains(executable.path) else {
            block(invocation)
            return CommandResult(
                terminationStatus: Self.blockedStatus,
                output: "blocked in tests: \(executable.path)"
            )
        }
        return try await real.run(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            additionalEnvironment: additionalEnvironment,
            standardInput: standardInput,
            onOutput: onOutput,
            terminateWhenOutput: terminateWhenOutput
        )
    }

    /// Synchronous so the lock is never held across a suspension point.
    private func record(_ invocation: Invocation) {
        lock.lock()
        storage.append(invocation)
        lock.unlock()
    }

    private func block(_ invocation: Invocation) {
        lock.lock()
        blocked.append(invocation)
        lock.unlock()
    }
}

/// The publishing log is written from whatever executor the actor is running on, so it
/// is collected under a lock rather than assumed to arrive on one thread.
final class CollectedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = ""

    func append(_ value: String) {
        lock.lock()
        storage += value
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

final class SigningCertificateProvenanceTests: XCTestCase {
    private static let openssl = URL(fileURLWithPath: "/usr/bin/openssl")
    private static let teamID = "TESTTEAM01"

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Certificate parser preflight

    /// The preflight is only worth anything if it exercises the same Security framework
    /// path the install does, on a certificate that really was signed by the key that
    /// is about to be sent to Apple.
    func testParserPreflightAcceptsARealDERCertificateFromTheGeneratedKey() async throws {
        let directory = try scratchDirectory()
        let keyURL = try await Self.makePrivateKey(in: directory, name: "preflight")
        let derURL = try await Self.makeSelfSignedDER(
            key: keyURL,
            subject: DistributionCertificateProvisioningService.parserPreflightSubject,
            at: directory.appendingPathComponent("preflight.der")
        )
        let certificateData = try Data(contentsOf: derURL)

        XCTAssertNil(DistributionCertificateProvisioningService.parserPreflightFailureReason(
            certificateData: certificateData
        ))

        // The exact values the install path later depends on.
        let record = try XCTUnwrap(
            DeveloperTeamService.signingCertificateRecord(certificateData: certificateData)
        )
        XCTAssertEqual(
            record.commonName,
            DistributionCertificateProvisioningService.parserPreflightCommonName
        )
        XCTAssertEqual(
            record.organizationalUnit,
            DistributionCertificateProvisioningService.parserPreflightOrganizationalUnit
        )
        XCTAssertEqual(
            record.sha1Fingerprint,
            DeveloperTeamService.sha1Fingerprint(ofCertificateData: certificateData)
        )
    }

    func testParserPreflightRejectsEmptyGarbageAndWrongSubjectCertificates() async throws {
        let directory = try scratchDirectory()
        let keyURL = try await Self.makePrivateKey(in: directory, name: "wrong")

        XCTAssertNotNil(DistributionCertificateProvisioningService.parserPreflightFailureReason(
            certificateData: Data()
        ))
        XCTAssertNotNil(DistributionCertificateProvisioningService.parserPreflightFailureReason(
            certificateData: Data("not a certificate".utf8)
        ))

        // A real certificate whose subject carries no organizational unit is exactly
        // what `signingCertificateRecord` refuses, and refusing it after Apple has
        // issued one is what costs a certificate slot.
        let withoutTeam = try await Self.makeSelfSignedDER(
            key: keyURL,
            subject: "/CN=\(DistributionCertificateProvisioningService.parserPreflightCommonName)",
            at: directory.appendingPathComponent("no-ou.der")
        )
        XCTAssertNotNil(DistributionCertificateProvisioningService.parserPreflightFailureReason(
            certificateData: try Data(contentsOf: withoutTeam)
        ))

        let wrongTeam = try await Self.makeSelfSignedDER(
            key: keyURL,
            subject: "/CN=\(DistributionCertificateProvisioningService.parserPreflightCommonName)"
                + "/OU=SOMETHINGELSE",
            at: directory.appendingPathComponent("wrong-ou.der")
        )
        let reason = try XCTUnwrap(
            DistributionCertificateProvisioningService.parserPreflightFailureReason(
                certificateData: try Data(contentsOf: wrongTeam)
            )
        )
        XCTAssertTrue(reason.contains("SOMETHINGELSE"), "the reason must name what was read")
    }

    /// The whole point of the preflight is its position: it has to fail before anything
    /// exists on the Apple account, so no slot is consumed and no key is left pending.
    func testAParserFailureStopsBeforeAnyCertificateIsRequestedFromApple() async throws {
        let pendingStore = PendingSigningCertificateStore(directoryOverride: try scratchDirectory())
        let provenanceStore = IssuedSigningCertificateProvenanceStore(
            directoryOverride: try scratchDirectory()
        )
        // Only the self-signed preflight certificate fails; key generation is real.
        let runner = PartiallyScriptedProcessRunner { invocation in
            guard invocation.arguments.contains("-x509") else { return nil }
            return CommandResult(terminationStatus: 1, output: "openssl: cannot self-sign")
        }
        StubURLProtocol.enqueue(.init(
            match: { $0.url?.path == "/v1/certificates" && $0.httpMethod == "GET" },
            statusCode: 200,
            body: ["data": []]
        ))

        do {
            _ = try await makeService(
                runner: runner,
                pendingStore: pendingStore,
                provenanceStore: provenanceStore
            ).prepareLocalIdentity(
                teamID: Self.teamID,
                issuerID: "issuer",
                keyID: "key",
                privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation,
                onOutput: { _ in }
            )
            XCTFail("expected certificateParserUnavailable")
        } catch let error as DistributionCertificateProvisioningError {
            guard case .certificateParserUnavailable = error else {
                return XCTFail("expected certificateParserUnavailable, got \(error)")
            }
            let message = try XCTUnwrap(error.errorDescription)
            XCTAssertTrue(message.contains("No archive was uploaded."))
        }

        XCTAssertFalse(
            StubURLProtocol.requests.contains {
                $0.httpMethod == "POST" && $0.url?.path == "/v1/certificates"
            },
            "a certificate must never be requested from Apple after the parser preflight failed"
        )
        XCTAssertTrue(
            pendingStore.pendingRequests().isEmpty,
            "nothing was issued, so nothing may be left pending"
        )
        XCTAssertTrue(provenanceStore.records().isEmpty)
        XCTAssertEqual(runner.blockedInvocations, [])
    }

    // MARK: - Rollback never destroys a live certificate's key

    /// The legacy orphan: a rollback whose local cleanup failed used to delete the
    /// pending request and its private key, leaving a live Apple certificate that
    /// nothing on this Mac could install or even identify again.
    func testKeychainCleanupFailureKeepsThePendingKeyAndRevokesNothing() async throws {
        let directory = try scratchDirectory()
        let pendingStore = PendingSigningCertificateStore(directoryOverride: try scratchDirectory())
        let provenanceStore = IssuedSigningCertificateProvenanceStore(
            directoryOverride: try scratchDirectory()
        )
        // Apple issues a certificate for a different team, which is a genuine reason to
        // roll back — and the only kind of failure that is allowed to revoke anything.
        let issued = try await Self.makeCertificateData(
            in: directory,
            name: "other-team",
            subject: "/CN=Apple Distribution: Example Ltd (OTHERTEAM)/OU=OTHERTEAM/O=Example Ltd"
        )
        Self.enqueueEmptyCertificateList()
        Self.enqueueIssuedCertificate(id: "CERT-NEW", data: issued)

        // The dedicated keychain exists but cannot be inspected.
        let keychainURL = directory.appendingPathComponent("Signing.keychain-db")
        try Data("existing".utf8).write(to: keychainURL)
        let runner = PartiallyScriptedProcessRunner { invocation in
            guard invocation.executable == "/usr/bin/security" else { return nil }
            guard invocation.arguments.first == "find-identity" else {
                return CommandResult(terminationStatus: 0, output: "")
            }
            return CommandResult(terminationStatus: 1, output: "security: unable to open keychain")
        }
        let output = CollectedOutput()

        do {
            _ = try await makeService(
                runner: runner,
                pendingStore: pendingStore,
                provenanceStore: provenanceStore,
                keychainURL: keychainURL
            ).prepareLocalIdentity(
                teamID: Self.teamID,
                issuerID: "issuer",
                keyID: "key",
                privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation,
                onOutput: { output.append($0) }
            )
            XCTFail("expected teamMismatch")
        } catch let error as DistributionCertificateProvisioningError {
            guard case .teamMismatch = error else {
                return XCTFail("expected teamMismatch, got \(error)")
            }
        }

        // The certificate is still live on the account, so its key must still exist.
        let pending = pendingStore.pendingRequests()
        XCTAssertEqual(pending.count, 1, "the only key for a live certificate was deleted")
        let request = try XCTUnwrap(pending.first)
        XCTAssertEqual(request.certificateID, "CERT-NEW")
        XCTAssertTrue(
            try pendingStore.privateKeyPEM(id: request.id).contains("PRIVATE KEY"),
            "the persisted key must still be a usable PEM"
        )

        // Nothing was revoked, and nothing was deleted from any keychain.
        XCTAssertFalse(
            StubURLProtocol.requests.contains { $0.httpMethod == "DELETE" },
            "a certificate must not be revoked while its local cleanup is unverified"
        )
        XCTAssertFalse(
            runner.invocations.contains {
                $0.standardInput?.hasPrefix("delete-identity") == true
            }
        )

        // Ownership stays provable: recorded straight after the POST, before the
        // install that failed.
        let records = provenanceStore.records()
        XCTAssertEqual(records.map(\.certificateID), ["CERT-NEW"])
        XCTAssertEqual(records.first?.status, .issued)
        XCTAssertEqual(records.first?.expectedTeamID, Self.teamID)
        XCTAssertEqual(records.first?.publicKeyModulus, request.publicKeyModulus)
        XCTAssertEqual(
            provenanceStore.record(matchingPublicKeyModulus: request.publicKeyModulus)?
                .certificateID,
            "CERT-NEW"
        )

        let reported = output.text
        XCTAssertTrue(
            reported.contains("still occupies a certificate slot"),
            "the report must not understate the cost: \(reported)"
        )
        XCTAssertFalse(
            reported.contains("No certificate slot was lost"),
            "the old message claimed a safety the situation did not have"
        )
        XCTAssertFalse(reported.contains("releasing its certificate slot"))
        XCTAssertEqual(runner.blockedInvocations, [], "a real tool was almost invoked")
    }

    // MARK: - Slot exhaustion

    /// Two renewals with the same name and the same expiry are indistinguishable in the
    /// old listing, and revoking the wrong one costs another slot.
    func testSlotExhaustionListDistinguishesOtherwiseIdenticalCertificates() async throws {
        let directory = try scratchDirectory()
        let pendingStore = PendingSigningCertificateStore(directoryOverride: try scratchDirectory())
        let provenanceStore = IssuedSigningCertificateProvenanceStore(
            directoryOverride: try scratchDirectory()
        )
        let subject = "/CN=Apple Distribution: Example Ltd (\(Self.teamID))"
            + "/OU=\(Self.teamID)/O=Example Ltd"
        let first = try await Self.makeCertificateData(in: directory, name: "one", subject: subject)
        let second = try await Self.makeCertificateData(
            in: directory,
            name: "two",
            subject: subject
        )
        StubURLProtocol.enqueue(.init(
            match: { $0.url?.path == "/v1/certificates" && $0.httpMethod == "GET" },
            statusCode: 200,
            body: ["data": [
                Self.certificateResource(id: "CERT-A", data: first),
                Self.certificateResource(id: "CERT-B", data: second)
            ]]
        ))
        StubURLProtocol.enqueue(.init(
            match: { $0.url?.path == "/v1/certificates" && $0.httpMethod == "POST" },
            statusCode: 409,
            body: ["errors": [["detail": "maximum number of certificates"]]]
        ))
        let runner = PartiallyScriptedProcessRunner { invocation in
            invocation.executable == "/usr/bin/security"
                ? CommandResult(terminationStatus: 0, output: "")
                : nil
        }

        do {
            _ = try await makeService(
                runner: runner,
                pendingStore: pendingStore,
                provenanceStore: provenanceStore
            ).prepareLocalIdentity(
                teamID: Self.teamID,
                issuerID: "issuer",
                keyID: "key",
                privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation,
                onOutput: { _ in }
            )
            XCTFail("expected certificateSlotsExhausted")
        } catch let error as DistributionCertificateProvisioningError {
            guard case .certificateSlotsExhausted(let blocking) = error else {
                return XCTFail("expected certificateSlotsExhausted, got \(error)")
            }
            XCTAssertEqual(blocking.map(\.id).sorted(), ["CERT-A", "CERT-B"])
            let descriptions = blocking.map(\.descriptionText)
            XCTAssertNotEqual(
                descriptions[0],
                descriptions[1],
                "identical names must still produce distinguishable descriptions"
            )
            let message = try XCTUnwrap(error.errorDescription)
            XCTAssertTrue(message.contains("CERT-A"))
            XCTAssertTrue(message.contains("CERT-B"))
            XCTAssertTrue(
                message.contains(Self.shortFingerprint(of: first)),
                "the fingerprint is what identifies the certificate in Keychain Access"
            )
            XCTAssertTrue(message.contains("never revokes"))
        }

        // Apple's pre-existing certificates are never revoked to make room.
        XCTAssertFalse(StubURLProtocol.requests.contains { $0.httpMethod == "DELETE" })
        // Apple issued nothing, so nothing may be recorded or left pending.
        XCTAssertTrue(pendingStore.pendingRequests().isEmpty)
        XCTAssertTrue(provenanceStore.records().isEmpty)
        XCTAssertEqual(runner.blockedInvocations, [])
    }

    func testUnusableCertificateDescriptionCarriesOnlyPublicIdentifiers() {
        let certificate = UnusableDistributionCertificate(
            id: "ABC123",
            displayName: "Apple Distribution: Example Ltd",
            expirationDate: Date(timeIntervalSince1970: 1_700_000_000),
            sha1Fingerprint: "0123456789ABCDEF0123456789ABCDEF01234567"
        )

        let text = certificate.descriptionText
        XCTAssertTrue(text.hasPrefix("Apple Distribution: Example Ltd ("))
        XCTAssertTrue(text.contains("ABC123"))
        XCTAssertTrue(text.contains("01:23:45:67:89:AB:CD:EF"))
        XCTAssertFalse(text.contains("PRIVATE"))

        // Still readable when Apple returned no certificate content at all.
        let withoutContent = UnusableDistributionCertificate(
            id: "ABC123",
            displayName: "Apple Distribution: Example Ltd",
            expirationDate: nil
        )
        XCTAssertTrue(withoutContent.descriptionText.contains("ABC123"))
        XCTAssertNil(UnusableDistributionCertificate.shortFingerprint(nil))
        XCTAssertNil(UnusableDistributionCertificate.shortFingerprint("AB"))
        XCTAssertEqual(
            UnusableDistributionCertificate.shortFingerprint("aabbccddeeff0011"),
            "AA:BB:CC:DD:EE:FF:00:11"
        )
    }

    // MARK: - Provenance store

    func testProvenanceRecordsAreOwnerOnlyAndSurviveAFreshStore() throws {
        let directory = try scratchDirectory().appendingPathComponent("nested", isDirectory: true)
        let store = IssuedSigningCertificateProvenanceStore(directoryOverride: directory)

        let written = try store.recordStatus(
            .issued,
            certificateID: "CERT1",
            publicKeyModulus: "AABB",
            expectedTeamID: Self.teamID,
            at: Date(timeIntervalSince1970: 1_000)
        )

        func permissions(_ url: URL) throws -> Int {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        }
        XCTAssertEqual(try permissions(directory), 0o700)
        XCTAssertEqual(try permissions(store.recordURL(certificateID: "CERT1")), 0o600)

        // A fresh instance stands in for the next launch.
        let reader = IssuedSigningCertificateProvenanceStore(directoryOverride: directory)
        XCTAssertEqual(reader.record(certificateID: "CERT1"), written)
        XCTAssertEqual(reader.records(), [written])
        XCTAssertTrue(reader.wasIssuedByDevelopmentManagement(certificateID: "CERT1"))
        XCTAssertFalse(reader.wasIssuedByDevelopmentManagement(certificateID: "SOMEONE-ELSE"))

        // No key material of any kind reaches the record.
        let contents = try String(
            contentsOf: store.recordURL(certificateID: "CERT1"),
            encoding: .utf8
        ).lowercased()
        for forbidden in ["private", "password", "passphrase", "p12", "begin"] {
            XCTAssertFalse(contents.contains(forbidden), "record leaked \(forbidden)")
        }
    }

    func testProvenanceOutlivesThePendingKeyAndKeepsProvingOwnership() throws {
        let pendingDirectory = try scratchDirectory()
        let pendingStore = PendingSigningCertificateStore(directoryOverride: pendingDirectory)
        let provenanceStore = IssuedSigningCertificateProvenanceStore(
            directoryOverride: try scratchDirectory()
        )
        let request = PendingSigningCertificateRequest(
            id: "request-1",
            createdAt: Date(timeIntervalSince1970: 10),
            expectedTeamID: Self.teamID,
            publicKeyModulus: "C0FFEE",
            certificateID: "CERT1"
        )
        try pendingStore.save(request, privateKeyPEM: "-----BEGIN PRIVATE KEY-----\nk\n")
        try provenanceStore.recordStatus(
            .installed,
            certificateID: "CERT1",
            publicKeyModulus: request.publicKeyModulus,
            expectedTeamID: request.expectedTeamID
        )

        pendingStore.remove(id: request.id)

        XCTAssertTrue(pendingStore.pendingRequests().isEmpty)
        // The key is gone, so this record is now the only evidence of ownership.
        XCTAssertEqual(
            provenanceStore.record(matchingPublicKeyModulus: "c0ffee")?.certificateID,
            "CERT1"
        )
        XCTAssertEqual(provenanceStore.record(certificateID: "CERT1")?.status, .installed)
        XCTAssertNil(provenanceStore.record(matchingPublicKeyModulus: "DEADBEEF"))
        XCTAssertNil(provenanceStore.record(matchingPublicKeyModulus: "  "))
    }

    func testProvenanceStatusAdvancesWithoutLosingTheIssuanceTime() throws {
        let store = IssuedSigningCertificateProvenanceStore(
            directoryOverride: try scratchDirectory()
        )
        let issuedAt = Date(timeIntervalSince1970: 1_000)
        try store.recordStatus(
            .issued,
            certificateID: "CERT1",
            publicKeyModulus: "AABB",
            expectedTeamID: Self.teamID,
            at: issuedAt
        )

        let revoked = try store.recordStatus(
            .revoked,
            certificateID: "CERT1",
            // Later calls must never be able to rewrite what was originally issued.
            publicKeyModulus: "DIFFERENT",
            expectedTeamID: "OTHERTEAM",
            at: Date(timeIntervalSince1970: 2_000)
        )

        XCTAssertEqual(revoked.status, .revoked)
        XCTAssertEqual(revoked.issuedAt, issuedAt)
        XCTAssertEqual(revoked.statusChangedAt, Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(revoked.publicKeyModulus, "AABB")
        XCTAssertEqual(revoked.expectedTeamID, Self.teamID)
        XCTAssertEqual(store.records(), [revoked])
    }

    /// A revocation is the single fact most worth keeping, so it must be recordable even
    /// when the write at issuance time failed and left nothing behind.
    func testConfirmedRevocationIsRecordedEvenWithoutAnEarlierRecord() throws {
        let store = IssuedSigningCertificateProvenanceStore(
            directoryOverride: try scratchDirectory()
        )

        try store.recordStatus(
            .revoked,
            certificateID: "CERT-LATE",
            publicKeyModulus: "AABB",
            expectedTeamID: Self.teamID
        )

        XCTAssertEqual(store.record(certificateID: "CERT-LATE")?.status, .revoked)
    }

    func testProvenanceFileNamesStayInsideTheirDirectory() throws {
        let directory = try scratchDirectory()
        let store = IssuedSigningCertificateProvenanceStore(directoryOverride: directory)

        for hostile in ["../../escape", "/etc/passwd", "a/b", "..", ""] {
            let url = store.recordURL(certificateID: hostile)
            XCTAssertEqual(
                url.deletingLastPathComponent().standardizedFileURL,
                directory.standardizedFileURL,
                "\(hostile) escaped the store directory"
            )
        }
        // Different identifiers must never collide onto one sanitised file name.
        XCTAssertNotEqual(
            IssuedSigningCertificateProvenanceStore.fileName(certificateID: "a/b"),
            IssuedSigningCertificateProvenanceStore.fileName(certificateID: "a_b")
        )
    }

    // MARK: - Rollback policy

    func testParserPreflightFailureNeverTriggersARollback() {
        // It is raised before Apple is contacted, so there is nothing to revoke.
        XCTAssertFalse(DistributionCertificateProvisioningService.shouldRollBackCertificate(
            for: DistributionCertificateProvisioningError.certificateParserUnavailable("reason")
        ))
    }

    // MARK: - Fixtures

    private func makeService(
        runner: any ProcessRunning,
        pendingStore: PendingSigningCertificateStore,
        provenanceStore: IssuedSigningCertificateProvenanceStore,
        keychainURL: URL? = nil
    ) throws -> DistributionCertificateProvisioningService {
        let keychainURL = try keychainURL ?? scratchDirectory()
            .appendingPathComponent("Signing.keychain-db")
        return DistributionCertificateProvisioningService(
            processRunner: runner,
            signingKeychainService: SigningKeychainService(
                processRunner: runner,
                passwordStore: InMemoryPasswordStore(password: "pw"),
                keychainURLOverride: keychainURL,
                updatesSearchList: false
            ),
            pendingStore: pendingStore,
            provenanceStore: provenanceStore,
            urlSession: StubURLProtocol.session()
        )
    }

    private func scratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DMProvenanceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private static func enqueueEmptyCertificateList() {
        StubURLProtocol.enqueue(.init(
            match: { $0.url?.path == "/v1/certificates" && $0.httpMethod == "GET" },
            statusCode: 200,
            body: ["data": []]
        ))
    }

    private static func enqueueIssuedCertificate(id: String, data: Data) {
        StubURLProtocol.enqueue(.init(
            match: { $0.url?.path == "/v1/certificates" && $0.httpMethod == "POST" },
            statusCode: 201,
            body: ["data": certificateResource(id: id, data: data)]
        ))
    }

    private static func certificateResource(id: String, data: Data) -> [String: Any] {
        [
            "type": "certificates",
            "id": id,
            "attributes": [
                "certificateType": "DISTRIBUTION",
                "displayName": "Apple Distribution: Example Ltd",
                "expirationDate": "2035-08-15T17:37:13.000+00:00",
                "certificateContent": data.base64EncodedString()
            ]
        ]
    }

    private static func shortFingerprint(of certificateData: Data) -> String {
        UnusableDistributionCertificate.shortFingerprint(
            DeveloperTeamService.sha1Fingerprint(ofCertificateData: certificateData)
        ) ?? ""
    }

    private static func makePrivateKey(in directory: URL, name: String) async throws -> URL {
        let keyURL = directory.appendingPathComponent("\(name).key.pem")
        _ = try await ProcessRunner().runAndRequireSuccess(
            executable: openssl,
            arguments: ["genrsa", "-out", keyURL.path, "2048"]
        )
        return keyURL
    }

    private static func makeSelfSignedDER(
        key keyURL: URL,
        subject: String,
        at url: URL
    ) async throws -> URL {
        _ = try await ProcessRunner().runAndRequireSuccess(
            executable: openssl,
            arguments: [
                "req", "-new", "-x509",
                "-key", keyURL.path,
                "-sha256", "-days", "1",
                "-subj", subject,
                "-outform", "DER",
                "-out", url.path
            ]
        )
        return url
    }

    /// A genuine DER certificate, so every assertion runs through the real parser.
    private static func makeCertificateData(
        in directory: URL,
        name: String,
        subject: String
    ) async throws -> Data {
        let keyURL = try await makePrivateKey(in: directory, name: name)
        let derURL = try await makeSelfSignedDER(
            key: keyURL,
            subject: subject,
            at: directory.appendingPathComponent("\(name).der")
        )
        return try Data(contentsOf: derURL)
    }
}
