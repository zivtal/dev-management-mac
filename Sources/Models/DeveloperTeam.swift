import Foundation

struct DeveloperTeam: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    let organizationName: String?
    let accountName: String?

    var displayName: String {
        let organization = organizationName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = accountName?.trimmingCharacters(in: .whitespacesAndNewlines)

        if let organization, !organization.isEmpty,
           let account, !account.isEmpty,
           organization.localizedCaseInsensitiveCompare(account) != .orderedSame {
            return "\(organization) — \(account) (\(id))"
        }
        if let organization, !organization.isEmpty {
            return "\(organization) (\(id))"
        }
        if let account, !account.isEmpty {
            return "\(account) (\(id))"
        }
        return id
    }
}
