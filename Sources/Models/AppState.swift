import Foundation

struct AppPreferences: Codable, Equatable {
    var automationEnabled = true
    var reinstallAfterDays = 3
    var launchAtLogin = true
    var pollIntervalSeconds = 300
    var notificationsEnabled: Bool? = true
    // Retained only to migrate the former global device exclusions into each project.
    var excludedDeviceUDIDs: Set<String>?
    var openAIModel: String?
    var appStoreConnectIssuerID: String?
    var appStoreConnectKeyID: String?
    var appStoreConnectCredentialProfiles: [AppStoreConnectCredentialProfile]?
    var appStorePrivacyAppleID: String?
    var appStorePrivacyTeamID: String?
    var appStoreLocale: String?
    var appStoreCopyright: String?
    var appStoreSupportURL: String?
    var appStoreReviewFirstName: String?
    var appStoreReviewLastName: String?
    var appStoreReviewPhone: String?
    var appStoreReviewEmail: String?
    var appStoreReviewNotes: String?
    var appStoreReviewDemoAccountRequired: Bool?
    var appStoreReleaseAutomatically: Bool?
}

struct InstallationRecord: Codable, Equatable, Identifiable {
    var id: String { "\(projectID.uuidString)|\(deviceUDID)" }
    let projectID: UUID
    let deviceUDID: String
    var installedAt: Date
    var installedVersion: String?
    var profileExpirationDate: Date? = nil
    var profileExpirationWasChecked: Bool? = nil
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
    enum Phase: Equatable, Sendable {
        case preparing
        case building
        case packaging
        case stopping
        case installing
        case launching
    }

    let projectName: String
    let deviceName: String
    var phase: Phase
    var latestOutput: String

    var phaseTitle: String {
        switch phase {
        case .preparing: L10n.text("Preparing installation…")
        case .building: L10n.text("Building the application…")
        case .packaging: L10n.text("Creating the DMG…")
        case .stopping: L10n.text("Stopping the running application…")
        case .installing: L10n.text("Installing the application…")
        case .launching: L10n.text("Launching the application…")
        }
    }
}

struct InstallationLogSession: Equatable, Identifiable {
    private static let outputLimit = 30_000

    enum State: Equatable {
        case inProgress
        case succeeded
        case failed
        case cancelled
    }

    let id: UUID
    let projectName: String
    let deviceName: String
    let startedAt: Date
    var finishedAt: Date?
    var phase: InstallationProgress.Phase
    var state: State
    private(set) var output: String
    private(set) var revision: Int

    init(
        id: UUID = UUID(),
        projectName: String,
        deviceName: String,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        phase: InstallationProgress.Phase = .preparing,
        state: State = .inProgress,
        output: String = ""
    ) {
        self.id = id
        self.projectName = projectName
        self.deviceName = deviceName
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.phase = phase
        self.state = state
        self.output = output
        revision = 0
    }

    mutating func append(_ text: String) {
        guard !text.isEmpty else { return }
        output.append(text)
        output = Self.limitedOutput(output)
        revision += 1
    }

    mutating func replaceOutput(with text: String) {
        let replacement = Self.limitedOutput(text)
        guard output != replacement else { return }
        output = replacement
        revision += 1
    }

    var latestOutputLine: String {
        output
            .split(whereSeparator: \Character.isNewline)
            .last
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func elapsedTime(at now: Date = Date()) -> TimeInterval {
        max(0, (finishedAt ?? now).timeIntervalSince(startedAt))
    }

    var statusTitle: String {
        switch state {
        case .inProgress:
            phase.title
        case .succeeded:
            L10n.text("Installation completed successfully")
        case .failed:
            L10n.text("Installation failed")
        case .cancelled:
            L10n.text("Installation canceled")
        }
    }

    private static func limitedOutput(_ output: String) -> String {
        guard output.count > outputLimit else { return output }
        return "…\n" + String(output.suffix(outputLimit))
    }
}

private extension InstallationProgress.Phase {
    var title: String {
        switch self {
        case .preparing:
            L10n.text("Preparing installation…")
        case .building:
            L10n.text("Building the application…")
        case .packaging:
            L10n.text("Creating the DMG…")
        case .stopping:
            L10n.text("Stopping the running application…")
        case .installing:
            L10n.text("Installing the application…")
        case .launching:
            L10n.text("Launching the application…")
        }
    }
}
