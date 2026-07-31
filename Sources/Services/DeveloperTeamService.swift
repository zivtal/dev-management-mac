import Foundation
import Security

struct SigningCertificateRecord: Equatable {
    let commonName: String
    let organizationalUnit: String
    let organizationName: String?
}

final class DeveloperTeamService {
    func availableTeams() -> [DeveloperTeam] {
        Self.teams(from: signingCertificateRecords())
    }

    static func teams(from records: [SigningCertificateRecord]) -> [DeveloperTeam] {
        let validPrefixes = ["Apple Development:", "iPhone Developer:"]
        var teamsByID: [String: DeveloperTeam] = [:]

        for record in records where validPrefixes.contains(where: record.commonName.hasPrefix) {
            let teamID = record.organizationalUnit.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !teamID.isEmpty else { continue }

            let accountName = accountName(fromCertificateCommonName: record.commonName)
            let candidate = DeveloperTeam(
                id: teamID,
                organizationName: record.organizationName,
                accountName: accountName
            )

            if let existing = teamsByID[teamID] {
                let existingHasOrganization = existing.organizationName?.isEmpty == false
                let candidateHasOrganization = candidate.organizationName?.isEmpty == false
                if !existingHasOrganization && candidateHasOrganization {
                    teamsByID[teamID] = candidate
                }
            } else {
                teamsByID[teamID] = candidate
            }
        }

        return teamsByID.values.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
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
    }

    private func commonName(of certificate: SecCertificate) -> String? {
        var value: CFString?
        guard SecCertificateCopyCommonName(certificate, &value) == errSecSuccess else { return nil }
        return value as String?
    }

    private func subjectValue(_ oid: CFString, certificate: SecCertificate) -> String? {
        guard let values = SecCertificateCopyValues(certificate, [oid] as CFArray, nil) as NSDictionary?,
              let property = values[oid] as? NSDictionary,
              let value = property[kSecPropertyKeyValue] as? String
        else {
            return nil
        }
        return value
    }
}
