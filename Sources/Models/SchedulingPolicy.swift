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
}
