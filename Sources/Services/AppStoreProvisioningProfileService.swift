import Foundation

enum AppStoreProvisioningProfileError: LocalizedError {
    case certificateNotOnAccount(String)
    case bundleIdentifiersNotRegistered([String])
    case profileContentUnavailable(String)
    case profileMissingEntitlements(name: String, bundleIdentifier: String, entitlements: [String])

    var errorDescription: String? {
        switch self {
        case .certificateNotOnAccount(let commonName):
            return L10n.format(
                "The local Apple Distribution identity %@ does not exist on the App Store Connect account, so no distribution profile can reference it. Import a certificate that belongs to this team. No archive was uploaded.",
                commonName
            )
        case .bundleIdentifiersNotRegistered(let identifiers):
            // Every missing identifier at once: registering them one failed publish at
            // a time would mean one Release archive per app extension.
            return L10n.format(
                "These bundle identifiers are not registered in App Store Connect, so no distribution profile could be created for them: %@. Register each one under Identifiers with the capabilities the app uses, then publish again. No archive was uploaded.",
                identifiers.joined(separator: ", ")
            )
        case .profileContentUnavailable(let name):
            return L10n.format(
                "App Store Connect returned distribution profile %@ without its profile data, so it could not be installed. No archive was uploaded.",
                name
            )
        case .profileMissingEntitlements(let name, let bundleIdentifier, let entitlements):
            return L10n.format(
                "Distribution profile %@ for %@ is missing required capabilities (%@). Enable these capabilities for the identifier in Apple Developer, then publish again. The archive was not exported or uploaded.",
                name,
                bundleIdentifier,
                entitlements.joined(separator: ", ")
            )
        }
    }
}

struct AppStoreProvisioningTarget: Equatable, Sendable {
    let bundleIdentifier: String
    let requiredEntitlementKeys: Set<String>
}

/// Whether Development Management may register a missing bundle identifier itself.
///
/// `manual` is the default and the only value used today. A bundle identifier created
/// through the API starts with no capabilities enabled, so auto-registering one for a
/// bundle that uses App Groups, Push, or HealthKit would produce a profile that cannot
/// sign it and an error far less clear than naming the identifier up front. Automatic
/// registration becomes safe once capability mirroring exists.
enum BundleIDRegistrationPolicy: Equatable, Sendable {
    case manual
    case automatic
}

/// Maps each bundle identifier in an archive to an installed App Store provisioning
/// profile that authorizes a specific local distribution certificate, so the export
/// can be fully manual and never reach for Xcode cloud signing.
actor AppStoreProvisioningProfileService {
    static let shared = AppStoreProvisioningProfileService()

    private let fileManager: FileManager
    private let developerTeamService: DeveloperTeamService
    private let registrationPolicy: BundleIDRegistrationPolicy

    init(
        fileManager: FileManager = .default,
        developerTeamService: DeveloperTeamService = DeveloperTeamService(),
        registrationPolicy: BundleIDRegistrationPolicy = .manual
    ) {
        self.fileManager = fileManager
        self.developerTeamService = developerTeamService
        self.registrationPolicy = registrationPolicy
    }

    /// Checks before the archive that the identifiers a publish will need are
    /// registered, so a missing identifier costs an API call rather than a full
    /// Release build. Embedded bundles can only be enumerated after archiving, so this
    /// covers the application itself.
    func preflight(
        bundleIdentifiers: [String],
        issuerID: String,
        keyID: String,
        privateKeyPEM: String
    ) async throws {
        let identifiers = Self.uniqueIdentifiers(bundleIdentifiers)
        guard !identifiers.isEmpty else { return }
        let appStoreConnect = try AppStoreConnectService(
            issuerID: issuerID,
            keyID: keyID,
            privateKeyPEM: privateKeyPEM
        )
        let registered = Set(try await appStoreConnect.bundleIDs().map(\.identifier))
        let missing = identifiers.filter { !registered.contains($0) }
        guard missing.isEmpty else {
            throw AppStoreProvisioningProfileError.bundleIdentifiersNotRegistered(missing)
        }
    }

    /// Returns a `bundle identifier -> profile name` map suitable for the
    /// `provisioningProfiles` key of an export options plist.
    func ensureProfiles(
        targets: [AppStoreProvisioningTarget],
        identity: DistributionSigningIdentity,
        issuerID: String,
        keyID: String,
        privateKeyPEM: String,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> [String: String] {
        let uniqueTargets = Self.uniqueTargets(targets)
        guard !uniqueTargets.isEmpty else { return [:] }

        let installed = developerTeamService.provisioningProfileRecords()
        var resolved: [String: String] = [:]
        var pending: [String] = []
        for target in uniqueTargets {
            let bundleIdentifier = target.bundleIdentifier
            if let match = Self.installedAppStoreProfile(
                in: installed,
                bundleIdentifier: bundleIdentifier,
                teamID: identity.teamID,
                certificateSHA1: identity.sha1Fingerprint,
                requiredEntitlementKeys: target.requiredEntitlementKeys
            ), let name = match.name {
                resolved[bundleIdentifier] = name
                onOutput(L10n.format(
                    "Using installed distribution profile %@ for %@.\n",
                    name,
                    bundleIdentifier
                ))
            } else {
                pending.append(bundleIdentifier)
            }
        }
        guard !pending.isEmpty else { return resolved }

        let appStoreConnect = try AppStoreConnectService(
            issuerID: issuerID,
            keyID: keyID,
            privateKeyPEM: privateKeyPEM
        )
        let certificateID = try await self.certificateID(
            for: identity,
            appStoreConnect: appStoreConnect
        )
        var bundleIDsByIdentifier = Dictionary(
            try await appStoreConnect.bundleIDs().map { ($0.identifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let accountProfiles = try await appStoreConnect.profiles()

        // Everything that still needs a profile is checked for a registered
        // identifier in one pass, so the user sees every missing one at once.
        let requiredEntitlementsByIdentifier = Dictionary(
            uniqueKeysWithValues: uniqueTargets.map {
                ($0.bundleIdentifier, $0.requiredEntitlementKeys)
            }
        )
        let needingCreation = pending.filter { bundleIdentifier in
            Self.reusableAccountProfile(
                in: accountProfiles,
                bundleIdentifier: bundleIdentifier,
                certificateID: certificateID,
                requiredEntitlementKeys: requiredEntitlementsByIdentifier[bundleIdentifier] ?? []
            ) == nil
        }
        let missing = needingCreation.filter { bundleIDsByIdentifier[$0] == nil }
        if !missing.isEmpty {
            guard registrationPolicy == .automatic else {
                throw AppStoreProvisioningProfileError.bundleIdentifiersNotRegistered(missing)
            }
            for identifier in missing {
                let created = try await appStoreConnect.createIOSBundleID(
                    identifier: identifier,
                    name: Self.bundleIDName(for: identifier)
                )
                bundleIDsByIdentifier[identifier] = created
                onOutput(L10n.format(
                    "Registered bundle identifier %@ in App Store Connect.\n",
                    identifier
                ))
            }
        }

        for bundleIdentifier in pending {
            let profile = try await self.profile(
                for: bundleIdentifier,
                certificateID: certificateID,
                requiredEntitlementKeys: requiredEntitlementsByIdentifier[bundleIdentifier] ?? [],
                accountProfiles: accountProfiles,
                bundleIDsByIdentifier: bundleIDsByIdentifier,
                appStoreConnect: appStoreConnect,
                onOutput: onOutput
            )
            try install(profile)
            resolved[bundleIdentifier] = profile.name
        }
        return resolved
    }

    private func profile(
        for bundleIdentifier: String,
        certificateID: String,
        requiredEntitlementKeys: Set<String>,
        accountProfiles: [AppStoreConnectProfile],
        bundleIDsByIdentifier: [String: AppStoreConnectBundleID],
        appStoreConnect: AppStoreConnectService,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> AppStoreConnectProfile {
        if let reusable = Self.reusableAccountProfile(
            in: accountProfiles,
            bundleIdentifier: bundleIdentifier,
            certificateID: certificateID,
            requiredEntitlementKeys: requiredEntitlementKeys
        ) {
            onOutput(L10n.format(
                "Reusing App Store Connect distribution profile %@ for %@.\n",
                reusable.name,
                bundleIdentifier
            ))
            return reusable
        }
        guard let bundleID = bundleIDsByIdentifier[bundleIdentifier] else {
            throw AppStoreProvisioningProfileError.bundleIdentifiersNotRegistered([bundleIdentifier])
        }
        let name = Self.profileName(
            bundleIdentifier: bundleIdentifier,
            existingNames: Set(accountProfiles.map(\.name))
        )
        let created = try await appStoreConnect.createAppStoreProfile(
            name: name,
            bundleIDResourceID: bundleID.id,
            certificateID: certificateID
        )
        onOutput(L10n.format(
            "Created App Store distribution profile %@ for %@.\n",
            created.name,
            bundleIdentifier
        ))
        let missing = Self.missingEntitlementKeys(
            requiredEntitlementKeys,
            inProfileContent: created.profileContent
        )
        guard missing.isEmpty else {
            throw AppStoreProvisioningProfileError.profileMissingEntitlements(
                name: created.name,
                bundleIdentifier: bundleIdentifier,
                entitlements: missing.sorted()
            )
        }
        return created
    }

    private func certificateID(
        for identity: DistributionSigningIdentity,
        appStoreConnect: AppStoreConnectService
    ) async throws -> String {
        let certificates = try await appStoreConnect.certificates()
        guard let match = Self.matchingCertificateID(
            in: certificates,
            sha1Fingerprint: identity.sha1Fingerprint
        ) else {
            throw AppStoreProvisioningProfileError.certificateNotOnAccount(identity.commonName)
        }
        return match
    }

    private func install(_ profile: AppStoreConnectProfile) throws {
        guard let content = profile.profileContent, !content.isEmpty else {
            throw AppStoreProvisioningProfileError.profileContentUnavailable(profile.name)
        }
        let directory = DeveloperTeamService.installedProvisioningProfilesDirectory(
            homeDirectory: fileManager.homeDirectoryForCurrentUser
        )
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try content.write(
            to: directory.appendingPathComponent("\(Self.installedFilename(for: profile)).mobileprovision"),
            options: [.atomic]
        )
    }

    static func installedFilename(for profile: AppStoreConnectProfile) -> String {
        profile.uuid
            ?? profile.profileContent
                .flatMap(DeveloperTeamService.decodedProvisioningProfileContent)
                .flatMap(DeveloperTeamService.provisioningProfileRecord(fromPropertyListData:))?
                .uuid
            ?? profile.id
    }

    static func bundleIDName(for identifier: String) -> String {
        "Development Management \(identifier)"
    }

    static func uniqueIdentifiers(_ bundleIdentifiers: [String]) -> [String] {
        var seen: Set<String> = []
        return bundleIdentifiers
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func uniqueTargets(
        _ targets: [AppStoreProvisioningTarget]
    ) -> [AppStoreProvisioningTarget] {
        var order: [String] = []
        var entitlementsByIdentifier: [String: Set<String>] = [:]
        for target in targets {
            let identifier = target.bundleIdentifier
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !identifier.isEmpty else { continue }
            if entitlementsByIdentifier[identifier] == nil {
                order.append(identifier)
            }
            entitlementsByIdentifier[identifier, default: []]
                .formUnion(DeveloperTeamService.canonicalProvisioningEntitlementKeys(
                    target.requiredEntitlementKeys
                ))
        }
        return order.map {
            AppStoreProvisioningTarget(
                bundleIdentifier: $0,
                requiredEntitlementKeys: entitlementsByIdentifier[$0] ?? []
            )
        }
    }

    static func installedAppStoreProfile(
        in profiles: [ProvisioningProfileRecord],
        bundleIdentifier: String,
        teamID: String,
        certificateSHA1: String,
        requiredEntitlementKeys: Set<String> = [],
        now: Date = Date()
    ) -> ProvisioningProfileRecord? {
        let required = DeveloperTeamService.canonicalProvisioningEntitlementKeys(
            requiredEntitlementKeys
        )
        return profiles.first { profile in
            profile.isAppStoreProfile
                && !profile.hasWildcardBundleIdentifier
                && profile.teamID == teamID
                && profile.bundleIdentifier == bundleIdentifier
                && profile.name?.isEmpty == false
                && profile.expirationDate.map { $0 > now } != false
                && profile.certificateSHA1Fingerprints.contains(certificateSHA1)
                && required.isSubset(of: DeveloperTeamService
                    .canonicalProvisioningEntitlementKeys(profile.entitlementKeys))
        }
    }

    static func reusableAccountProfile(
        in profiles: [AppStoreConnectProfile],
        bundleIdentifier: String,
        certificateID: String,
        requiredEntitlementKeys: Set<String> = [],
        now: Date = Date()
    ) -> AppStoreConnectProfile? {
        guard !bundleIdentifier.contains("*") else { return nil }
        return profiles.first { profile in
            profile.profileType == AppStoreConnectProfile.appStoreProfileType
                && profile.bundleIdentifier == bundleIdentifier
                && profile.isActive(at: now)
                && profile.certificateIDs.contains(certificateID)
                && profile.profileContent?.isEmpty == false
                && missingEntitlementKeys(
                    requiredEntitlementKeys,
                    inProfileContent: profile.profileContent
                ).isEmpty
        }
    }

    static func missingEntitlementKeys(
        _ required: Set<String>,
        inProfileContent content: Data?
    ) -> Set<String> {
        let canonicalRequired = DeveloperTeamService.canonicalProvisioningEntitlementKeys(
            required
        )
        guard !canonicalRequired.isEmpty else { return [] }
        guard let content,
              let record = DeveloperTeamService.provisioningProfileRecord(
                fromProfileContent: content
              )
        else {
            return canonicalRequired
        }
        return canonicalRequired.subtracting(
            DeveloperTeamService.canonicalProvisioningEntitlementKeys(record.entitlementKeys)
        )
    }

    static func matchingCertificateID(
        in certificates: [AppStoreConnectCertificate],
        sha1Fingerprint: String
    ) -> String? {
        certificates.first {
            $0.certificateContent
                .map { DeveloperTeamService.sha1Fingerprint(ofCertificateData: $0) } == sha1Fingerprint
        }?.id
    }

    /// Creating a profile whose name already exists fails, and Development Management
    /// must not delete profiles it did not create, so collisions get a unique suffix.
    static func profileName(bundleIdentifier: String, existingNames: Set<String>) -> String {
        let base = "Development Management App Store \(bundleIdentifier)"
        guard existingNames.contains(base) else { return base }
        var candidate = base
        var suffix = 2
        while existingNames.contains(candidate) {
            candidate = "\(base) \(suffix)"
            suffix += 1
        }
        return candidate
    }
}
