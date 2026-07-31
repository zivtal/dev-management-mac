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

struct InstallationLogSession: Equatable, Identifiable {
    enum State: Equatable {
        case inProgress
        case succeeded
        case failed
    }

    let id: UUID
    let projectName: String
    let deviceName: String
    let startedAt: Date
    var phase: InstallationProgress.Phase
    var state: State
    private(set) var output: String
    private(set) var revision: Int

    init(
        id: UUID = UUID(),
        projectName: String,
        deviceName: String,
        startedAt: Date = Date(),
        phase: InstallationProgress.Phase = .preparing,
        state: State = .inProgress,
        output: String = ""
    ) {
        self.id = id
        self.projectName = projectName
        self.deviceName = deviceName
        self.startedAt = startedAt
        self.phase = phase
        self.state = state
        self.output = output
        revision = 0
    }

    mutating func append(_ text: String) {
        guard !text.isEmpty else { return }
        output.append(text)
        revision += 1
    }

    var latestOutputLine: String {
        output
            .split(whereSeparator: \Character.isNewline)
            .last
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var statusTitle: String {
        switch state {
        case .inProgress:
            phase.title
        case .succeeded:
            L10n.text("Installation completed successfully")
        case .failed:
            L10n.text("Installation failed")
        }
    }
}

private extension InstallationProgress.Phase {
    var title: String {
        switch self {
        case .preparing:
            L10n.text("Preparing installation…")
        case .building:
            L10n.text("Building the application…")
        case .installing:
            L10n.text("Installing on iPhone…")
        }
    }
}
