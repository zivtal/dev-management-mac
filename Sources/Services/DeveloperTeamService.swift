import Foundation
import Security

struct SigningCertificateRecord: Equatable {
    let commonName: String
    let organizationalUnit: String
    let organizationName: String?
}

struct ProvisioningProfileRecord: Equatable {
    let teamID: String
    let teamName: String?
    let bundleIdentifier: String?
    let expirationDate: Date?
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

    static func hasDistributionSigningIdentity(
        certificateRecords: [SigningCertificateRecord],
        teamID: String?
    ) -> Bool {
        let normalizedTeamID = teamID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["Apple Distribution:", "iPhone Distribution:"]
        return certificateRecords.contains { record in
            prefixes.contains(where: record.commonName.hasPrefix)
                && (normalizedTeamID?.isEmpty != false
                    || record.organizationalUnit == normalizedTeamID)
        }
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
            organizationName: subjectValue(kSecOIDOrganizationName, certificate: certificate)
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

        return ProvisioningProfileRecord(
            teamID: teamID,
            teamName: dictionary["TeamName"] as? String,
            bundleIdentifier: bundleIdentifier,
            expirationDate: dictionary["ExpirationDate"] as? Date
        )
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
            guard let propertyListData = decodedProvisioningProfileContent(data) else {
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
                )
            )
        }
    }

    private func provisioningProfileRecords() -> [ProvisioningProfileRecord] {
        let homeDirectory = fileManagerHomeDirectory
        let directories = [
            homeDirectory.appendingPathComponent(
                "Library/Developer/Xcode/UserData/Provisioning Profiles",
                isDirectory: true
            ),
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
                  let propertyListData = decodedProvisioningProfileContent(data)
            else {
                return nil
            }
            return Self.provisioningProfileRecord(fromPropertyListData: propertyListData)
        }
    }

    private var fileManagerHomeDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    private func decodedProvisioningProfileContent(_ data: Data) -> Data? {
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
