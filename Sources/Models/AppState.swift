import Foundation

struct AppPreferences: Codable, Equatable {
    var automationEnabled = true
    var reinstallAfterDays = 3
    var launchAtLogin = true
    var pollIntervalSeconds = 300
    var notificationsEnabled: Bool? = true
    // Retained only to migrate the former global device exclusions into each project.
    var excludedDeviceUDIDs: Set<String>?
}

struct InstallationRecord: Codable, Equatable, Identifiable {
    var id: String { "\(projectID.uuidString)|\(deviceUDID)" }
    let projectID: UUID
    let deviceUDID: String
    var installedAt: Date
    var installedVersion: String?
}

extension Sequence where Element == InstallationRecord {
    func installedDeviceCount(for projectID: UUID) -> Int {
        Set(
            lazy
                .filter { $0.projectID == projectID }
                .map(\.deviceUDID)
        ).count
    }
}

enum ActivityLevel: String, Codable {
    case info
    case success
    case warning
    case error
}

struct ActivityEntry: Codable, Equatable, Identifiable {
    let id: UUID
    let date: Date
    let level: ActivityLevel
    let title: String
    let details: String?
    let projectID: UUID?
    let deviceUDID: String?

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        level: ActivityLevel,
        title: String,
        details: String? = nil,
        projectID: UUID? = nil,
        deviceUDID: String? = nil
    ) {
        self.id = id
        self.date = date
        self.level = level
        self.title = title
        self.details = details
        self.projectID = projectID
        self.deviceUDID = deviceUDID
    }
}

struct PersistedState: Codable, Equatable {
    var preferences: AppPreferences
    var projects: [ManagedProject]
    var installationRecords: [InstallationRecord]
    var activity: [ActivityEntry]
    var didApplyLaunchAtLoginDefault: Bool?

    static let empty = PersistedState(
        preferences: AppPreferences(),
        projects: [],
        installationRecords: [],
        activity: [],
        didApplyLaunchAtLoginDefault: nil
    )
}

struct InstallationProgress: Equatable {
    enum Phase: Equatable {
        case preparing
        case building
        case installing
    }

    let projectName: String
    let deviceName: String
    var phase: Phase
    var latestOutput: String

    var phaseTitle: String {
        switch phase {
        case .preparing: L10n.text("Preparing installation…")
        case .building: L10n.text("Building the application…")
        case .installing: L10n.text("Installing on iPhone…")
        }
    }
}
