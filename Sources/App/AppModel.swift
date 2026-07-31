import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var preferences: AppPreferences {
        didSet {
            persist()
            if !isLoading,
               (oldValue.reinstallAfterDays != preferences.reinstallAfterDays
                || oldValue.automationEnabled != preferences.automationEnabled) {
                restartMonitoring()
            }
            if !isLoading,
               oldValue.notificationsEnabled != preferences.notificationsEnabled,
               preferences.notificationsEnabled != false {
                notificationService.requestAuthorization()
            }
        }
    }
    @Published var projects: [ManagedProject] { didSet { persist() } }
    @Published private(set) var installationRecords: [InstallationRecord] { didSet { persist() } }
    @Published private(set) var activity: [ActivityEntry] { didSet { persist() } }
    @Published private(set) var connectedDevices: [ConnectedDevice] = []
    @Published private(set) var progress: InstallationProgress?
    @Published private(set) var isRefreshingDevices = false
    @Published private(set) var isDiscoveringProject = false
    @Published private(set) var pendingInstallAllCount = 0
    @Published private(set) var projectIconURLs: [UUID: URL] = [:]
    @Published var presentedError: String?

    var installableDevices: [ConnectedDevice] {
        connectedDevices.filter {
            $0.supportsIOSAppInstallation && preferences.installationEnabled(for: $0.udid)
        }
    }

    private let settingsStore: SettingsStore
    private let deviceService: DeviceService
    private let discoveryService: ProjectDiscoveryService
    private let installationService: InstallationService
    private let versionService: ProjectVersionService
    private let launchAtLoginService: LaunchAtLoginService
    private let usbConnectionMonitor: USBConnectionMonitor
    private let notificationService: NotificationService
    private let projectIconService: ProjectIconService
    private var monitoringTask: Task<Void, Never>?
    private var isLoading = true
    private var failedAttemptCooldowns: [String: Date] = [:]
    private var installAllProjectIDs: Set<UUID> = [] {
        didSet { pendingInstallAllCount = installAllProjectIDs.count }
    }
    private var installAllTargetDeviceUDIDs: Set<String> = []
    private var completedInstallAllTargets: Set<String> = []
    private var lastDeviceError: String?
    private var didApplyLaunchAtLoginDefault: Bool

    init(
        settingsStore: SettingsStore = SettingsStore(),
        deviceService: DeviceService = DeviceService(),
        discoveryService: ProjectDiscoveryService = ProjectDiscoveryService(),
        installationService: InstallationService = InstallationService(),
        versionService: ProjectVersionService = ProjectVersionService(),
        launchAtLoginService: LaunchAtLoginService = LaunchAtLoginService(),
        usbConnectionMonitor: USBConnectionMonitor = USBConnectionMonitor(),
        notificationService: NotificationService = NotificationService(),
        projectIconService: ProjectIconService = ProjectIconService()
    ) {
        self.settingsStore = settingsStore
        self.deviceService = deviceService
        self.discoveryService = discoveryService
        self.installationService = installationService
        self.versionService = versionService
        self.launchAtLoginService = launchAtLoginService
        self.usbConnectionMonitor = usbConnectionMonitor
        self.notificationService = notificationService
        self.projectIconService = projectIconService

        let savedState = settingsStore.load()
        var loadedPreferences = savedState.preferences
        if savedState.didApplyLaunchAtLoginDefault != true {
            loadedPreferences.launchAtLogin = true
        }
        preferences = loadedPreferences
        projects = savedState.projects
        installationRecords = savedState.installationRecords
        activity = savedState.activity
        didApplyLaunchAtLoginDefault = true
        isLoading = false

        usbConnectionMonitor.onConnectionChanged = { [weak self] in
            Task { @MainActor [weak self] in
                await self?.refreshDevices(installWhenDue: true)
            }
        }

        persist()
        Task { @MainActor [weak self] in
            await self?.refreshProjectIcons()
        }
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            if preferences.notificationsEnabled != false {
                notificationService.requestAuthorization()
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                self?.applyLaunchAtLoginPreferenceOnStartup()
            }
        }
    }

    deinit {
        monitoringTask?.cancel()
    }

    func startMonitoring() {
        guard monitoringTask == nil else { return }
        usbConnectionMonitor.start()
        monitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshDevices(installWhenDue: true)
                let seconds = self.nextMonitoringDelay()
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    func refreshNow() {
        Task { await refreshDevices(installWhenDue: true) }
    }

    func refreshDevices(installWhenDue: Bool) async {
        guard !isRefreshingDevices else { return }
        isRefreshingDevices = true
        defer { isRefreshingDevices = false }

        refreshProjectVersions()

        do {
            let devices = try await deviceService.availableDevices()
            connectedDevices = devices
            lastDeviceError = nil
            let appInstallableDevices = installableDevices
            if !installAllProjectIDs.isEmpty, !appInstallableDevices.isEmpty {
                if installAllTargetDeviceUDIDs.isEmpty {
                    installAllTargetDeviceUDIDs = Set(appInstallableDevices.map(\.udid))
                }
                let requestedDevices = appInstallableDevices.filter {
                    installAllTargetDeviceUDIDs.contains($0.udid)
                }
                await installAllRequestedProjects(on: requestedDevices)
            } else if installWhenDue, preferences.automationEnabled {
                await installDueProjects(on: appInstallableDevices)
            }
        } catch {
            connectedDevices = []
            let message = error.localizedDescription
            if lastDeviceError != message {
                addActivity(level: .warning, title: L10n.text("Could not check connected devices"), details: message)
                lastDeviceError = message
            }
        }
    }

    func addProject(folderURL: URL) async {
        let normalizedPath = folderURL.standardizedFileURL.path
        guard !projects.contains(where: { $0.folderPath == normalizedPath }) else {
            presentedError = L10n.text("This folder is already in the application list.")
            return
        }

        isDiscoveringProject = true
        defer { isDiscoveringProject = false }
        do {
            let descriptor = try await discoveryService.discover(folderURL: folderURL)
            var project = descriptor.makeManagedProject()
            let version = versionService.currentVersion(for: project)
            project.marketingVersion = version.marketingVersion
            project.buildNumber = version.buildNumber
            projects.append(project)
            await refreshProjectIcon(for: project)
            addActivity(
                level: .info,
                title: L10n.format("Added %@", project.displayName),
                details: project.folderPath,
                projectID: project.id
            )
            if connectedDevices.isEmpty {
                await refreshDevices(installWhenDue: true)
            } else if preferences.automationEnabled {
                await installDueProjects(on: installableDevices)
            }
        } catch {
            presentedError = error.localizedDescription
        }
    }

    func removeProject(id: UUID) {
        guard let project = projects.first(where: { $0.id == id }) else { return }
        projects.removeAll { $0.id == id }
        projectIconURLs[id] = nil
        installationRecords.removeAll { $0.projectID == id }
        addActivity(level: .info, title: L10n.format("Removed %@", project.displayName))
    }

    func updateProject(id: UUID, mutation: (inout ManagedProject) -> Void) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        mutation(&projects[index])
    }

    func projectIconURL(for projectID: UUID) -> URL? {
        projectIconURLs[projectID]
    }

    func isDeviceInstallationEnabled(_ deviceUDID: String) -> Bool {
        preferences.installationEnabled(for: deviceUDID)
    }

    func setDeviceInstallationEnabled(_ enabled: Bool, deviceUDID: String) {
        preferences.setInstallationEnabled(enabled, for: deviceUDID)
        if !enabled {
            installAllTargetDeviceUDIDs.remove(deviceUDID)
        }
        restartMonitoring()
    }

    func installNow(projectID: UUID, deviceUDID: String? = nil) {
        guard let project = projects.first(where: { $0.id == projectID }) else { return }
        let targetDevices: [ConnectedDevice]
        if let deviceUDID {
            targetDevices = installableDevices.filter { $0.udid == deviceUDID }
        } else {
            targetDevices = installableDevices
        }
        guard !targetDevices.isEmpty else {
            presentedError = L10n.text("No selected iPhone or iPad is available. Choose a connected device in Settings.")
            return
        }

        Task {
            for device in targetDevices {
                _ = await install(project: project, on: device, ignoreSchedule: true)
            }
        }
    }

    func installAll() {
        guard progress == nil else {
            presentedError = L10n.text("An installation is already in progress. Try again when it finishes.")
            return
        }
        let enabledProjectIDs = Set(projects.filter(\.isEnabled).map(\.id))
        guard !enabledProjectIDs.isEmpty else {
            presentedError = L10n.text("There are no enabled applications to install.")
            return
        }

        installAllProjectIDs = enabledProjectIDs
        installAllTargetDeviceUDIDs = Set(installableDevices.map(\.udid))
        completedInstallAllTargets = []
        addActivity(
            level: .info,
            title: L10n.format("Install All requested for %d application(s)", enabledProjectIDs.count),
            details: installableDevices.isEmpty
                ? L10n.text("Waiting for a selected iPhone or iPad. Choose devices in Settings; the search will continue in the background.")
                : nil
        )
        restartMonitoring()
        Task { await refreshDevices(installWhenDue: false) }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try launchAtLoginService.setEnabled(enabled)
            preferences.launchAtLogin = enabled
        } catch {
            preferences.launchAtLogin = launchAtLoginService.isEnabled
            presentedError = L10n.format("Could not change launch at login: %@", error.localizedDescription)
        }
    }

    private func applyLaunchAtLoginPreferenceOnStartup() {
        guard preferences.launchAtLogin else { return }
        do {
            try launchAtLoginService.setEnabled(true)
        } catch {
            addActivity(
                level: .warning,
                title: L10n.text("Could not enable launch at login"),
                details: error.localizedDescription
            )
        }
    }

    func lastInstallation(for projectID: UUID, deviceUDID: String? = nil) -> Date? {
        installationRecords
            .filter { record in
                record.projectID == projectID && (deviceUDID == nil || record.deviceUDID == deviceUDID)
            }
            .map(\.installedAt)
            .max()
    }

    func nextInstallation(for projectID: UUID) -> Date? {
        SchedulingPolicy.nextInstallationDate(
            lastInstalledAt: lastInstallation(for: projectID),
            intervalDays: preferences.reinstallAfterDays
        )
    }

    func clearActivity() {
        activity = []
    }

    private func installDueProjects(on devices: [ConnectedDevice]) async {
        guard progress == nil else { return }
        let enabledProjects = projects.filter(\.isEnabled)
        let now = Date()

        for device in devices where device.supportsIOSAppInstallation {
            for project in enabledProjects {
                let attemptKey = recordKey(projectID: project.id, deviceUDID: device.udid)
                if let cooldownUntil = failedAttemptCooldowns[attemptKey], cooldownUntil > now {
                    continue
                }

                let lastInstalledAt = installationRecords.first {
                    $0.projectID == project.id && $0.deviceUDID == device.udid
                }?.installedAt
                guard SchedulingPolicy.isDue(
                    lastInstalledAt: lastInstalledAt,
                    now: now,
                    intervalDays: preferences.reinstallAfterDays
                ) else {
                    continue
                }

                _ = await install(project: project, on: device, ignoreSchedule: false)
            }
        }
    }

    private func installAllRequestedProjects(on devices: [ConnectedDevice]) async {
        guard progress == nil else { return }
        let requestedIDs = installAllProjectIDs
        for device in devices {
            for project in projects where requestedIDs.contains(project.id) && project.isEnabled {
                let targetKey = recordKey(projectID: project.id, deviceUDID: device.udid)
                guard !completedInstallAllTargets.contains(targetKey) else { continue }
                if await install(project: project, on: device, ignoreSchedule: true) {
                    completedInstallAllTargets.insert(targetKey)
                }
            }
        }

        installAllProjectIDs = Set(installAllProjectIDs.filter { projectID in
            guard projects.contains(where: { $0.id == projectID && $0.isEnabled }) else {
                return false
            }
            return installAllTargetDeviceUDIDs.contains { deviceUDID in
                !completedInstallAllTargets.contains(
                    recordKey(projectID: projectID, deviceUDID: deviceUDID)
                )
            }
        })
        if installAllProjectIDs.isEmpty {
            installAllTargetDeviceUDIDs = []
            completedInstallAllTargets = []
            addActivity(level: .success, title: L10n.text("Install All completed successfully"))
        }
    }

    @discardableResult
    private func install(project: ManagedProject, on device: ConnectedDevice, ignoreSchedule: Bool) async -> Bool {
        guard device.supportsIOSAppInstallation else { return false }
        guard progress == nil else {
            if ignoreSchedule {
                presentedError = L10n.text("An installation is already in progress. Try again when it finishes.")
            }
            return false
        }

        progress = InstallationProgress(
            projectName: project.displayName,
            deviceName: device.name,
            phase: .preparing,
            latestOutput: ""
        )
        addActivity(
            level: .info,
            title: L10n.format("Starting installation of %@ on %@", project.displayName, device.name),
            projectID: project.id,
            deviceUDID: device.udid
        )

        do {
            let outcome = try await installationService.install(
                project: project,
                on: device,
                eventHandler: { [weak self] event in
                    Task { @MainActor [weak self] in
                        self?.handleInstallationEvent(event)
                    }
                }
            )
            recordSuccessfulInstallation(projectID: project.id, deviceUDID: device.udid)
            if preferences.notificationsEnabled != false {
                let iconURL: URL?
                if let cachedIconURL = projectIconURLs[project.id] {
                    iconURL = cachedIconURL
                } else {
                    iconURL = await projectIconService.iconURL(for: project)
                }
                if let iconURL { projectIconURLs[project.id] = iconURL }
                notificationService.notifySuccessfulInstallation(
                    project: project,
                    device: device,
                    applicationIconURL: iconURL
                )
            }
            failedAttemptCooldowns[recordKey(projectID: project.id, deviceUDID: device.udid)] = nil
            addActivity(
                level: .success,
                title: L10n.format("%@ was installed successfully on %@", project.displayName, device.name),
                details: outcome.log,
                projectID: project.id,
                deviceUDID: device.udid
            )
            progress = nil
            return true
        } catch {
            failedAttemptCooldowns[recordKey(projectID: project.id, deviceUDID: device.udid)] =
                Date().addingTimeInterval(5 * 60)
            addActivity(
                level: .error,
                title: L10n.format("Installation of %@ failed", project.displayName),
                details: Self.trimmedError(error.localizedDescription),
                projectID: project.id,
                deviceUDID: device.udid
            )
            progress = nil
            return false
        }
    }

    private func handleInstallationEvent(_ event: InstallationEvent) {
        guard var current = progress else { return }
        switch event {
        case .phase(let phase):
            current.phase = phase
        case .output(let output):
            let lines = output.split(whereSeparator: \Character.isNewline)
            if let latest = lines.last {
                current.latestOutput = String(latest).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        progress = current
    }

    private func recordSuccessfulInstallation(projectID: UUID, deviceUDID: String) {
        let installedVersion = projects.first(where: { $0.id == projectID })?.versionDisplay
        if let index = installationRecords.firstIndex(where: {
            $0.projectID == projectID && $0.deviceUDID == deviceUDID
        }) {
            installationRecords[index].installedAt = Date()
            installationRecords[index].installedVersion = installedVersion
        } else {
            installationRecords.append(InstallationRecord(
                projectID: projectID,
                deviceUDID: deviceUDID,
                installedAt: Date(),
                installedVersion: installedVersion
            ))
        }
    }

    private func refreshProjectVersions() {
        var refreshedProjects = projects
        var changed = false
        for index in refreshedProjects.indices {
            let version = versionService.currentVersion(for: refreshedProjects[index])
            if refreshedProjects[index].marketingVersion != version.marketingVersion
                || refreshedProjects[index].buildNumber != version.buildNumber {
                refreshedProjects[index].marketingVersion = version.marketingVersion
                refreshedProjects[index].buildNumber = version.buildNumber
                changed = true
            }
        }
        if changed { projects = refreshedProjects }
    }

    private func refreshProjectIcons() async {
        for project in projects {
            await refreshProjectIcon(for: project)
        }
    }

    private func refreshProjectIcon(for project: ManagedProject) async {
        if let url = await projectIconService.iconURL(for: project) {
            projectIconURLs[project.id] = url
        }
    }

    private func addActivity(
        level: ActivityLevel,
        title: String,
        details: String? = nil,
        projectID: UUID? = nil,
        deviceUDID: String? = nil
    ) {
        activity.insert(ActivityEntry(
            level: level,
            title: title,
            details: details,
            projectID: projectID,
            deviceUDID: deviceUDID
        ), at: 0)
        if activity.count > 100 {
            activity.removeLast(activity.count - 100)
        }
    }

    private func recordKey(projectID: UUID, deviceUDID: String) -> String {
        "\(projectID.uuidString)|\(deviceUDID)"
    }

    private func nextMonitoringDelay(now: Date = Date()) -> TimeInterval {
        if !installAllProjectIDs.isEmpty { return TimeInterval(preferences.pollIntervalSeconds) }
        guard preferences.automationEnabled else { return 60 * 60 }

        let enabledProjects = projects.filter(\.isEnabled)
        guard !enabledProjects.isEmpty else { return 60 * 60 }

        var nextDates: [Date] = []
        for project in enabledProjects {
            guard let lastInstalledAt = lastInstallation(for: project.id),
                  let nextDate = SchedulingPolicy.nextInstallationDate(
                    lastInstalledAt: lastInstalledAt,
                    intervalDays: preferences.reinstallAfterDays
                  )
            else {
                return TimeInterval(preferences.pollIntervalSeconds)
            }
            nextDates.append(nextDate)
        }

        guard let earliestDate = nextDates.min() else { return 60 * 60 }
        if earliestDate <= now { return TimeInterval(preferences.pollIntervalSeconds) }
        return max(10, earliestDate.timeIntervalSince(now))
    }

    private func restartMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = nil
        startMonitoring()
    }

    private func persist() {
        guard !isLoading else { return }
        settingsStore.save(PersistedState(
            preferences: preferences,
            projects: projects,
            installationRecords: installationRecords,
            activity: activity,
            didApplyLaunchAtLoginDefault: didApplyLaunchAtLoginDefault
        ))
    }

    private static func trimmedError(_ text: String, limit: Int = 30_000) -> String {
        guard text.count > limit else { return text }
        return "…\n" + String(text.suffix(limit))
    }
}
