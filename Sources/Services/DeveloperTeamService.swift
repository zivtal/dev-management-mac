import CryptoKit
import Foundation
import Security

struct SigningCertificateRecord: Equatable {
    let commonName: String
    let organizationalUnit: String
    let organizationName: String?
    /// Uppercase hexadecimal SHA-1 of the DER certificate, matching the value
    /// `security find-identity` prints and `exportOptionsPlist` expects for
    /// `signingCertificate`. Nil when the record was built from parsed subject
    /// components instead of a certificate.
    let sha1Fingerprint: String?
    /// Expiry of the certificate. A keychain routinely holds several certificates
    /// sharing one common name, only one of which is still valid.
    let expirationDate: Date?

    init(
        commonName: String,
        organizationalUnit: String,
        organizationName: String?,
        sha1Fingerprint: String? = nil,
        expirationDate: Date? = nil
    ) {
        self.commonName = commonName
        self.organizationalUnit = organizationalUnit
        self.organizationName = organizationName
        self.sha1Fingerprint = sha1Fingerprint
        self.expirationDate = expirationDate
    }

    func isValid(at date: Date) -> Bool {
        expirationDate.map { $0 > date } != false
    }
}

struct ProvisioningProfileRecord: Equatable {
    let teamID: String
    let teamName: String?
    let bundleIdentifier: String?
    let expirationDate: Date?
    let uuid: String?
    let name: String?
    /// Uppercase SHA-1 fingerprints of the certificates the profile authorizes.
    let certificateSHA1Fingerprints: [String]
    /// App Store profiles carry no `ProvisionedDevices` list; development and
    /// ad-hoc profiles always do.
    let hasProvisionedDevices: Bool
    /// Set on enterprise in-house profiles, which also carry no device list.
    let provisionsAllDevices: Bool
    /// `beta-reports-active` is present and true only on App Store profiles.
    let isBetaReportsActive: Bool
    /// Entitlements authorized by this exact profile. Profile reuse must cover the
    /// archived bundle's capabilities; matching only its identifier and certificate
    /// can select a profile created before a capability such as Push was enabled.
    let entitlementKeys: Set<String>

    init(
        teamID: String,
        teamName: String?,
        bundleIdentifier: String?,
        expirationDate: Date?,
        uuid: String? = nil,
        name: String? = nil,
        certificateSHA1Fingerprints: [String] = [],
        hasProvisionedDevices: Bool = false,
        provisionsAllDevices: Bool = false,
        isBetaReportsActive: Bool = false,
        entitlementKeys: Set<String> = []
    ) {
        self.teamID = teamID
        self.teamName = teamName
        self.bundleIdentifier = bundleIdentifier
        self.expirationDate = expirationDate
        self.uuid = uuid
        self.name = name
        self.certificateSHA1Fingerprints = certificateSHA1Fingerprints
        self.hasProvisionedDevices = hasProvisionedDevices
        self.provisionsAllDevices = provisionsAllDevices
        self.isBetaReportsActive = isBetaReportsActive
        self.entitlementKeys = entitlementKeys
    }

    /// The absence of a device list is not enough on its own: enterprise in-house
    /// profiles have no device list either, and signing an App Store upload with one
    /// produces an IPA Apple rejects. `beta-reports-active` is what actually marks a
    /// profile as App Store.
    var isAppStoreProfile: Bool {
        !hasProvisionedDevices && !provisionsAllDevices && isBetaReportsActive
    }

    /// Wildcard identifiers such as `com.example.*` cannot back an App Store profile
    /// for a concrete bundle, so they are never reused for one.
    var hasWildcardBundleIdentifier: Bool {
        bundleIdentifier?.contains("*") == true
    }
}

/// A locally usable Apple Distribution identity: a certificate whose private key
/// is present in one of the search-list keychains.
struct DistributionSigningIdentity: Equatable, Sendable {
    let teamID: String
    let commonName: String
    let sha1Fingerprint: String
}

final class DeveloperTeamService {
    func availableTeams() -> [DeveloperTeam] {
        Self.teams(
            from: signingCertificateRecords(),
            provisioningProfiles: provisioningProfileRecords()
        )
    }

    func recommendedTeamID(for bundleIdentifier: String?) -> String? {
        let certificateRecords = signingCertificateRecords()
        let provisioningProfiles = provisioningProfileRecords()
        if let matchingTeamID = Self.recommendedTeamID(
            for: bundleIdentifier,
            provisioningProfiles: provisioningProfiles
        ) {
            return matchingTeamID
        }

        let availableTeams = Self.teams(
            from: certificateRecords,
            provisioningProfiles: provisioningProfiles
        )
        return availableTeams.count == 1 ? availableTeams[0].id : nil
    }

    func hasDistributionSigningIdentity(teamID: String?) -> Bool {
        Self.hasDistributionSigningIdentity(
            certificateRecords: signingCertificateRecords(),
            teamID: teamID
        )
    }

    /// The Apple Distribution identity usable for manual App Store export, or nil
    /// when no matching certificate has its private key in the keychain.
    func distributionSigningIdentity(teamID: String?) -> DistributionSigningIdentity? {
        distributionSigningIdentities(teamID: teamID).first
    }

    /// Every locally usable identity, newest expiry first. Provisioning checks each
    /// one against the App Store Connect account: a revoked renewal must not hide an
    /// older identity that is still active there.
    func distributionSigningIdentities(teamID: String?) -> [DistributionSigningIdentity] {
        Self.distributionSigningIdentities(
            certificateRecords: signingCertificateRecords(),
            teamID: teamID
        )
    }

    static let distributionCertificatePrefixes = ["Apple Distribution:", "iPhone Distribution:"]

    static func hasDistributionSigningIdentity(
        certificateRecords: [SigningCertificateRecord],
        teamID: String?
    ) -> Bool {
        !distributionCertificateRecords(
            certificateRecords: certificateRecords,
            teamID: teamID
        ).isEmpty
    }

    static func distributionCertificateRecords(
        certificateRecords: [SigningCertificateRecord],
        teamID: String?
    ) -> [SigningCertificateRecord] {
        let normalizedTeamID = teamID?.trimmingCharacters(in: .whitespacesAndNewlines)
        return certificateRecords.filter { record in
            distributionCertificatePrefixes.contains(where: record.commonName.hasPrefix)
                && (normalizedTeamID?.isEmpty != false
                    || record.organizationalUnit == normalizedTeamID)
        }
    }

    /// Manual export pins one exact certificate, so only a record that carries a
    /// SHA-1 fingerprint can back a `DistributionSigningIdentity`.
    ///
    /// A keychain commonly holds several certificates with the same common name —
    /// renewals accumulate — so expired ones are rejected and the longest-lived
    /// remaining certificate wins. Pinning an expired hash would fail the export.
    static func distributionSigningIdentity(
        certificateRecords: [SigningCertificateRecord],
        teamID: String?,
        now: Date = Date()
    ) -> DistributionSigningIdentity? {
        distributionSigningIdentities(
            certificateRecords: certificateRecords,
            teamID: teamID,
            now: now
        ).first
    }

    static func distributionSigningIdentities(
        certificateRecords: [SigningCertificateRecord],
        teamID: String?,
        now: Date = Date()
    ) -> [DistributionSigningIdentity] {
        let candidates = distributionCertificateRecords(
            certificateRecords: certificateRecords,
            teamID: teamID
        )
        .filter { $0.sha1Fingerprint?.isEmpty == false && $0.isValid(at: now) }
        .sorted { left, right in
            (left.expirationDate ?? .distantFuture) > (right.expirationDate ?? .distantFuture)
        }
        return candidates.compactMap { match in
            guard let fingerprint = match.sha1Fingerprint else { return nil }
            return DistributionSigningIdentity(
                teamID: match.organizationalUnit,
                commonName: match.commonName,
                sha1Fingerprint: fingerprint
            )
        }
    }

    static func sha1Fingerprint(ofCertificateData data: Data) -> String {
        Insecure.SHA1.hash(data: data)
            .map { String(format: "%02X", $0) }
            .joined()
    }

    static func signingCertificateRecord(
        certificateData: Data
    ) -> SigningCertificateRecord? {
        guard let certificate = SecCertificateCreateWithData(nil, certificateData as CFData),
              let commonName = commonName(of: certificate),
              let organizationalUnit = subjectValue(
                kSecOIDOrganizationalUnitName,
                certificate: certificate
              )
        else {
            return nil
        }
        return SigningCertificateRecord(
            commonName: commonName,
            organizationalUnit: organizationalUnit,
            organizationName: subjectValue(kSecOIDOrganizationName, certificate: certificate),
            sha1Fingerprint: sha1Fingerprint(ofCertificateData: certificateData)
        )
    }

    static func teams(from records: [SigningCertificateRecord]) -> [DeveloperTeam] {
        teams(from: records, provisioningProfiles: [])
    }

    static func teams(
        from certificateRecords: [SigningCertificateRecord],
        provisioningProfiles: [ProvisioningProfileRecord],
        now: Date = Date()
    ) -> [DeveloperTeam] {
        let validPrefixes = ["Apple Development:", "iPhone Developer:"]
        var teamsByID: [String: DeveloperTeam] = [:]

        for profile in provisioningProfiles where profile.expirationDate.map({ $0 > now }) != false {
            let teamID = profile.teamID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !teamID.isEmpty else { continue }
            if teamsByID[teamID]?.organizationName?.isEmpty != false {
                teamsByID[teamID] = DeveloperTeam(
                    id: teamID,
                    organizationName: profile.teamName,
                    accountName: nil
                )
            }
        }

        for record in certificateRecords where validPrefixes.contains(where: record.commonName.hasPrefix) {
            let teamID = record.organizationalUnit.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !teamID.isEmpty else { continue }

            let accountName = accountName(fromCertificateCommonName: record.commonName)
            let candidate = DeveloperTeam(
                id: teamID,
                organizationName: record.organizationName,
                accountName: accountName
            )

            if let existing = teamsByID[teamID] {
                teamsByID[teamID] = DeveloperTeam(
                    id: teamID,
                    organizationName: candidate.organizationName?.isEmpty == false
                        ? candidate.organizationName
                        : existing.organizationName,
                    accountName: candidate.accountName?.isEmpty == false
                        ? candidate.accountName
                        : existing.accountName
                )
            } else {
                teamsByID[teamID] = candidate
            }
        }

        return teamsByID.values.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    static func recommendedTeamID(
        for bundleIdentifier: String?,
        provisioningProfiles: [ProvisioningProfileRecord],
        now: Date = Date()
    ) -> String? {
        guard let bundleIdentifier = normalizedBundleIdentifier(bundleIdentifier) else { return nil }
        let requestedComponents = bundleIdentifier.split(separator: ".").map(String.init)
        var bestScoresByTeamID: [String: Int] = [:]

        for profile in provisioningProfiles where profile.expirationDate.map({ $0 > now }) != false {
            guard let profileBundleIdentifier = normalizedBundleIdentifier(profile.bundleIdentifier) else {
                continue
            }
            let isWildcard = profileBundleIdentifier.hasSuffix(".*")
            let comparableProfileIdentifier = isWildcard
                ? String(profileBundleIdentifier.dropLast(2))
                : profileBundleIdentifier
            let profileComponents = comparableProfileIdentifier.split(separator: ".").map(String.init)
            let commonComponentCount = zip(requestedComponents, profileComponents)
                .prefix { $0.0 == $0.1 }
                .count
            guard commonComponentCount >= 2 else { continue }

            let score: Int
            if comparableProfileIdentifier.caseInsensitiveCompare(bundleIdentifier) == .orderedSame {
                score = 10_000 + commonComponentCount
            } else if isWildcard, commonComponentCount == profileComponents.count {
                score = 5_000 + commonComponentCount
            } else {
                score = commonComponentCount
            }
            bestScoresByTeamID[profile.teamID] = max(bestScoresByTeamID[profile.teamID] ?? 0, score)
        }

        guard let bestScore = bestScoresByTeamID.values.max() else { return nil }
        let matchingTeamIDs = bestScoresByTeamID.compactMap { teamID, score in
            score == bestScore ? teamID : nil
        }
        return matchingTeamIDs.count == 1 ? matchingTeamIDs[0] : nil
    }

    static func provisioningProfileRecord(fromPropertyListData data: Data) -> ProvisioningProfileRecord? {
        guard let propertyList = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = propertyList as? [String: Any],
              let teamID = (dictionary["TeamIdentifier"] as? [String])?.first?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !teamID.isEmpty
        else {
            return nil
        }

        let entitlements = dictionary["Entitlements"] as? [String: Any]
        let applicationIdentifier = entitlements?["application-identifier"] as? String
        let identifierPrefix = "\(teamID)."
        let bundleIdentifier: String?
        if let applicationIdentifier, applicationIdentifier.hasPrefix(identifierPrefix) {
            bundleIdentifier = String(applicationIdentifier.dropFirst(identifierPrefix.count))
        } else {
            bundleIdentifier = applicationIdentifier
        }

        let certificateFingerprints = (dictionary["DeveloperCertificates"] as? [Data] ?? [])
            .map { sha1Fingerprint(ofCertificateData: $0) }

        return ProvisioningProfileRecord(
            teamID: teamID,
            teamName: dictionary["TeamName"] as? String,
            bundleIdentifier: bundleIdentifier,
            expirationDate: dictionary["ExpirationDate"] as? Date,
            uuid: dictionary["UUID"] as? String,
            name: dictionary["Name"] as? String,
            certificateSHA1Fingerprints: certificateFingerprints,
            hasProvisionedDevices: (dictionary["ProvisionedDevices"] as? [String])?.isEmpty == false,
            provisionsAllDevices: dictionary["ProvisionsAllDevices"] as? Bool == true,
            isBetaReportsActive: entitlements?["beta-reports-active"] as? Bool == true,
            entitlementKeys: canonicalProvisioningEntitlementKeys(
                entitlements?.keys.map { $0 } ?? []
            )
        )
    }

    /// Xcode 26 emits the executable Push entitlement with the namespaced spelling,
    /// while Apple's provisioning profiles continue to authorize `aps-environment`.
    /// Treat both as the same capability before comparing archive and profile data.
    static func canonicalProvisioningEntitlementKey(_ key: String) -> String {
        switch key {
        case "com.apple.developer.aps-environment":
            return "aps-environment"
        default:
            return key
        }
    }

    static func canonicalProvisioningEntitlementKeys<S: Sequence>(
        _ keys: S
    ) -> Set<String> where S.Element == String {
        Set(keys.map(canonicalProvisioningEntitlementKey))
    }

    /// Accepts either a decoded profile plist (useful to callers and tests) or the
    /// CMS-wrapped profile content returned by App Store Connect.
    static func provisioningProfileRecord(fromProfileContent data: Data) -> ProvisioningProfileRecord? {
        if let record = provisioningProfileRecord(fromPropertyListData: data) {
            return record
        }
        guard let propertyListData = decodedProvisioningProfileContent(data) else { return nil }
        return provisioningProfileRecord(fromPropertyListData: propertyListData)
    }

    static func provisioningProfileExpirationDate(fromPropertyListData data: Data) -> Date? {
        guard let propertyList = try? PropertyListSerialization.propertyList(
            from: data,
            format: nil
        ),
        let dictionary = propertyList as? [String: Any]
        else {
            return nil
        }
        return dictionary["ExpirationDate"] as? Date
    }

    func provisioningProfileExpirationDate(in applicationURL: URL) -> Date? {
        let candidateURLs = [
            applicationURL.appendingPathComponent("embedded.mobileprovision"),
            applicationURL.appendingPathComponent("Contents/embedded.provisionprofile")
        ]

        for profileURL in candidateURLs {
            guard let data = try? Data(contentsOf: profileURL) else { continue }
            if let expirationDate = Self.provisioningProfileExpirationDate(
                fromPropertyListData: data
            ) {
                return expirationDate
            }
            guard let propertyListData = Self.decodedProvisioningProfileContent(data) else {
                continue
            }
            if let expirationDate = Self.provisioningProfileExpirationDate(
                fromPropertyListData: propertyListData
            ) {
                return expirationDate
            }
        }
        return nil
    }

    private static func accountName(fromCertificateCommonName commonName: String) -> String? {
        let prefixes = ["Apple Development:", "iPhone Developer:"]
        guard let prefix = prefixes.first(where: commonName.hasPrefix) else { return nil }

        var name = String(commonName.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let suffixStart = name.range(of: " (", options: .backwards), name.hasSuffix(")") {
            name.removeSubrange(suffixStart.lowerBound..<name.endIndex)
        }
        return name.isEmpty ? nil : name
    }

    private func signingCertificateRecords() -> [SigningCertificateRecord] {
        let query: [CFString: Any] = [
            kSecClass: kSecClassIdentity,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecReturnRef: true
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let identities = result as? [SecIdentity]
        else {
            return []
        }

        return identities.compactMap { identity in
            var certificate: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
                  let certificate,
                  let commonName = Self.commonName(of: certificate),
                  let organizationalUnit = Self.subjectValue(
                    kSecOIDOrganizationalUnitName,
                    certificate: certificate
                  )
            else {
                return nil
            }

            return SigningCertificateRecord(
                commonName: commonName,
                organizationalUnit: organizationalUnit,
                organizationName: Self.subjectValue(
                    kSecOIDOrganizationName,
                    certificate: certificate
                ),
                sha1Fingerprint: Self.sha1Fingerprint(
                    ofCertificateData: SecCertificateCopyData(certificate) as Data
                ),
                expirationDate: Self.expirationDate(of: certificate)
            )
        }
    }

    /// Reads the certificate's notAfter date. Security reports it as a
    /// `CFAbsoluteTime`, which is seconds since 2001-01-01, not since the epoch.
    static func expirationDate(of certificate: SecCertificate) -> Date? {
        guard let values = SecCertificateCopyValues(
            certificate,
            [kSecOIDX509V1ValidityNotAfter] as CFArray,
            nil
        ) as? [String: Any],
              let entry = values[kSecOIDX509V1ValidityNotAfter as String] as? [String: Any],
              let rawValue = entry[kSecPropertyKeyValue as String]
        else {
            return nil
        }
        if let date = rawValue as? Date {
            return date
        }
        if let interval = rawValue as? Double {
            return Date(timeIntervalSinceReferenceDate: interval)
        }
        if let number = rawValue as? NSNumber {
            return Date(timeIntervalSinceReferenceDate: number.doubleValue)
        }
        return nil
    }

    /// Where Xcode 14+ looks for installed profiles. Newly created profiles are
    /// written here so `xcodebuild -exportArchive` can resolve them by name.
    static func installedProvisioningProfilesDirectory(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory.appendingPathComponent(
            "Library/Developer/Xcode/UserData/Provisioning Profiles",
            isDirectory: true
        )
    }

    func provisioningProfileRecords() -> [ProvisioningProfileRecord] {
        let homeDirectory = fileManagerHomeDirectory
        let directories = [
            Self.installedProvisioningProfilesDirectory(homeDirectory: homeDirectory),
            homeDirectory.appendingPathComponent(
                "Library/MobileDevice/Provisioning Profiles",
                isDirectory: true
            )
        ]
        var seenURLs: Set<URL> = []

        return directories.flatMap { directory in
            (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
        }
        .filter { ["mobileprovision", "provisionprofile"].contains($0.pathExtension.lowercased()) }
        .filter { seenURLs.insert($0.standardizedFileURL).inserted }
        .compactMap { profileURL in
            guard let data = try? Data(contentsOf: profileURL),
                  let propertyListData = Self.decodedProvisioningProfileContent(data)
            else {
                return nil
            }
            return Self.provisioningProfileRecord(fromPropertyListData: propertyListData)
        }
    }

    private var fileManagerHomeDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    static func decodedProvisioningProfileContent(_ data: Data) -> Data? {
        var decoder: CMSDecoder?
        guard CMSDecoderCreate(&decoder) == errSecSuccess, let decoder else { return nil }

        let updateStatus = data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return errSecParam }
            return CMSDecoderUpdateMessage(decoder, baseAddress, data.count)
        }
        guard updateStatus == errSecSuccess,
              CMSDecoderFinalizeMessage(decoder) == errSecSuccess
        else {
            return nil
        }

        var content: CFData?
        guard CMSDecoderCopyContent(decoder, &content) == errSecSuccess,
              let content
        else {
            return nil
        }
        return content as Data
    }

    private static func normalizedBundleIdentifier(_ bundleIdentifier: String?) -> String? {
        guard let value = bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !value.isEmpty
        else {
            return nil
        }
        return value
    }

    private static func commonName(of certificate: SecCertificate) -> String? {
        var value: CFString?
        guard SecCertificateCopyCommonName(certificate, &value) == errSecSuccess else { return nil }
        return value as String?
    }

    private static func subjectValue(_ oid: CFString, certificate: SecCertificate) -> String? {
        guard let values = SecCertificateCopyValues(
            certificate,
            [kSecOIDX509V1SubjectName] as CFArray,
            nil
        ) as? [String: Any],
              let subject = values[kSecOIDX509V1SubjectName as String] as? [String: Any],
              let components = subject[kSecPropertyKeyValue as String] as? [[String: Any]]
        else {
            return nil
        }
        return certificateSubjectValue(oid as String, components: components)
    }

    static func certificateSubjectValue(
        _ oid: String,
        components: [[String: Any]]
    ) -> String? {
        components.first(where: {
            ($0[kSecPropertyKeyLabel as String] as? String) == oid
        })?[kSecPropertyKeyValue as String] as? String
    }
}
