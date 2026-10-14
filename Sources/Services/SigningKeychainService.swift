import Foundation

enum SigningKeychainError: LocalizedError {
    case passwordUnavailable(String)
    case passwordRejected(String)
    case secretNotRepresentable
    case commandFailed(command: String, status: Int32, output: String)
    case importVerificationFailed(fingerprint: String, keychainPath: String)
    case recoveryFailed(backupPath: String, reason: String)
    case repairBusy

    var errorDescription: String? {
        switch self {
        // Normal publishing never replaces a keychain. Explicit recovery in Settings
        // preserves a verified copy before replacing the active database.
        case .passwordUnavailable(let path):
            return L10n.format(
                "The Development Management signing keychain at %@ cannot be opened because its saved password is missing. Open Settings → Publishing → Repair Signing Keychain to preserve a backup and prepare signing again. No archive was uploaded.",
                path
            )
        case .passwordRejected(let path):
            return L10n.format(
                "The saved password no longer opens the Development Management signing keychain at %@. Open Settings → Publishing → Repair Signing Keychain to preserve a backup and prepare signing again. No archive was uploaded.",
                path
            )
        case .secretNotRepresentable:
            return L10n.text("A signing password contained characters that cannot be passed to the keychain tool safely.")
        case .commandFailed(let command, let status, let output):
            return output.isEmpty
                ? L10n.format("The keychain command %@ failed (code %d).", command, status)
                : L10n.format("The keychain command %@ failed (code %d).\n%@", command, status, output)
        case .importVerificationFailed(let fingerprint, let keychainPath):
            return L10n.format(
                "The Apple Distribution identity %@ was imported but is not present in %@.",
                fingerprint,
                keychainPath
            )
        case .recoveryFailed(let backupPath, let reason):
            return L10n.format("Signing keychain repair did not finish. The original keychain backup is at %@. %@", backupPath, reason)
        case .repairBusy:
            return L10n.text("Wait for the current work or signing keychain repair to finish, then try again.")
        }
    }
}

/// One `security` invocation, split so that secrets can be redacted from anything
/// that is logged and kept out of the argument vector entirely.
struct SecurityCommand: Equatable {
    enum Token: Equatable {
        case plain(String)
        case secret(String)

        var value: String {
            switch self {
            case .plain(let value), .secret(let value): return value
            }
        }
    }

    let tokens: [Token]

    init(_ tokens: [Token]) {
        self.tokens = tokens
    }

    var secrets: [String] {
        tokens.compactMap { token in
            if case .secret(let value) = token, !value.isEmpty { return value }
            return nil
        }
    }

    /// The name shown in errors. Never includes an argument, so it can never leak.
    var name: String { tokens.first?.value ?? "security" }

    /// `security -i` reads one command per line and tokenizes it with shell-style
    /// double quoting, so every argument is quoted and every quote or backslash
    /// inside it is escaped.
    func standardInputLine() throws -> String {
        guard tokens.allSatisfy({ Self.isRepresentable($0.value) }) else {
            throw SigningKeychainError.secretNotRepresentable
        }
        let head = tokens.first.map(\.value) ?? ""
        let tail = tokens.dropFirst().map { Self.quote($0.value) }
        return ([head] + tail).joined(separator: " ") + "\n"
    }

    static func isRepresentable(_ value: String) -> Bool {
        !value.unicodeScalars.contains { $0 == "\n" || $0 == "\r" || $0 == "\0" }
    }

    static func quote(_ value: String) -> String {
        var escaped = "\""
        for character in value {
            if character == "\"" || character == "\\" {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        escaped.append("\"")
        return escaped
    }

    static func redact(_ text: String, secrets: [String]) -> String {
        secrets.reduce(text) { partial, secret in
            partial.replacingOccurrences(of: secret, with: "••••")
        }
    }
}

/// Where the dedicated keychain's password lives. Injectable so tests can exercise
/// the keychain paths without ever writing to the developer's login keychain.
protocol SigningKeychainPasswordStore: Sendable {
    func signingKeychainPassword() throws -> String?
    func setSigningKeychainPassword(_ password: String) throws
}

/// `@unchecked` only because `KeychainCredentialStore` is a reference type with an
/// internal cache; every use here is serialised by `SigningKeychainService`.
struct LoginKeychainPasswordStore: SigningKeychainPasswordStore, @unchecked Sendable {
    private let credentialStore: KeychainCredentialStore

    init(credentialStore: KeychainCredentialStore = KeychainCredentialStore()) {
        self.credentialStore = credentialStore
    }

    func signingKeychainPassword() throws -> String? {
        try SilentKeychainAccess.perform {
            try credentialStore.string(for: .signingKeychainPassword)
        }
    }

    func setSigningKeychainPassword(_ password: String) throws {
        try credentialStore.set(password, for: .signingKeychainPassword)
    }
}

/// A dedicated, Development Management owned keychain for distribution signing.
///
/// Importing into the login keychain cannot work unattended: `security` has no way
/// to set the imported key's partition list without the login keychain password, so
/// `codesign` blocks on a modal authorization prompt that an `LSUIElement` menu-bar
/// app cannot answer. A separate keychain whose password Development Management
/// generates and stores solves that — the partition list can be set non-interactively,
/// and adding the keychain to the user search list makes the identity visible to
/// `codesign`, `xcodebuild`, and `SecItemCopyMatching` exactly like a login-keychain one.
actor SigningKeychainService {
    static let shared = SigningKeychainService()

    static let keychainFilename = "DevManagement-Signing.keychain-db"
    /// Entitles Apple's signing tools to use the imported private key without a prompt.
    static let partitionList = "apple-tool:,apple:,codesign:"

    private let processRunner: any ProcessRunning
    private let fileManager: FileManager
    private let passwordStore: any SigningKeychainPasswordStore
    private let keychainURLOverride: URL?
    private let updatesSearchList: Bool
    private let lockState: @Sendable (URL) -> Bool
    private let removeBackedUpKeychain: @Sendable (URL) throws -> Void

    init(
        processRunner: any ProcessRunning = ProcessRunner(),
        fileManager: FileManager = .default,
        passwordStore: any SigningKeychainPasswordStore = LoginKeychainPasswordStore(),
        keychainURLOverride: URL? = nil,
        updatesSearchList: Bool = true,
        lockState: @escaping @Sendable (URL) -> Bool = SilentKeychainAccess.isUnlocked,
        removeBackedUpKeychain: @escaping @Sendable (URL) throws -> Void = SilentKeychainAccess.removeBackedUpKeychain
    ) {
        self.processRunner = processRunner
        self.fileManager = fileManager
        self.passwordStore = passwordStore
        self.keychainURLOverride = keychainURLOverride
        self.updatesSearchList = updatesSearchList
        self.lockState = lockState
        self.removeBackedUpKeychain = removeBackedUpKeychain
    }

    private static let security = URL(fileURLWithPath: "/usr/bin/security")

    var keychainURL: URL {
        keychainURLOverride ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Keychains", isDirectory: true)
            .appendingPathComponent(Self.keychainFilename)
    }

    /// Only called by the explicit Settings action while no managed work is active.
    /// A working keychain is kept. An unusable one is copied and byte-verified before
    /// Security unregisters the active database, so stale handles/search entries are
    /// not reused. The backup is never deleted, even if creating the replacement fails.
    /// This does not contact Apple, revoke certificates, or export private keys.
    func repairKeychain() async throws -> URL? {
        do {
            try await prepareKeychain(onOutput: { _ in })
            return nil
        } catch SigningKeychainError.passwordUnavailable {
            // Missing machine-generated password: preserve the old database.
        } catch SigningKeychainError.passwordRejected {
            // Confirmed unusable keychain: preserve the old database.
        }

        let url = keychainURL
        let backup = url.deletingLastPathComponent().appendingPathComponent(
            "DevManagement-Signing-backup-\(UUID().uuidString).keychain-db"
        )
        try fileManager.copyItem(at: url, to: backup)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        guard try Data(contentsOf: url) == Data(contentsOf: backup) else {
            throw SigningKeychainError.recoveryFailed(
                backupPath: backup.path,
                reason: L10n.text("Backup verification failed. The original keychain was not replaced.")
            )
        }
        do {
            try removeBackedUpKeychain(url)
            try await prepareKeychain(onOutput: { _ in })
            return backup
        } catch {
            throw SigningKeychainError.recoveryFailed(backupPath: backup.path, reason: error.localizedDescription)
        }
    }

    /// Creates the keychain when missing, unlocks it, disables auto-locking, and
    /// makes sure it is on the user search list. Safe to call repeatedly, and safe
    /// to call on every publish including the ones that reuse an existing identity —
    /// a keychain relocks across restarts no matter how it was created.
    /// `createIfMissing` is false on the reuse path: a developer whose Apple
    /// Distribution identity already lives in their login keychain never needs a
    /// dedicated one, and creating an empty keychain plus a stored password for them
    /// would be pure side effect.
    @discardableResult
    func prepareKeychain(
        createIfMissing: Bool = true,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> URL {
        let url = keychainURL
        let existed = fileManager.fileExists(atPath: url.path)
        guard existed || createIfMissing else { return url }

        let password: String
        if existed {
            // Never create a second keychain over the top of one that already holds
            // key material, and never delete it to recover: report and stop.
            guard let stored = try storedPassword(), !stored.isEmpty else {
                throw SigningKeychainError.passwordUnavailable(url.path)
            }
            password = stored
        } else {
            password = try existingOrGeneratedPassword()
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try await runSecurity(SecurityCommand([
                .plain("create-keychain"),
                .plain("-p"), .secret(password),
                .plain(url.path)
            ]))
            onOutput(L10n.text(
                "Created a dedicated Development Management signing keychain.\n"
            ))
        }

        try await unlock(url: url, password: password, wasExisting: existed)

        // No -l/-u arguments: the keychain must not re-lock while a publish runs.
        try await runSecurity(SecurityCommand([
            .plain("set-keychain-settings"),
            .plain(url.path)
        ]))
        if updatesSearchList {
            try await addToSearchListIfNeeded(url: url)
        }
        return url
    }

    private func unlock(url: URL, password: String, wasExisting: Bool) async throws {
        do {
            try await runSecurity(SecurityCommand([
                .plain("unlock-keychain"),
                .plain("-p"), .secret(password),
                .plain(url.path)
            ]))
        } catch let error as SigningKeychainError {
            if wasExisting,
               case .commandFailed(_, let status, let output) = error,
               status == 51 || (output.contains("SecKeychainUnlock") && output.contains("not correct")) {
                throw SigningKeychainError.passwordRejected(url.path)
            }
            throw error
        }
        // `unlock-keychain` succeeds silently when a keychain is already unlocked, so
        // the lock state is probed separately before anything is imported.
        guard try await isUnlocked(url: url) else {
            throw wasExisting
                ? SigningKeychainError.passwordRejected(url.path)
                : SigningKeychainError.passwordUnavailable(url.path)
        }
    }

    func isUnlocked(url: URL) async throws -> Bool {
        lockState(url)
    }

    /// Imports a PKCS#12 identity and authorizes Apple's signing tools to use its key.
    /// Verifies afterwards that the identity really landed in the dedicated keychain.
    func importIdentity(
        pkcs12URL: URL,
        pkcs12Password: String,
        expectedSHA1Fingerprint: String,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws {
        let url = try await prepareKeychain(onOutput: onOutput)
        // Recovery may retry after the identity was imported successfully but the
        // separate provenance write failed. Treat an exact fingerprint match as an
        // already-completed import so that retrying remains idempotent instead of
        // failing forever with Security's "item already exists" error.
        if try await containsIdentity(sha1Fingerprint: expectedSHA1Fingerprint) {
            try await authorizeSigningTools(for: expectedSHA1Fingerprint)
            return
        }
        let keychainPassword = try requiredPassword()
        try await runSecurity(SecurityCommand([
            .plain("import"), .plain(pkcs12URL.path),
            .plain("-k"), .plain(url.path),
            .plain("-f"), .plain("pkcs12"),
            .plain("-P"), .secret(pkcs12Password),
            .plain("-T"), .plain("/usr/bin/codesign"),
            .plain("-T"), .plain("/usr/bin/xcodebuild"),
            .plain("-T"), .plain("/usr/bin/productbuild")
        ]))
        // `-T` alone is not enough on macOS 10.12+: without an explicit partition
        // list the key stays guarded by a UI authorization prompt.
        try await runSecurity(SecurityCommand([
            .plain("set-key-partition-list"),
            .plain("-S"), .plain(Self.partitionList),
            .plain("-s"),
            .plain("-k"), .secret(keychainPassword),
            .plain(url.path)
        ]))
        guard try await containsIdentity(sha1Fingerprint: expectedSHA1Fingerprint) else {
            throw SigningKeychainError.importVerificationFailed(
                fingerprint: expectedSHA1Fingerprint,
                keychainPath: url.path
            )
        }
    }

    /// Repair interrupted imports before codesign/productbuild can launch a dialog.
    /// Only keys in this app's dedicated keychain are changed.
    func authorizeSigningTools(for fingerprint: String) async throws {
        guard try await containsIdentity(sha1Fingerprint: fingerprint) else { return }
        let password = try requiredPassword()
        try await runSecurity(SecurityCommand([
            .plain("set-key-partition-list"),
            .plain("-S"), .plain(Self.partitionList), .plain("-s"),
            .plain("-k"), .secret(password), .plain(keychainURL.path)
        ]))
    }

    /// Whether the dedicated keychain holds an identity with this fingerprint.
    func containsIdentity(sha1Fingerprint: String) async throws -> Bool {
        let url = keychainURL
        guard fileManager.fileExists(atPath: url.path) else { return false }
        // No `-v`: validity is judged separately, and a policy filter here would hide
        // an identity that must still be found in order to be removed.
        let result = try await processRunner.runAndRequireSuccess(
            executable: Self.security,
            arguments: ["find-identity", url.path]
        )
        return Self.identityListing(result.output, contains: sha1Fingerprint)
    }

    /// Removes exactly one identity, by fingerprint, from the dedicated keychain.
    ///
    /// Scoped twice over so a rollback can never touch pre-existing key material:
    /// the fingerprint must match the certificate this attempt created, and the
    /// keychain argument is always Development Management's own file, never the
    /// login keychain.
    func removeIdentity(sha1Fingerprint: String) async throws {
        let url = keychainURL
        guard fileManager.fileExists(atPath: url.path) else { return }
        // Deleting key material from a locked keychain can invoke SecurityAgent. Always
        // reopen our dedicated keychain with its stored machine-generated password
        // first; if that fails, abort the rollback and leave Apple's certificate active.
        try await prepareKeychain(createIfMissing: false, onOutput: { _ in })
        guard try await containsIdentity(sha1Fingerprint: sha1Fingerprint) else { return }
        try await runSecurity(SecurityCommand([
            .plain("delete-identity"),
            .plain("-Z"), .plain(sha1Fingerprint),
            .plain(url.path)
        ]))
    }

    static func identityListing(_ output: String, contains sha1Fingerprint: String) -> Bool {
        let target = sha1Fingerprint
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard !target.isEmpty else { return false }
        return output.uppercased().contains(target)
    }

    private func addToSearchListIfNeeded(url: URL) async throws {
        let result = try await processRunner.runAndRequireSuccess(
            executable: Self.security,
            arguments: ["list-keychains", "-d", "user"]
        )
        let existing = Self.usableSearchListEntries(
            Self.parseKeychainSearchList(result.output),
            fileManager: fileManager
        )
        guard !Self.searchList(existing, contains: url.path) else { return }
        // Replacing the search list with fewer entries than it had would silently
        // drop the user's login keychain, so a parse that lost entries is refused.
        guard Self.searchListReplacementIsSafe(existing: existing, parsedFrom: result.output) else {
            return
        }
        _ = try await processRunner.runAndRequireSuccess(
            executable: Self.security,
            arguments: ["list-keychains", "-d", "user", "-s"] + existing + [url.path]
        )
    }

    /// `security list-keychains` prints one quoted, indented path per line.
    static func parseKeychainSearchList(_ output: String) -> [String] {
        output
            .split(whereSeparator: \Character.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            .filter { !$0.isEmpty }
    }

    /// `ProcessRunner` folds stderr into stdout, so a warning would otherwise become
    /// a bogus search-list entry the moment the list is rewritten. Only absolute
    /// paths that exist on disk survive.
    static func usableSearchListEntries(
        _ entries: [String],
        fileManager: FileManager = .default
    ) -> [String] {
        var seen: Set<String> = []
        return entries.filter { entry in
            entry.hasPrefix("/")
                && fileManager.fileExists(atPath: entry)
                && seen.insert(normalizedKeychainPath(entry)).inserted
        }
    }

    /// True when every line that looked like a keychain path survived validation.
    static func searchListReplacementIsSafe(existing: [String], parsedFrom output: String) -> Bool {
        let candidates = parseKeychainSearchList(output).filter { $0.hasPrefix("/") }
        let survivors = Set(existing.map(normalizedKeychainPath))
        return candidates.allSatisfy { survivors.contains(normalizedKeychainPath($0)) }
    }

    /// macOS reports both `foo.keychain` and `foo.keychain-db` for the same file, so
    /// compare on the name without the database suffix.
    static func searchList(_ entries: [String], contains path: String) -> Bool {
        let target = normalizedKeychainPath(path)
        return entries.contains { normalizedKeychainPath($0) == target }
    }

    static func normalizedKeychainPath(_ path: String) -> String {
        path.hasSuffix("-db") ? String(path.dropLast(3)) : path
    }

    @discardableResult
    private func runSecurity(_ command: SecurityCommand) async throws -> CommandResult {
        let line = try command.standardInputLine()
        let result = try await processRunner.run(
            executable: Self.security,
            arguments: ["-i"],
            workingDirectory: nil,
            additionalEnvironment: [:],
            standardInput: Data(line.utf8),
            onOutput: nil,
            terminateWhenOutput: nil
        )
        guard result.terminationStatus == 0 else {
            throw SigningKeychainError.commandFailed(
                command: command.name,
                status: result.terminationStatus,
                output: SecurityCommand.redact(result.output, secrets: command.secrets)
            )
        }
        return result
    }

    private func storedPassword() throws -> String? {
        try passwordStore.signingKeychainPassword()
    }

    private func requiredPassword() throws -> String {
        guard let password = try storedPassword(), !password.isEmpty else {
            throw SigningKeychainError.passwordUnavailable(keychainURL.path)
        }
        return password
    }

    private func existingOrGeneratedPassword() throws -> String {
        if let existing = try storedPassword(), !existing.isEmpty {
            return existing
        }
        let generated = UUID().uuidString + UUID().uuidString
        try passwordStore.setSigningKeychainPassword(generated)
        return generated
    }
}
