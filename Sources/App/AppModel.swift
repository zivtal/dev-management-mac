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
    @Published private(set) var installedApplicationsByDeviceUDID: [String: [String: InstalledApplication]] = [:]
    @Published private(set) var checkedInstalledApplicationDeviceUDIDs: Set<String> = []
    @Published private(set) var progress: InstallationProgress?
    @Published private(set) var installationLog: InstallationLogSession?
    @Published private(set) var isCancellingInstallation = false
    @Published private(set) var isRefreshingDevices = false
    @Published private(set) var isDiscoveringProject = false
    @Published private(set) var compatibilityRefreshProjectIDs: Set<UUID> = []
    @Published private(set) var pendingInstallAllCount = 0
    @Published private(set) var projectIconURLs: [UUID: URL] = [:]
    @Published private(set) var developerTeams: [DeveloperTeam] = []
    @Published private(set) var isRefreshingDeveloperTeams = false
    @Published private(set) var isSettingsWindowOpen = false
    @Published var presentedError: String?

    var installableDevices: [ConnectedDevice] {
        connectedDevices.filter(\.supportsIOSAppInstallation)
    }

    var hasMacOSProjects: Bool {
        projects.contains(where: \.isMacOSApplication)
    }

    var hasIOSProjects: Bool {
        projects.contains { !$0.isMacOSApplication }
    }

    private struct ProjectInstallationTarget {
        let identifier: String
        let name: String
        let device: ConnectedDevice?
    }

    private var localMacInstallationTarget: ProjectInstallationTarget {
        ProjectInstallationTarget(
            identifier: ManagedProject.localMacInstallationTargetID,
            name: L10n.text("This Mac"),
            device: nil
        )
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
    private let developerTeamService: DeveloperTeamService
    private var monitoringTask: Task<Void, Never>?
    private var activeInstallationTask: Task<InstallationOutcome, Error>?
    private var installationCancellationGeneration = 0
    private var isLoading = true
    private var failedAttemptCooldowns: [String: Date] = [:]
    private var failedVersionCheckDeviceUDIDs: Set<String> = []
    private var installAllTargets: [UUID: Set<String>] = [:] {
        didSet { pendingInstallAllCount = installAllTargets.count }
    }
    private var completedInstallAllTargets: Set<String> = []
    private var lastDeviceError: String?
    private var didApplyLaunchAtLoginDefault: Bool
    private var didRequestNotificationAuthorization = false

    init(
        settingsStore: SettingsStore = SettingsStore(),
        deviceService: DeviceService = DeviceService(),
        discoveryService: ProjectDiscoveryService = ProjectDiscoveryService(),
        installationService: InstallationService = InstallationService(),
        versionService: ProjectVersionService = ProjectVersionService(),
        launchAtLoginService: LaunchAtLoginService = LaunchAtLoginService(),
        usbConnectionMonitor: USBConnectionMonitor = USBConnectionMonitor(),
        notificationService: NotificationService = NotificationService(),
        projectIconService: ProjectIconService = ProjectIconService(),
        developerTeamService: DeveloperTeamService = DeveloperTeamService()
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
        self.developerTeamService = developerTeamService

        let savedState = settingsStore.load()
        var loadedPreferences = savedState.preferences
        var loadedProjects = savedState.projects
        if savedState.didApplyLaunchAtLoginDefault != true {
            loadedPreferences.launchAtLogin = true
        }
        if let legacyExclusions = loadedPreferences.excludedDeviceUDIDs {
            for index in loadedProjects.indices where loadedProjects[index].excludedDeviceUDIDs == nil {
                loadedProjects[index].excludedDeviceUDIDs = legacyExclusions
            }
            loadedPreferences.excludedDeviceUDIDs = nil
        }
        preferences = loadedPreferences
        projects = loadedProjects
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
        refreshDeveloperTeams()
        Task { @MainActor [weak self] in
            await self?.refreshProjectIcons()
        }
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            startMonitoring()
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                self?.applyLaunchAtLoginPreferenceOnStartup()
            }
        }
    }

    deinit {
        monitoringTask?.cancel()
        activeInstallationTask?.cancel()
    }

    func startMonitoring() {
        guard monitoringTask == nil else { return }
        if !didRequestNotificationAuthorization, preferences.notificationsEnabled != false {
            didRequestNotificationAuthorization = true
            notificationService.requestAuthorization()
        }
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

    func refreshDeveloperTeams() {
        guard !isRefreshingDeveloperTeams else { return }
        isRefreshingDeveloperTeams = true
        developerTeams = developerTeamService.availableTeams()
        isRefreshingDeveloperTeams = false
    }

    func refreshDevices(installWhenDue: Bool) async {
        guard !isRefreshingDevices else { return }
        isRefreshingDevices = true
        defer { isRefreshingDevices = false }

        await refreshUnknownProjectMetadata(restartMonitoringAfterUpdate: false)
        refreshProjectVersions()

        do {
            let devices = try await deviceService.availableDevices()
            connectedDevices = devices
            let connectedDeviceUDIDs = Set(devices.map(\.udid))
            installedApplicationsByDeviceUDID = installedApplicationsByDeviceUDID.filter {
                connectedDeviceUDIDs.contains($0.key)
            }
            checkedInstalledApplicationDeviceUDIDs.formIntersection(connectedDeviceUDIDs)
            failedVersionCheckDeviceUDIDs.formIntersection(connectedDeviceUDIDs)
            lastDeviceError = nil
            let appInstallableDevices = installableDevices
            await refreshInstalledApplications(on: appInstallableDevices)
            if !installAllTargets.isEmpty {
                preparePendingInstallAllTargets()
                await installAllRequestedProjects(on: appInstallableDevices)
            } else if installWhenDue, preferences.automationEnabled, !isSettingsWindowOpen {
                await installDueProjects(on: appInstallableDevices)
            }
        } catch {
            connectedDevices = []
            installedApplicationsByDeviceUDID = [:]
            checkedInstalledApplicationDeviceUDIDs = []
            let message = error.localizedDescription
            if lastDeviceError != message {
                addActivity(level: .warning, title: L10n.text("Could not check connected devices"), details: message)
                lastDeviceError = message
            }
            if !installAllTargets.isEmpty {
                preparePendingInstallAllTargets()
                await installAllRequestedProjects(on: [])
            } else if installWhenDue, preferences.automationEnabled, !isSettingsWindowOpen {
                await installDueProjects(on: [])
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
            } else if preferences.automationEnabled, !isSettingsWindowOpen {
                await installDueProjects(on: installableDevices)
            }
        } catch {
            presentedError = error.localizedDescription
        }
    }

    func removeProject(id: UUID) {
        guard let project = projects.first(where: { $0.id == id }) else { return }
        projects.removeAll { $0.id == id }
        installAllTargets[id] = nil
        clearTransientInstallationState(for: id)
        projectIconURLs[id] = nil
        installationRecords.removeAll { $0.projectID == id }
        addActivity(level: .info, title: L10n.format("Removed %@", project.displayName))
    }

    func updateProject(id: UUID, mutation: (inout ManagedProject) -> Void) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        mutation(&projects[index])
        if !projects[index].isEnabled {
            installAllTargets[id] = nil
            clearTransientInstallationState(for: id)
        }
    }

    func setProjectEnabled(_ enabled: Bool, projectID: UUID) {
        updateProject(id: projectID) { $0.isEnabled = enabled }
        restartMonitoring()
    }

    func projectIconURL(for projectID: UUID) -> URL? {
        projectIconURLs[projectID]
    }

    func compatibleConnectedDevices(for project: ManagedProject) -> [ConnectedDevice] {
        project.devicesInInstallationOrder(installableDevices.filter(project.supports))
    }

    func selectedInstallableDevices(for project: ManagedProject) -> [ConnectedDevice] {
        compatibleConnectedDevices(for: project).filter(project.installationEnabled)
    }

    func selectedDeviceCount(for project: ManagedProject) -> Int {
        if project.isMacOSApplication { return 1 }
        return project.selectedDeviceCount(in: connectedDevices)
    }

    func hasAvailableInstallationTarget(for project: ManagedProject) -> Bool {
        project.isMacOSApplication || !selectedInstallableDevices(for: project).isEmpty
    }

    func isDeviceInstallationEnabled(_ deviceUDID: String, for projectID: UUID) -> Bool {
        guard let project = projects.first(where: { $0.id == projectID }),
              let device = connectedDevices.first(where: { $0.udid == deviceUDID })
        else {
            return false
        }
        return project.isSelectedInstallationTarget(device)
    }

    func setDeviceInstallationEnabled(_ enabled: Bool, deviceUDID: String, for projectID: UUID) {
        updateProject(id: projectID) {
            $0.setInstallationEnabled(enabled, for: deviceUDID)
        }
        if !enabled {
            installAllTargets[projectID]?.remove(deviceUDID)
            completedInstallAllTargets.remove(recordKey(projectID: projectID, deviceUDID: deviceUDID))
            failedAttemptCooldowns[recordKey(projectID: projectID, deviceUDID: deviceUDID)] = nil
        }
        restartMonitoring()
    }

    func moveInstallationDevice(
        _ deviceUDID: String,
        relativeTo destinationDeviceUDID: String,
        placeAfterDestination: Bool,
        for projectID: UUID
    ) {
        guard let project = projects.first(where: { $0.id == projectID }),
              deviceUDID != destinationDeviceUDID
        else {
            return
        }

        var orderedDeviceUDIDs = compatibleConnectedDevices(for: project).map(\.udid)
        guard let sourceIndex = orderedDeviceUDIDs.firstIndex(of: deviceUDID) else { return }
        orderedDeviceUDIDs.remove(at: sourceIndex)
        guard let destinationIndex = orderedDeviceUDIDs.firstIndex(of: destinationDeviceUDID) else {
            return
        }
        let insertionIndex = destinationIndex + (placeAfterDestination ? 1 : 0)
        orderedDeviceUDIDs.insert(deviceUDID, at: insertionIndex)
        updateProject(id: projectID) {
            $0.setInstallationDeviceOrder(orderedDeviceUDIDs)
        }
        restartMonitoring()
    }

    func isRefreshingCompatibility(for projectID: UUID) -> Bool {
        compatibilityRefreshProjectIDs.contains(projectID)
    }

    func setProjectScheme(_ scheme: String, for projectID: UUID) {
        updateProject(id: projectID) {
            $0.scheme = scheme
            if let matchingConfiguration = $0.configurationMatchingScheme(scheme) {
                $0.configuration = matchingConfiguration
            }
            $0.supportedDeviceFamilies = nil
            $0.bundleIdentifier = nil
            $0.projectSigningTeamID = nil
            $0.applicationPlatform = nil
        }
        resetQueuedTargets(for: projectID)
        refreshProjectCompatibility(projectID: projectID)
    }

    func setProjectConfiguration(_ configuration: String, for projectID: UUID) {
        updateProject(id: projectID) {
            $0.configuration = configuration
            $0.supportedDeviceFamilies = nil
            $0.bundleIdentifier = nil
            $0.projectSigningTeamID = nil
            $0.applicationPlatform = nil
        }
        resetQueuedTargets(for: projectID)
        refreshProjectCompatibility(projectID: projectID)
    }

    func installNow(projectID: UUID, deviceUDID: String? = nil) {
        guard let project = projects.first(where: { $0.id == projectID }) else { return }
        guard project.isEnabled else {
            presentedError = L10n.text("This application is paused. Resume it in Settings before installing.")
            return
        }
        if project.isMacOSApplication {
            let cancellationGeneration = installationCancellationGeneration
            Task {
                guard cancellationGeneration == installationCancellationGeneration else { return }
                _ = await install(
                    project: project,
                    target: localMacInstallationTarget,
                    ignoreSchedule: true
                )
            }
            return
        }

        let targetDevices: [ConnectedDevice]
        if let deviceUDID {
            targetDevices = selectedInstallableDevices(for: project).filter { $0.udid == deviceUDID }
        } else {
            targetDevices = selectedInstallableDevices(for: project)
        }
        guard !targetDevices.isEmpty else {
            presentedError = L10n.text("No selected compatible device is available for this application. Choose a connected device in Applications settings.")
            return
        }

        let cancellationGeneration = installationCancellationGeneration
        Task {
            for device in targetDevices {
                guard cancellationGeneration == installationCancellationGeneration else { return }
                _ = await install(
                    project: project,
                    target: ProjectInstallationTarget(
                        identifier: device.udid,
                        name: device.name,
                        device: device
                    ),
                    ignoreSchedule: true
                )
            }
        }
    }

    func cancelActiveInstallation() {
        guard progress != nil, let activeInstallationTask else { return }
        installationCancellationGeneration &+= 1
        isCancellingInstallation = true
        installAllTargets = [:]
        completedInstallAllTargets = []
        activeInstallationTask.cancel()
    }

    func installAll() {
        guard progress == nil else {
            presentedError = L10n.text("An installation is already in progress. Try again when it finishes.")
            return
        }
        let enabledProjects = projects.filter(\.isEnabled)
        guard !enabledProjects.isEmpty else {
            presentedError = L10n.text("There are no enabled applications to install.")
            return
        }

        installAllTargets = Dictionary(uniqueKeysWithValues: enabledProjects.map { project in
            let targetIdentifiers = project.isMacOSApplication
                ? [ManagedProject.localMacInstallationTargetID]
                : selectedInstallableDevices(for: project).map(\.udid)
            return (project.id, Set(targetIdentifiers))
        })
        completedInstallAllTargets = []
        addActivity(
            level: .info,
            title: L10n.format("Install All requested for %d application(s)", enabledProjects.count),
            details: installAllTargets.values.contains(where: \.isEmpty)
                ? L10n.text("Some applications are waiting for a selected compatible iPhone or iPad. Choose devices per application in Settings; the search will continue in the background.")
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

    func setSettingsWindowOpen(_ isOpen: Bool) {
        guard isSettingsWindowOpen != isOpen else { return }
        isSettingsWindowOpen = isOpen
        Task { await refreshDevices(installWhenDue: !isOpen) }
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

    func lastInstallationRecord(for projectID: UUID, deviceUDID: String) -> InstallationRecord? {
        installationRecords
            .filter { $0.projectID == projectID && $0.deviceUDID == deviceUDID }
            .max { $0.installedAt < $1.installedAt }
    }

    func installedApplication(for project: ManagedProject, deviceUDID: String) -> InstalledApplication? {
        guard let bundleIdentifier = project.bundleIdentifier else { return nil }
        return installedApplicationsByDeviceUDID[deviceUDID]?[bundleIdentifier]
    }

    func didCheckInstalledApplications(on deviceUDID: String) -> Bool {
        checkedInstalledApplicationDeviceUDIDs.contains(deviceUDID)
    }

    func installedDeviceCount(for projectID: UUID) -> Int {
        installationRecords.installedDeviceCount(for: projectID)
    }

    func nextInstallation(for projectID: UUID) -> Date? {
        SchedulingPolicy.nextInstallationDate(
            lastInstalledAt: lastInstallation(for: projectID),
            profileExpirationDate: expirationDate(for: projectID),
            intervalDays: preferences.reinstallAfterDays
        )
    }

    func expirationDate(for projectID: UUID) -> Date? {
        installationRecords.lazy
            .filter { $0.projectID == projectID }
            .compactMap(\.profileExpirationDate)
            .min()
    }

    func clearActivity() {
        activity = []
    }

    private func installDueProjects(on devices: [ConnectedDevice]) async {
        guard progress == nil else { return }
        let enabledProjects = projects.filter(\.isEnabled)
        let now = Date()
        let cancellationGeneration = installationCancellationGeneration

        for project in enabledProjects {
            if project.isMacOSApplication {
                let target = localMacInstallationTarget
                let attemptKey = recordKey(
                    projectID: project.id,
                    deviceUDID: target.identifier
                )
                if let cooldownUntil = failedAttemptCooldowns[attemptKey], cooldownUntil > now {
                    continue
                }
                let installationRecord = lastInstallationRecord(
                    for: project.id,
                    deviceUDID: target.identifier
                )
                guard SchedulingPolicy.isDue(
                    lastInstalledAt: installationRecord?.installedAt,
                    profileExpirationDate: installationRecord?.profileExpirationDate,
                    now: now,
                    intervalDays: preferences.reinstallAfterDays
                ) else {
                    continue
                }
                guard cancellationGeneration == installationCancellationGeneration else { return }
                _ = await install(project: project, target: target, ignoreSchedule: false)
                continue
            }

            let orderedDevices = project.devicesInInstallationOrder(
                devices.filter { project.installationEnabled(for: $0) }
            )
            for device in orderedDevices {
                guard cancellationGeneration == installationCancellationGeneration else { return }
                let attemptKey = recordKey(projectID: project.id, deviceUDID: device.udid)
                if let cooldownUntil = failedAttemptCooldowns[attemptKey], cooldownUntil > now {
                    continue
                }

                let installationRecord = lastInstallationRecord(
                    for: project.id,
                    deviceUDID: device.udid
                )
                let scheduleIsDue = SchedulingPolicy.isDue(
                    lastInstalledAt: installationRecord?.installedAt,
                    profileExpirationDate: installationRecord?.profileExpirationDate,
                    now: now,
                    intervalDays: preferences.reinstallAfterDays
                )
                let expirationDiscoveryIsDue = project.installMethod == .xcodebuild
                    && installationRecord != nil
                    && installationRecord?.profileExpirationWasChecked != true
                let installedVersionIsOlder: Bool
                if let bundleIdentifier = project.bundleIdentifier,
                   checkedInstalledApplicationDeviceUDIDs.contains(device.udid) {
                    installedVersionIsOlder = SchedulingPolicy.installedApplicationIsOlder(
                        installedApplicationsByDeviceUDID[device.udid]?[bundleIdentifier],
                        than: ProjectVersion(
                            marketingVersion: project.marketingVersion,
                            buildNumber: project.buildNumber
                        )
                    )
                } else {
                    installedVersionIsOlder = false
                }
                guard scheduleIsDue || expirationDiscoveryIsDue || installedVersionIsOlder else {
                    continue
                }

                _ = await install(
                    project: project,
                    target: ProjectInstallationTarget(
                        identifier: device.udid,
                        name: device.name,
                        device: device
                    ),
                    ignoreSchedule: false
                )
            }
        }
    }

    private func installAllRequestedProjects(on devices: [ConnectedDevice]) async {
        guard progress == nil else { return }
        let cancellationGeneration = installationCancellationGeneration
        let requestedIDs = projects.map(\.id).filter { installAllTargets[$0] != nil }
        for projectID in requestedIDs {
            guard cancellationGeneration == installationCancellationGeneration else { return }
            guard let project = projects.first(where: { $0.id == projectID && $0.isEnabled }) else {
                installAllTargets[projectID] = nil
                continue
            }
            let targetDeviceUDIDs = installAllTargets[projectID] ?? []
            let targets: [ProjectInstallationTarget]
            if project.isMacOSApplication {
                targets = targetDeviceUDIDs.contains(ManagedProject.localMacInstallationTargetID)
                    ? [localMacInstallationTarget]
                    : []
            } else {
                targets = project.devicesInInstallationOrder(
                    devices.filter { targetDeviceUDIDs.contains($0.udid) }
                ).map {
                    ProjectInstallationTarget(identifier: $0.udid, name: $0.name, device: $0)
                }
            }
            for target in targets {
                guard cancellationGeneration == installationCancellationGeneration else { return }
                let targetKey = recordKey(projectID: project.id, deviceUDID: target.identifier)
                guard !completedInstallAllTargets.contains(targetKey) else { continue }
                if await install(project: project, target: target, ignoreSchedule: true) {
                    completedInstallAllTargets.insert(targetKey)
                }
            }

            if !targetDeviceUDIDs.isEmpty,
               targetDeviceUDIDs.allSatisfy({ deviceUDID in
                   completedInstallAllTargets.contains(
                       recordKey(projectID: projectID, deviceUDID: deviceUDID)
                   )
               }) {
                installAllTargets[projectID] = nil
            }
        }

        if installAllTargets.isEmpty,
           cancellationGeneration == installationCancellationGeneration {
            completedInstallAllTargets = []
            addActivity(level: .success, title: L10n.text("Install All completed successfully"))
        }
    }

    private func preparePendingInstallAllTargets() {
        for projectID in Array(installAllTargets.keys) where installAllTargets[projectID]?.isEmpty == true {
            guard let project = projects.first(where: { $0.id == projectID && $0.isEnabled }) else {
                installAllTargets[projectID] = nil
                continue
            }
            let targetIdentifiers = project.isMacOSApplication
                ? Set([ManagedProject.localMacInstallationTargetID])
                : Set(selectedInstallableDevices(for: project).map(\.udid))
            if !targetIdentifiers.isEmpty {
                installAllTargets[projectID] = targetIdentifiers
            }
        }
    }

    @discardableResult
    private func install(
        project requestedProject: ManagedProject,
        target: ProjectInstallationTarget,
        ignoreSchedule: Bool
    ) async -> Bool {
        guard let project = projects.first(where: { $0.id == requestedProject.id }) else { return false }
        if let device = target.device {
            guard !project.isMacOSApplication, project.installationEnabled(for: device) else { return false }
        } else {
            guard project.isMacOSApplication, project.isEnabled else { return false }
        }
        guard progress == nil else {
            if ignoreSchedule {
                presentedError = L10n.text("An installation is already in progress. Try again when it finishes.")
            }
            return false
        }

        let installationLogID = UUID()
        isCancellingInstallation = false
        progress = InstallationProgress(
            projectName: project.displayName,
            deviceName: target.name,
            phase: .preparing,
            latestOutput: ""
        )
        installationLog = InstallationLogSession(
            id: installationLogID,
            projectName: project.displayName,
            deviceName: target.name
        )
        addActivity(
            level: .info,
            title: L10n.format("Starting installation of %@ on %@", project.displayName, target.name),
            projectID: project.id,
            deviceUDID: target.identifier
        )

        let eventCoalescer = InstallationEventCoalescer { [weak self] batch in
            Task { @MainActor [weak self] in
                self?.handleInstallationEvents(batch, installationLogID: installationLogID)
            }
        }

        let installationTask = Task { () -> InstallationOutcome in
            if let device = target.device {
                return try await installationService.install(
                    project: project,
                    on: device,
                    eventHandler: { eventCoalescer.receive($0) }
                )
            }
            return try await installationService.install(
                project: project,
                eventHandler: { eventCoalescer.receive($0) }
            )
        }
        activeInstallationTask = installationTask

        do {
            let outcome = try await installationTask.value
            activeInstallationTask = nil
            handleInstallationEvents(eventCoalescer.finish(), installationLogID: installationLogID)
            replaceInstallationLogOutput(outcome.log, installationLogID: installationLogID)
            finishInstallationLog(id: installationLogID, state: .succeeded)
            recordSuccessfulInstallation(
                projectID: project.id,
                deviceUDID: target.identifier,
                profileExpirationDate: outcome.profileExpirationDate,
                profileExpirationWasChecked: outcome.profileExpirationWasChecked
            )
            if preferences.notificationsEnabled != false {
                let iconURL = await projectIconService.iconURL(for: project)
                projectIconURLs[project.id] = iconURL
                if let device = target.device {
                    notificationService.notifySuccessfulInstallation(
                        project: project,
                        device: device,
                        applicationIconURL: iconURL
                    )
                } else {
                    notificationService.notifySuccessfulMacOSInstallation(
                        project: project,
                        applicationIconURL: iconURL
                    )
                }
            }
            failedAttemptCooldowns[
                recordKey(projectID: project.id, deviceUDID: target.identifier)
            ] = nil
            addActivity(
                level: .success,
                title: L10n.format("%@ was installed successfully on %@", project.displayName, target.name),
                details: outcome.log,
                projectID: project.id,
                deviceUDID: target.identifier
            )
            progress = nil
            isCancellingInstallation = false
            return true
        } catch {
            activeInstallationTask = nil
            handleInstallationEvents(eventCoalescer.finish(), installationLogID: installationLogID)
            if installationTask.isCancelled || error is CancellationError {
                let cancellationText = L10n.text("Installation canceled by user.")
                appendInstallationLogOutput(
                    "\n\n\(cancellationText)\n",
                    installationLogID: installationLogID
                )
                finishInstallationLog(id: installationLogID, state: .cancelled)
                failedAttemptCooldowns[
                    recordKey(projectID: project.id, deviceUDID: target.identifier)
                ] = nil
                addActivity(
                    level: .warning,
                    title: L10n.format("Installation of %@ was canceled", project.displayName),
                    details: cancellationText,
                    projectID: project.id,
                    deviceUDID: target.identifier
                )
                progress = nil
                isCancellingInstallation = false
                return false
            }
            let errorOutput = Self.trimmedError(error.localizedDescription)
            replaceInstallationLogOutput(errorOutput, installationLogID: installationLogID)
            finishInstallationLog(
                id: installationLogID,
                state: .failed,
                fallbackError: errorOutput
            )
            failedAttemptCooldowns[recordKey(projectID: project.id, deviceUDID: target.identifier)] =
                Date().addingTimeInterval(5 * 60)
            addActivity(
                level: .error,
                title: L10n.format("Installation of %@ failed", project.displayName),
                details: errorOutput,
                projectID: project.id,
                deviceUDID: target.identifier
            )
            progress = nil
            isCancellingInstallation = false
            return false
        }
    }

    private func handleInstallationEvents(_ batch: InstallationEventBatch, installationLogID: UUID) {
        guard !batch.isEmpty else { return }
        guard var current = progress else { return }
        guard var log = installationLog, log.id == installationLogID else { return }
        guard log.state == .inProgress else { return }
        if let phase = batch.phase {
            current.phase = phase
            log.phase = phase
        }
        if !batch.output.isEmpty {
            log.append(batch.output)
            current.latestOutput = log.latestOutputLine
        }
        installationLog = log
        progress = current
    }

    private func replaceInstallationLogOutput(_ output: String, installationLogID: UUID) {
        guard var log = installationLog, log.id == installationLogID else { return }
        log.replaceOutput(with: output)
        installationLog = log
    }

    private func appendInstallationLogOutput(_ output: String, installationLogID: UUID) {
        guard var log = installationLog, log.id == installationLogID else { return }
        log.append(output)
        installationLog = log
    }

    private func finishInstallationLog(
        id: UUID,
        state: InstallationLogSession.State,
        fallbackError: String? = nil
    ) {
        guard var log = installationLog, log.id == id else { return }
        log.state = state
        if log.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let fallbackError,
           !fallbackError.isEmpty {
            log.append(fallbackError)
        }
        installationLog = log
    }

    private func recordSuccessfulInstallation(
        projectID: UUID,
        deviceUDID: String,
        profileExpirationDate: Date?,
        profileExpirationWasChecked: Bool
    ) {
        let installedProject = projects.first(where: { $0.id == projectID })
        let installedVersion = installedProject?.versionDisplay
        if let index = installationRecords.firstIndex(where: {
            $0.projectID == projectID && $0.deviceUDID == deviceUDID
        }) {
            installationRecords[index].installedAt = Date()
            installationRecords[index].installedVersion = installedVersion
            installationRecords[index].profileExpirationDate = profileExpirationDate
            installationRecords[index].profileExpirationWasChecked = profileExpirationWasChecked
        } else {
            installationRecords.append(InstallationRecord(
                projectID: projectID,
                deviceUDID: deviceUDID,
                installedAt: Date(),
                installedVersion: installedVersion,
                profileExpirationDate: profileExpirationDate,
                profileExpirationWasChecked: profileExpirationWasChecked
            ))
        }
        if deviceUDID != ManagedProject.localMacInstallationTargetID,
           let installedProject,
           let bundleIdentifier = installedProject.bundleIdentifier {
            installedApplicationsByDeviceUDID[deviceUDID, default: [:]][bundleIdentifier] =
                InstalledApplication(
                    bundleIdentifier: bundleIdentifier,
                    marketingVersion: installedProject.marketingVersion,
                    buildNumber: installedProject.buildNumber
                )
            checkedInstalledApplicationDeviceUDIDs.insert(deviceUDID)
        }
    }

    private func refreshInstalledApplications(on devices: [ConnectedDevice]) async {
        for device in devices {
            do {
                installedApplicationsByDeviceUDID[device.udid] =
                    try await deviceService.installedApplications(on: device)
                checkedInstalledApplicationDeviceUDIDs.insert(device.udid)
                failedVersionCheckDeviceUDIDs.remove(device.udid)
            } catch {
                installedApplicationsByDeviceUDID[device.udid] = nil
                checkedInstalledApplicationDeviceUDIDs.remove(device.udid)
                failedVersionCheckDeviceUDIDs.insert(device.udid)
            }
        }
    }

    func refreshProjectVersions() {
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
        projectIconURLs[project.id] = await projectIconService.iconURL(for: project)
    }

    private func refreshUnknownProjectMetadata(restartMonitoringAfterUpdate: Bool) async {
        let projectIDs = projects
            .filter {
                $0.applicationPlatform == nil
                    || ($0.effectiveApplicationPlatform == .iOS
                        && $0.supportedDeviceFamilies == nil)
                    || $0.bundleIdentifier == nil
                    || $0.projectSigningTeamID == nil
            }
            .map(\.id)
        for projectID in projectIDs {
            await detectProjectCompatibility(
                projectID: projectID,
                restartMonitoringAfterUpdate: restartMonitoringAfterUpdate
            )
        }
    }

    private func refreshProjectCompatibility(projectID: UUID) {
        Task { @MainActor [weak self] in
            await self?.detectProjectCompatibility(
                projectID: projectID,
                restartMonitoringAfterUpdate: true
            )
        }
    }

    private func detectProjectCompatibility(
        projectID: UUID,
        restartMonitoringAfterUpdate: Bool
    ) async {
        guard let project = projects.first(where: { $0.id == projectID }) else { return }
        guard !compatibilityRefreshProjectIDs.contains(projectID) else { return }
        compatibilityRefreshProjectIDs.insert(projectID)
        defer { compatibilityRefreshProjectIDs.remove(projectID) }

        guard let metadata = try? await discoveryService.applicationMetadata(for: project),
              let index = projects.firstIndex(where: {
                  $0.id == projectID
                      && $0.scheme == project.scheme
                      && $0.configuration == project.configuration
              })
        else {
            return
        }
        projects[index].supportedDeviceFamilies = metadata.supportedDeviceFamilies
        projects[index].bundleIdentifier = metadata.bundleIdentifier
        projects[index].projectSigningTeamID = metadata.projectSigningTeamID
        projects[index].applicationPlatform = metadata.applicationPlatform
        if restartMonitoringAfterUpdate {
            restartMonitoring()
        }
    }

    private func resetQueuedTargets(for projectID: UUID) {
        clearTransientInstallationState(for: projectID)
        guard installAllTargets[projectID] != nil else { return }
        installAllTargets[projectID] = []
    }

    private func clearTransientInstallationState(for projectID: UUID) {
        let prefix = "\(projectID.uuidString)|"
        completedInstallAllTargets = Set(completedInstallAllTargets.filter { !$0.hasPrefix(prefix) })
        failedAttemptCooldowns = failedAttemptCooldowns.filter { !$0.key.hasPrefix(prefix) }
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
        if !installAllTargets.isEmpty { return TimeInterval(preferences.pollIntervalSeconds) }
        guard preferences.automationEnabled else { return 60 * 60 }
        if !failedAttemptCooldowns.isEmpty || !failedVersionCheckDeviceUDIDs.isEmpty {
            return TimeInterval(preferences.pollIntervalSeconds)
        }

        let enabledProjects = projects.filter(\.isEnabled)
        guard !enabledProjects.isEmpty else { return 60 * 60 }
        if enabledProjects.contains(where: { $0.bundleIdentifier == nil }) {
            return TimeInterval(preferences.pollIntervalSeconds)
        }

        var nextDates: [Date] = []
        for project in enabledProjects {
            let targetDeviceUDIDs: [String?]
            if project.isMacOSApplication {
                targetDeviceUDIDs = [ManagedProject.localMacInstallationTargetID]
            } else {
                let selectedDevices = selectedInstallableDevices(for: project)
                targetDeviceUDIDs = selectedDevices.isEmpty
                    ? [nil]
                    : selectedDevices.map { Optional($0.udid) }
            }

            for deviceUDID in targetDeviceUDIDs {
                let installationRecord = deviceUDID.flatMap {
                    lastInstallationRecord(for: project.id, deviceUDID: $0)
                }
                if !project.isMacOSApplication,
                   project.installMethod == .xcodebuild,
                   installationRecord != nil,
                   installationRecord?.profileExpirationWasChecked != true {
                    return TimeInterval(preferences.pollIntervalSeconds)
                }
                guard let lastInstalledAt = installationRecord?.installedAt
                    ?? lastInstallation(for: project.id, deviceUDID: deviceUDID),
                let nextDate = SchedulingPolicy.nextInstallationDate(
                    lastInstalledAt: lastInstalledAt,
                    profileExpirationDate: installationRecord?.profileExpirationDate,
                    intervalDays: preferences.reinstallAfterDays
                )
                else {
                    return TimeInterval(preferences.pollIntervalSeconds)
                }
                nextDates.append(nextDate)
            }
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
