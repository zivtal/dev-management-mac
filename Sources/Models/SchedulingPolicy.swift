import Foundation

enum SchedulingPolicy {
    static let expirationLeadDays = 3

    static func isDue(
        lastInstalledAt: Date?,
        profileExpirationDate: Date? = nil,
        now: Date = Date(),
        intervalDays: Int
    ) -> Bool {
        guard let lastInstalledAt else { return true }
        let interval = TimeInterval(max(1, intervalDays)) * 24 * 60 * 60
        if now.timeIntervalSince(lastInstalledAt) >= interval {
            return true
        }

        guard let renewalDate = profileRenewalDate(for: profileExpirationDate) else {
            return false
        }
        return now >= renewalDate && lastInstalledAt < renewalDate
    }

    static func nextInstallationDate(
        lastInstalledAt: Date?,
        profileExpirationDate: Date? = nil,
        intervalDays: Int
    ) -> Date? {
        guard let lastInstalledAt else { return nil }
        let intervalDate = lastInstalledAt.addingTimeInterval(
            TimeInterval(max(1, intervalDays)) * 24 * 60 * 60
        )
        guard let renewalDate = profileRenewalDate(for: profileExpirationDate),
              lastInstalledAt < renewalDate
        else {
            return intervalDate
        }
        return min(intervalDate, renewalDate)
    }

    static func profileRenewalDate(for expirationDate: Date?) -> Date? {
        expirationDate?.addingTimeInterval(
            -TimeInterval(expirationLeadDays) * 24 * 60 * 60
        )
    }

    static func installedApplicationIsOlder(
        _ installedApplication: InstalledApplication?,
        than projectVersion: ProjectVersion
    ) -> Bool {
        guard projectVersion.marketingVersion != nil || projectVersion.buildNumber != nil else {
            return false
        }
        guard let installedApplication else { return true }

        if let projectMarketingVersion = projectVersion.marketingVersion {
            guard let installedMarketingVersion = installedApplication.marketingVersion else {
                return true
            }
            let comparison = installedMarketingVersion.compare(
                projectMarketingVersion,
                options: [.numeric, .caseInsensitive]
            )
            if comparison != .orderedSame {
                return comparison == .orderedAscending
            }
        }

        if let projectBuildNumber = projectVersion.buildNumber {
            guard let installedBuildNumber = installedApplication.buildNumber else {
                return true
            }
            return installedBuildNumber.compare(
                projectBuildNumber,
                options: [.numeric, .caseInsensitive]
            ) == .orderedAscending
        }

        return false
    }
}
