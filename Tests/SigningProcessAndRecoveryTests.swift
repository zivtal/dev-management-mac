import CryptoKit
import XCTest
@testable import DevManagement

/// Records every command a service issues instead of spawning anything, so the exact
/// argument vector and standard input can be asserted.
final class RecordingProcessRunner: ProcessRunning, @unchecked Sendable {
    struct Invocation: Equatable {
        let executable: String
        let arguments: [String]
        let standardInput: String?
    }

    private let lock = NSLock()
    private var storage: [Invocation] = []
    private var responses: [(Invocation) -> CommandResult?] = []

    var invocations: [Invocation] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    /// Answers the first matching rule; anything unmatched succeeds with no output.
    func respond(_ rule: @escaping (Invocation) -> CommandResult?) {
        lock.lock()
        responses.append(rule)
        lock.unlock()
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
        for rule in record(invocation) {
            if let result = rule(invocation) { return result }
        }
        return CommandResult(terminationStatus: 0, output: "")
    }

    /// Synchronous so the lock is never held across a suspension point.
    private func record(_ invocation: Invocation) -> [(Invocation) -> CommandResult?] {
        lock.lock()
        defer { lock.unlock() }
        storage.append(invocation)
        return responses
    }
}

final class InMemoryPasswordStore: SigningKeychainPasswordStore, @unchecked Sendable {
    private let lock = NSLock()
    private var password: String?
    private var readError: Error?

    init(password: String? = nil, readError: Error? = nil) {
        self.password = password
        self.readError = readError
    }

    func signingKeychainPassword() throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let readError { throw readError }
        return password
    }

    func setSigningKeychainPassword(_ password: String) throws {
        lock.lock()
        self.password = password
        lock.unlock()
    }

    var current: String? {
        lock.lock()
        defer { lock.unlock() }
        return password
    }
}

final class SigningProcessAndRecoveryTests: XCTestCase {
    private static let openssl = URL(fileURLWithPath: "/usr/bin/openssl")

    // MARK: - ProcessRunner standard input

    func testProcessRunnerWritesStandardInputAndKeepsItOutOfTheArgumentVector() async throws {
        let secret = "s3cret \"quoted\" \\ value"
        let result = try await ProcessRunner().runAndRequireSuccess(
            executable: URL(fileURLWithPath: "/bin/cat"),
            arguments: [],
            standardInput: Data(secret.utf8)
        )

        XCTAssertEqual(result.output, secret)
    }

    func testProcessRunnerAcceptsInputLargerThanOnePipeBuffer() async throws {
        // A naive synchronous write on the calling thread deadlocks well before this.
        let payload = String(repeating: "a", count: 512 * 1024)
        let result = try await ProcessRunner().runAndRequireSuccess(
            executable: URL(fileURLWithPath: "/bin/cat"),
            arguments: [],
            standardInput: Data(payload.utf8)
        )

        XCTAssertEqual(result.output.count, payload.count)
    }

    func testProcessRunnerReportsFailureStatusWithoutStandardInput() async throws {
        let result = try await ProcessRunner().run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exit 3"]
        )

        XCTAssertEqual(result.terminationStatus, 3)
    }

    // MARK: - security command quoting and redaction

    func testSecurityCommandQuotesEveryArgumentAndEscapesQuotesAndBackslashes() throws {
        let command = SecurityCommand([
            .plain("unlock-keychain"),
            .plain("-p"), .secret("pa\"ss\\word with spaces"),
            .plain("/tmp/a b/My.keychain-db")
        ])

        XCTAssertEqual(
            try command.standardInputLine(),
            "unlock-keychain \"-p\" \"pa\\\"ss\\\\word with spaces\" \"/tmp/a b/My.keychain-db\"\n"
        )
        XCTAssertEqual(command.name, "unlock-keychain")
        XCTAssertEqual(command.secrets, ["pa\"ss\\word with spaces"])
    }

    func testSecurityCommandRejectsSecretsThatWouldBreakLineParsing() {
        // A newline would be read as the start of a second command.
        for hostile in ["pass\nword", "pass\rword", "pass\0word"] {
            XCTAssertThrowsError(
                try SecurityCommand([.plain("import"), .secret(hostile)]).standardInputLine()
            ) { error in
                guard case SigningKeychainError.secretNotRepresentable = error else {
                    return XCTFail("expected secretNotRepresentable, got \(error)")
                }
            }
        }
    }

    func testSecurityCommandRedactionRemovesEverySecretOccurrence() {
        let redacted = SecurityCommand.redact(
            "failed for hunter2 while using hunter2",
            secrets: ["hunter2"]
        )

        XCTAssertEqual(redacted, "failed for •••• while using ••••")
        XCTAssertFalse(redacted.contains("hunter2"))
    }

    // MARK: - Signing keychain command construction

    func testPrepareKeychainCreatesUnlocksAndNeverPutsSecretsInArgv() async throws {
        let runner = RecordingProcessRunner()
        let store = InMemoryPasswordStore()
        let url = try scratchKeychainURL()
        let service = SigningKeychainService(
            processRunner: runner,
            passwordStore: store,
            keychainURLOverride: url,
            updatesSearchList: false
        )

        _ = try await service.prepareKeychain(onOutput: { _ in })

        let password = try XCTUnwrap(store.current)
        XCTAssertFalse(password.isEmpty)
        let interactive = runner.invocations.filter { $0.arguments == ["-i"] }
        XCTAssertEqual(interactive.count, 3)
        XCTAssertTrue(interactive[0].standardInput?.hasPrefix("create-keychain ") == true)
        XCTAssertTrue(interactive[1].standardInput?.hasPrefix("unlock-keychain ") == true)
        XCTAssertTrue(interactive[2].standardInput?.hasPrefix("set-keychain-settings ") == true)
        // The generated password must appear only on standard input.
        for invocation in runner.invocations {
            XCTAssertFalse(
                invocation.arguments.contains { $0.contains(password) },
                "password leaked into argv: \(invocation.arguments)"
            )
        }
        XCTAssertTrue(
            runner.invocations.contains { $0.arguments.first == "show-keychain-info" },
            "the lock state must be probed rather than assumed"
        )
    }

    func testPrepareKeychainOnExistingFileReusesItAndDoesNotRecreate() async throws {
        let runner = RecordingProcessRunner()
        let url = try scratchKeychainURL()
        try Data("existing".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let service = SigningKeychainService(
            processRunner: runner,
            passwordStore: InMemoryPasswordStore(password: "stored"),
            keychainURLOverride: url,
            updatesSearchList: false
        )

        _ = try await service.prepareKeychain(onOutput: { _ in })

        XCTAssertFalse(
            runner.invocations.contains { $0.standardInput?.hasPrefix("create-keychain") == true },
            "an existing keychain must never be recreated over the top of its key material"
        )
    }

    func testReusePathUnlocksAnExistingKeychainButCreatesNoNewOne() async throws {
        // A keychain relocks across restarts, so the path that reuses an identity has
        // to reopen it too — but it must not create one for a developer whose identity
        // lives in their login keychain.
        let absent = try scratchKeychainURL()
        let absentRunner = RecordingProcessRunner()
        _ = try await SigningKeychainService(
            processRunner: absentRunner,
            passwordStore: InMemoryPasswordStore(),
            keychainURLOverride: absent,
            updatesSearchList: false
        ).prepareKeychain(createIfMissing: false, onOutput: { _ in })

        XCTAssertTrue(absentRunner.invocations.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path))

        let existing = try scratchKeychainURL()
        try Data("existing".utf8).write(to: existing)
        defer { try? FileManager.default.removeItem(at: existing) }
        let existingRunner = RecordingProcessRunner()
        _ = try await SigningKeychainService(
            processRunner: existingRunner,
            passwordStore: InMemoryPasswordStore(password: "pw"),
            keychainURLOverride: existing,
            updatesSearchList: false
        ).prepareKeychain(createIfMissing: false, onOutput: { _ in })

        XCTAssertTrue(
            existingRunner.invocations.contains {
                $0.standardInput?.hasPrefix("unlock-keychain") == true
            },
            "an existing keychain must be reopened on the reuse path"
        )
    }

    func testPrepareKeychainFailsWithRecoveryGuidanceWhenThePasswordIsMissing() async throws {
        let url = try scratchKeychainURL()
        try Data("existing".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let runner = RecordingProcessRunner()
        let service = SigningKeychainService(
            processRunner: runner,
            passwordStore: InMemoryPasswordStore(password: nil),
            keychainURLOverride: url,
            updatesSearchList: false
        )

        do {
            _ = try await service.prepareKeychain(onOutput: { _ in })
            XCTFail("expected passwordUnavailable")
        } catch let error as SigningKeychainError {
            guard case .passwordUnavailable(let path) = error else {
                return XCTFail("expected passwordUnavailable, got \(error)")
            }
            XCTAssertEqual(path, url.path)
            let message = try XCTUnwrap(error.errorDescription)
            XCTAssertTrue(message.contains(url.path), "the error must name the keychain")
        }
        // Nothing may be deleted: the file can hold the only copy of a private key.
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(
            runner.invocations.contains {
                $0.arguments.contains("delete-keychain")
                    || $0.standardInput?.contains("delete-keychain") == true
            }
        )
    }

    func testPrepareKeychainReportsARejectedPasswordAndPreservesTheKeychain() async throws {
        let url = try scratchKeychainURL()
        try Data("existing".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let runner = RecordingProcessRunner()
        runner.respond { invocation in
            guard invocation.standardInput?.hasPrefix("unlock-keychain") == true else { return nil }
            return CommandResult(terminationStatus: 1, output: "SecKeychainUnlock: not correct")
        }
        let service = SigningKeychainService(
            processRunner: runner,
            passwordStore: InMemoryPasswordStore(password: "stale"),
            keychainURLOverride: url,
            updatesSearchList: false
        )

        do {
            _ = try await service.prepareKeychain(onOutput: { _ in })
            XCTFail("expected passwordRejected")
        } catch let error as SigningKeychainError {
            guard case .passwordRejected(let path) = error else {
                return XCTFail("expected passwordRejected, got \(error)")
            }
            XCTAssertEqual(path, url.path)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testPrepareKeychainRejectsAPasswordThatLeavesTheKeychainLocked() async throws {
        // `unlock-keychain` exits 0 for an already-unlocked keychain, so a silent
        // no-op must still be caught by the probe.
        let url = try scratchKeychainURL()
        try Data("existing".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let runner = RecordingProcessRunner()
        runner.respond { invocation in
            guard invocation.arguments.first == "show-keychain-info" else { return nil }
            return CommandResult(terminationStatus: 128, output: "User canceled the operation.")
        }
        let service = SigningKeychainService(
            processRunner: runner,
            passwordStore: InMemoryPasswordStore(password: "stale"),
            keychainURLOverride: url,
            updatesSearchList: false
        )

        do {
            _ = try await service.prepareKeychain(onOutput: { _ in })
            XCTFail("expected passwordRejected")
        } catch let error as SigningKeychainError {
            guard case .passwordRejected = error else {
                return XCTFail("expected passwordRejected, got \(error)")
            }
        }
    }

    func testFailingSecurityCommandNeverLeaksTheSecretIntoTheError() async throws {
        let url = try scratchKeychainURL()
        let runner = RecordingProcessRunner()
        let store = InMemoryPasswordStore(password: "hunter2")
        runner.respond { invocation in
            guard invocation.standardInput?.hasPrefix("create-keychain") == true else { return nil }
            return CommandResult(terminationStatus: 1, output: "failed while using hunter2")
        }
        let service = SigningKeychainService(
            processRunner: runner,
            passwordStore: store,
            keychainURLOverride: url,
            updatesSearchList: false
        )

        do {
            _ = try await service.prepareKeychain(onOutput: { _ in })
            XCTFail("expected commandFailed")
        } catch let error as SigningKeychainError {
            let message = try XCTUnwrap(error.errorDescription)
            XCTAssertFalse(message.contains("hunter2"), "secret leaked: \(message)")
            XCTAssertTrue(message.contains("••••"))
        }
    }

    func testImportIdentityVerifiesTheFingerprintLandedInTheKeychain() async throws {
        let url = try scratchKeychainURL()
        try Data("existing".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let runner = RecordingProcessRunner()
        runner.respond { invocation in
            guard invocation.arguments.first == "find-identity" else { return nil }
            return CommandResult(terminationStatus: 0, output: "  1) AABB \"Apple Distribution\"")
        }
        let service = SigningKeychainService(
            processRunner: runner,
            passwordStore: InMemoryPasswordStore(password: "pw"),
            keychainURLOverride: url,
            updatesSearchList: false
        )

        do {
            try await service.importIdentity(
                pkcs12URL: URL(fileURLWithPath: "/tmp/x.p12"),
                pkcs12Password: "p12pw",
                expectedSHA1Fingerprint: "CCDD",
                onOutput: { _ in }
            )
            XCTFail("expected importVerificationFailed")
        } catch let error as SigningKeychainError {
            guard case .importVerificationFailed = error else {
                return XCTFail("expected importVerificationFailed, got \(error)")
            }
        }
        // Both secrets stayed on standard input.
        for invocation in runner.invocations {
            XCTAssertFalse(invocation.arguments.contains("p12pw"))
            XCTAssertFalse(invocation.arguments.contains("pw"))
        }
        let partition = try XCTUnwrap(runner.invocations.first {
            $0.standardInput?.hasPrefix("set-key-partition-list") == true
        })
        XCTAssertTrue(partition.standardInput?.contains("apple-tool:,apple:,codesign:") == true)
    }

    func testRemoveIdentityTargetsOnlyTheDedicatedKeychainAndOnlyWhenPresent() async throws {
        let url = try scratchKeychainURL()
        try Data("existing".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let runner = RecordingProcessRunner()
        runner.respond { invocation in
            guard invocation.arguments.first == "find-identity" else { return nil }
            return CommandResult(terminationStatus: 0, output: "1) AABBCC \"Apple Distribution\"")
        }
        let service = SigningKeychainService(
            processRunner: runner,
            passwordStore: InMemoryPasswordStore(password: "pw"),
            keychainURLOverride: url,
            updatesSearchList: false
        )

        try await service.removeIdentity(sha1Fingerprint: "DDEEFF")
        XCTAssertFalse(
            runner.invocations.contains { $0.standardInput?.hasPrefix("delete-identity") == true },
            "an absent fingerprint must not trigger a delete"
        )

        try await service.removeIdentity(sha1Fingerprint: "AABBCC")
        XCTAssertTrue(
            runner.invocations.contains { $0.standardInput?.hasPrefix("unlock-keychain") == true },
            "rollback must unlock its dedicated keychain non-interactively before deleting"
        )
        let delete = try XCTUnwrap(runner.invocations.first {
            $0.standardInput?.hasPrefix("delete-identity") == true
        })
        XCTAssertTrue(delete.standardInput?.contains("AABBCC") == true)
        XCTAssertTrue(
            delete.standardInput?.contains(url.path) == true,
            "the delete must be scoped to the dedicated keychain, never the login one"
        )
    }

    // MARK: - Search list safety

    func testSearchListEntriesDropAnythingThatIsNotARealKeychainPath() throws {
        let directory = try scratchDirectory()
        let real = directory.appendingPathComponent("login.keychain-db")
        try Data("k".utf8).write(to: real)

        let entries = SigningKeychainService.usableSearchListEntries(
            [real.path, "security: warning something happened", "/does/not/exist.keychain", real.path],
            fileManager: .default
        )

        XCTAssertEqual(entries, [real.path])
    }

    func testSearchListIsNotReplacedWhenParsingLostARealEntry() throws {
        let directory = try scratchDirectory()
        let real = directory.appendingPathComponent("login.keychain-db")
        try Data("k".utf8).write(to: real)
        let output = "    \"\(real.path)\"\n    \"/gone/System.keychain\"\n"

        let existing = SigningKeychainService.usableSearchListEntries(
            SigningKeychainService.parseKeychainSearchList(output),
            fileManager: .default
        )

        XCTAssertEqual(existing, [real.path])
        // Rewriting now would silently drop /gone/System.keychain from the user's list.
        XCTAssertFalse(
            SigningKeychainService.searchListReplacementIsSafe(existing: existing, parsedFrom: output)
        )
        XCTAssertTrue(
            SigningKeychainService.searchListReplacementIsSafe(
                existing: existing,
                parsedFrom: "    \"\(real.path)\"\n"
            )
        )
    }

    func testAddingToTheSearchListPreservesExistingEntries() async throws {
        let directory = try scratchDirectory()
        let login = directory.appendingPathComponent("login.keychain-db")
        try Data("k".utf8).write(to: login)
        let url = directory.appendingPathComponent("DevManagement-Signing.keychain-db")
        try Data("k".utf8).write(to: url)
        let runner = RecordingProcessRunner()
        runner.respond { invocation in
            guard invocation.arguments == ["list-keychains", "-d", "user"] else { return nil }
            return CommandResult(terminationStatus: 0, output: "    \"\(login.path)\"\n")
        }
        let service = SigningKeychainService(
            processRunner: runner,
            passwordStore: InMemoryPasswordStore(password: "pw"),
            keychainURLOverride: url,
            updatesSearchList: true
        )

        _ = try await service.prepareKeychain(onOutput: { _ in })

        let write = try XCTUnwrap(runner.invocations.first {
            $0.arguments.starts(with: ["list-keychains", "-d", "user", "-s"])
        })
        XCTAssertEqual(
            write.arguments,
            ["list-keychains", "-d", "user", "-s", login.path, url.path]
        )
    }

    func testSearchListIsNotRewrittenWhenTheKeychainIsAlreadyListed() async throws {
        let directory = try scratchDirectory()
        let url = directory.appendingPathComponent("DevManagement-Signing.keychain-db")
        try Data("k".utf8).write(to: url)
        let runner = RecordingProcessRunner()
        runner.respond { invocation in
            guard invocation.arguments == ["list-keychains", "-d", "user"] else { return nil }
            // macOS reports the same file with and without the -db suffix.
            let listed = String(url.path.dropLast(3))
            return CommandResult(terminationStatus: 0, output: "    \"\(listed)\"\n")
        }
        let service = SigningKeychainService(
            processRunner: runner,
            passwordStore: InMemoryPasswordStore(password: "pw"),
            keychainURLOverride: url,
            updatesSearchList: true
        )

        _ = try await service.prepareKeychain(onOutput: { _ in })

        XCTAssertFalse(
            runner.invocations.contains { $0.arguments.contains("-s") },
            "an idempotent prepare must not rewrite the user's search list"
        )
    }

    // MARK: - Pending certificate crash recovery

    func testPendingRequestSurvivesACrashAndIsFoundByAFreshStore() throws {
        let directory = try scratchDirectory()
        let request = PendingSigningCertificateRequest(
            id: UUID().uuidString,
            createdAt: Date(timeIntervalSince1970: 1_000),
            expectedTeamID: "TEAM123",
            publicKeyModulus: "ABCDEF",
            certificateID: nil
        )
        let writer = PendingSigningCertificateStore(directoryOverride: directory)
        try writer.save(request, privateKeyPEM: "-----BEGIN PRIVATE KEY-----\nkey\n")

        // A fresh instance stands in for the next launch after a crash.
        let reader = PendingSigningCertificateStore(directoryOverride: directory)
        XCTAssertEqual(reader.pendingRequests(), [request])
        XCTAssertEqual(
            try reader.privateKeyPEM(id: request.id),
            "-----BEGIN PRIVATE KEY-----\nkey\n"
        )
    }

    func testPendingRequestFilesAreOwnerOnlyAndStoreNoPassword() throws {
        let directory = try scratchDirectory()
            .appendingPathComponent("nested", isDirectory: true)
        let store = PendingSigningCertificateStore(directoryOverride: directory)
        let request = PendingSigningCertificateRequest(
            id: "abc",
            createdAt: Date(),
            expectedTeamID: nil,
            publicKeyModulus: "AA",
            certificateID: nil
        )
        try store.save(request, privateKeyPEM: "key")

        func permissions(_ url: URL) throws -> Int {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        }
        XCTAssertEqual(try permissions(directory), 0o700)
        XCTAssertEqual(try permissions(store.privateKeyURL(id: "abc")), 0o600)
        XCTAssertEqual(try permissions(store.metadataURL(id: "abc")), 0o600)

        let metadata = try String(contentsOf: store.metadataURL(id: "abc"), encoding: .utf8)
        for forbidden in ["password", "passphrase", "p12"] {
            XCTAssertFalse(metadata.lowercased().contains(forbidden), "metadata leaked \(forbidden)")
        }
    }

    func testPendingRequestWithoutItsKeyIsIgnoredAndOldKeysArePreserved() throws {
        let directory = try scratchDirectory()
        let store = PendingSigningCertificateStore(directoryOverride: directory)
        let fresh = PendingSigningCertificateRequest(
            id: "fresh",
            createdAt: Date(),
            expectedTeamID: nil,
            publicKeyModulus: "AA",
            certificateID: nil
        )
        let stale = PendingSigningCertificateRequest(
            id: "stale",
            createdAt: Date(timeIntervalSinceNow: -60 * 60 * 24 * 40),
            expectedTeamID: nil,
            publicKeyModulus: "BB",
            certificateID: nil
        )
        let orphan = PendingSigningCertificateRequest(
            id: "orphan",
            createdAt: Date(),
            expectedTeamID: nil,
            publicKeyModulus: "CC",
            certificateID: nil
        )
        try store.save(fresh, privateKeyPEM: "k1")
        try store.save(stale, privateKeyPEM: "k2")
        try store.save(orphan, privateKeyPEM: "k3")
        // Metadata without a key is useless: the certificate could never be installed.
        try FileManager.default.removeItem(at: store.privateKeyURL(id: "orphan"))

        XCTAssertEqual(store.pendingRequests().map(\.id).sorted(), ["fresh", "stale"])

        // Age alone is never proof that Apple did not issue a matching certificate.
        // The old key may still be the only recoverable copy for an occupied slot.
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: store.privateKeyURL(id: "stale").path)
        )
    }

    func testModulusPairsAPersistedKeyWithOnlyItsOwnCertificate() async throws {
        // This is the whole basis of recovery: it is what proves a certificate on the
        // account was issued from a key Development Management created.
        let directory = try scratchDirectory()
        let mine = try await Self.makeKeyAndCertificate(in: directory, name: "mine")
        let theirs = try await Self.makeKeyAndCertificate(in: directory, name: "theirs")
        let runner = ProcessRunner()

        func modulus(of arguments: [String], standardInput: Data? = nil) async throws -> String? {
            let result = try await runner.runAndRequireSuccess(
                executable: Self.openssl,
                arguments: arguments,
                standardInput: standardInput
            )
            return DistributionCertificateProvisioningService.parseModulus(result.output)
        }

        let keyModulus = try await modulus(of: ["rsa", "-in", mine.keyURL.path, "-noout", "-modulus"])
        let ownCertModulus = try await modulus(
            of: ["x509", "-noout", "-modulus"],
            standardInput: try Data(contentsOf: mine.certificatePEMURL)
        )
        let otherCertModulus = try await modulus(
            of: ["x509", "-noout", "-modulus"],
            standardInput: try Data(contentsOf: theirs.certificatePEMURL)
        )

        XCTAssertNotNil(keyModulus)
        XCTAssertEqual(keyModulus, ownCertModulus)
        XCTAssertNotEqual(keyModulus, otherCertModulus)
    }

    func testParseModulusReadsOpenSSLOutputAndRejectsAnythingElse() {
        XCTAssertEqual(
            DistributionCertificateProvisioningService.parseModulus("Modulus=00ab\n"),
            "00AB"
        )
        XCTAssertEqual(
            DistributionCertificateProvisioningService.parseModulus("noise\n  Modulus=AB12  \n"),
            "AB12"
        )
        XCTAssertNil(DistributionCertificateProvisioningService.parseModulus("Modulus=\n"))
        XCTAssertNil(DistributionCertificateProvisioningService.parseModulus("unable to load key"))
    }

    func testOnlyProvenCertificateFailuresTriggerRollback() {
        // A locked keychain or failed helper says nothing about the certificate, so
        // revoking would throw away a perfectly good slot.
        XCTAssertFalse(DistributionCertificateProvisioningService.shouldRollBackCertificate(
            for: SigningKeychainError.passwordRejected("/tmp/k")
        ))
        XCTAssertFalse(DistributionCertificateProvisioningService.shouldRollBackCertificate(
            for: ProcessRunnerError.couldNotStart("unavailable")
        ))
        XCTAssertTrue(DistributionCertificateProvisioningService.shouldRollBackCertificate(
            for: DistributionCertificateProvisioningError.invalidCertificate
        ))
        XCTAssertTrue(DistributionCertificateProvisioningService.shouldRollBackCertificate(
            for: DistributionCertificateProvisioningError.teamMismatch(
                expected: "TEAM1",
                actual: "TEAM2"
            )
        ))
    }

    func testActiveDistributionCertificatesExcludeMacOnlyTypes() {
        let future = Date().addingTimeInterval(60 * 60 * 24)
        let certificates = [
            AppStoreConnectCertificate(
                id: "ios", certificateType: "DISTRIBUTION", displayName: "iOS",
                certificateContent: nil, expirationDate: future, activated: nil
            ),
            AppStoreConnectCertificate(
                id: "macApp", certificateType: "MAC_APP_DISTRIBUTION", displayName: "Mac",
                certificateContent: nil, expirationDate: future, activated: nil
            ),
            AppStoreConnectCertificate(
                id: "macInstaller", certificateType: "MAC_INSTALLER_DISTRIBUTION",
                displayName: "Installer", certificateContent: nil,
                expirationDate: future, activated: nil
            )
        ]

        XCTAssertEqual(
            DistributionCertificateProvisioningService
                .activeDistributionCertificates(certificates).map(\.id),
            ["ios"]
        )
    }

    func testOpenSSLPKCS12ExportAcceptsPasswordThroughStandardInputWithoutNewline() async throws {
        let directory = try scratchDirectory()
        let fixture = try await Self.makeKeyAndCertificate(in: directory, name: "identity")
        let outputURL = directory.appendingPathComponent("identity.p12")

        _ = try await ProcessRunner().runAndRequireSuccess(
            executable: Self.openssl,
            arguments: [
                "pkcs12", "-export",
                "-inkey", fixture.keyURL.path,
                "-in", fixture.certificatePEMURL.path,
                "-out", outputURL.path,
                "-passout", "stdin"
            ],
            standardInput: Data("temporary-password".utf8)
        )

        XCTAssertGreaterThan(
            (try Data(contentsOf: outputURL)).count,
            0
        )
    }

    // MARK: - Fixtures

    private func scratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DMSigningTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func scratchKeychainURL() throws -> URL {
        let directory = try scratchDirectory()
        return directory.appendingPathComponent("Signing.keychain-db")
    }

    private struct KeyAndCertificate {
        let keyURL: URL
        let certificatePEMURL: URL
    }

    private static func makeKeyAndCertificate(
        in directory: URL,
        name: String
    ) async throws -> KeyAndCertificate {
        let runner = ProcessRunner()
        let keyURL = directory.appendingPathComponent("\(name).key.pem")
        let csrURL = directory.appendingPathComponent("\(name).csr.pem")
        let certificateURL = directory.appendingPathComponent("\(name).cert.pem")
        _ = try await runner.runAndRequireSuccess(
            executable: openssl,
            arguments: [
                "req", "-new", "-newkey", "rsa:2048", "-nodes", "-sha256",
                "-subj", "/CN=Apple Distribution: Test (TEAM123)/OU=TEAM123",
                "-keyout", keyURL.path, "-out", csrURL.path
            ]
        )
        _ = try await runner.runAndRequireSuccess(
            executable: openssl,
            arguments: [
                "x509", "-req", "-in", csrURL.path, "-signkey", keyURL.path,
                "-days", "30", "-out", certificateURL.path
            ]
        )
        return KeyAndCertificate(keyURL: keyURL, certificatePEMURL: certificateURL)
    }

}
