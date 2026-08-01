import Foundation

enum SchedulingPolicy {
    static func isDue(lastInstalledAt: Date?, now: Date = Date(), intervalDays: Int) -> Bool {
        guard let lastInstalledAt else { return true }
        let interval = TimeInterval(max(1, intervalDays)) * 24 * 60 * 60
        return now.timeIntervalSince(lastInstalledAt) >= interval
    }

    static func nextInstallationDate(lastInstalledAt: Date?, intervalDays: Int) -> Date? {
        guard let lastInstalledAt else { return nil }
        return lastInstalledAt.addingTimeInterval(TimeInterval(max(1, intervalDays)) * 24 * 60 * 60)
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
