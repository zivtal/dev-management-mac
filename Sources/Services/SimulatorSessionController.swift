import Foundation

/// Drives one project's live simulator session: boot, build, install, launch,
/// then watch the sources and rebuild on changes, with live control over the
/// simulator while the app runs.
@MainActor
final class SimulatorSessionController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case booting
        case building
        case installing
        case launching
        case running
        case failed

        var isActivelyWorking: Bool {
            switch self {
            case .booting, .building, .installing, .launching: true
            case .idle, .running, .failed: false
            }
        }
    }

    private static let outputLimit = 30_000

    @Published private(set) var phase = Phase.idle
    @Published private(set) var statusMessage = ""
    @Published private(set) var buildCount = 0
    @Published private(set) var logOutput = ""
    @Published private(set) var availableDevices: [SimulatorDevice] = []
    @Published private(set) var isRefreshingDevices = false
    @Published private(set) var appliedSettings: SimulatorRunSettings?
    @Published private(set) var activeDevice: SimulatorDevice?
    @Published private(set) var isSessionActive = false

    private(set) var project: ManagedProject
    private let simulatorService: SimulatorService
    private let installationService: InstallationService
    private let derivedDataURL: URL

    private var sessionTask: Task<Void, Never>?
    private var watcher: SourceChangeWatcher?
    private var buildProduct: SimulatorBuildProduct?
    private var pendingRebuild = false

    init(
        project: ManagedProject,
        simulatorService: SimulatorService,
        installationService: InstallationService,
        derivedDataURL: URL
    ) {
        self.project = project
        self.simulatorService = simulatorService
        self.installationService = installationService
        self.derivedDataURL = derivedDataURL
    }

    func updateProject(_ project: ManagedProject) {
        self.project = project
    }

    func refreshDevices() async {
        isRefreshingDevices = true
        defer { isRefreshingDevices = false }
        do {
            let devices = try await simulatorService.availableDevices()
            availableDevices = SimulatorDevice.compatibleIOSDevices(
                in: devices,
                supportedFamilies: project.effectiveSupportedDeviceFamilies
            )
        } catch {
            availableDevices = []
            appendOutput(L10n.format(
                "Could not list the available Simulators: %@\n",
                error.localizedDescription
            ))
        }
    }

    func start(settings: SimulatorRunSettings) {
        guard !isSessionActive else { return }
        isSessionActive = true
        logOutput = ""
        buildCount = 0
        pendingRebuild = false
        appliedSettings = settings
        startWatcher()
        runSession { [weak self] in
            try await self?.prepareDeviceAndRun(settings: settings, reinstallOnly: false)
        }
    }

    /// Stops watching and rebuilding. The simulator and the app keep running,
    /// matching run-emulator.sh's Ctrl-C behavior.
    func stop() {
        sessionTask?.cancel()
        sessionTask = nil
        watcher?.stop()
        watcher = nil
        pendingRebuild = false
        isSessionActive = false
        phase = .idle
        statusMessage = L10n.text("Session stopped; the app keeps running in the Simulator.")
    }

    func rebuildNow() {
        guard let settings = appliedSettings else { return }
        guard sessionTask == nil else {
            pendingRebuild = true
            return
        }
        runSession { [weak self] in
            try await self?.buildInstallAndLaunch(settings: settings)
        }
    }

    /// Applies changed settings to the live session: GPS updates in place,
    /// a device change installs the existing build on the new simulator, and
    /// launch-time changes (date/time, language, variable name) relaunch.
    func apply(settings: SimulatorRunSettings) {
        guard isSessionActive, let previous = appliedSettings else {
            appliedSettings = settings
            return
        }
        appliedSettings = settings
        guard sessionTask == nil else {
            pendingRebuild = true
            return
        }

        let deviceChanged = settings.deviceUDID != previous.deviceUDID
        let locationChanged = settings.locationArgument != previous.locationArgument
        let launchChanged = settings.launchArguments != previous.launchArguments
            || settings.launchEnvironment(forScheme: project.scheme)
                != previous.launchEnvironment(forScheme: project.scheme)

        if deviceChanged {
            runSession { [weak self] in
                try await self?.prepareDeviceAndRun(settings: settings, reinstallOnly: true)
            }
        } else if launchChanged {
            runSession { [weak self] in
                try await self?.applyLocationIfNeeded(settings: settings, changed: locationChanged)
                try await self?.launchApplication(settings: settings)
            }
        } else if locationChanged {
            runSession { [weak self] in
                try await self?.applyLocationIfNeeded(settings: settings, changed: true)
            }
        }
    }

    func handleSourceChange() {
        guard isSessionActive else { return }
        guard sessionTask == nil else {
            pendingRebuild = true
            return
        }
        appendOutput(L10n.text("Source change detected; rebuilding.\n"))
        rebuildNow()
    }

    private func startWatcher() {
        watcher?.stop()
        watcher = SourceChangeWatcher(directoryURL: project.folderURL) { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleSourceChange()
            }
        }
        if watcher == nil {
            appendOutput(L10n.text("Could not watch the project folder; automatic rebuilds are unavailable.\n"))
        }
    }

    private func runSession(_ work: @escaping () async throws -> Void) {
        sessionTask = Task { [weak self] in
            do {
                try await work()
            } catch is CancellationError {
                // Stopping the session cancels in-flight work silently.
            } catch {
                self?.phase = .failed
                self?.statusMessage = error.localizedDescription
                self?.appendOutput("\n" + error.localizedDescription + "\n")
                self?.appendOutput(L10n.text("Fix the error and save a watched file to try again.\n"))
            }
            self?.sessionTask = nil
            self?.runPendingRebuildIfNeeded()
        }
    }

    private func runPendingRebuildIfNeeded() {
        guard pendingRebuild, isSessionActive else { return }
        pendingRebuild = false
        appendOutput(L10n.text("A change arrived during the build; refreshing again.\n"))
        rebuildNow()
    }

    private func prepareDeviceAndRun(
        settings: SimulatorRunSettings,
        reinstallOnly: Bool
    ) async throws {
        let device = try await resolveDevice(settings: settings)
        activeDevice = device
        phase = .booting
        statusMessage = L10n.format("Booting %@…", device.name)
        if !device.isBooted {
            try await simulatorService.boot(udid: device.udid)
        }
        try await simulatorService.waitUntilBooted(udid: device.udid)
        await simulatorService.openSimulatorApplication(udid: device.udid)
        appendOutput(L10n.format("Using Simulator %@ (%@).\n", device.name, device.udid))
        try await applyLocationIfNeeded(settings: settings, changed: settings.usesLocation)
        if reinstallOnly, buildProduct != nil {
            try await installAndLaunch(settings: settings)
        } else {
            try await buildInstallAndLaunch(settings: settings)
        }
    }

    private func resolveDevice(settings: SimulatorRunSettings) async throws -> SimulatorDevice {
        let devices = try await simulatorService.availableDevices()
        availableDevices = SimulatorDevice.compatibleIOSDevices(
            in: devices,
            supportedFamilies: project.effectiveSupportedDeviceFamilies
        )
        if let requestedUDID = settings.deviceUDID,
           let device = devices.first(where: { $0.udid == requestedUDID }) {
            return device
        }
        guard let device = SimulatorDevice.preferredDevice(
            in: devices,
            supportedFamilies: project.effectiveSupportedDeviceFamilies
        ) else {
            throw SimulatorSessionError.noAvailableSimulator
        }
        return device
    }

    private func buildInstallAndLaunch(settings: SimulatorRunSettings) async throws {
        guard let deviceUDID = activeDeviceUDID(settings: settings) else {
            throw SimulatorSessionError.noAvailableSimulator
        }
        phase = .building
        buildCount += 1
        statusMessage = L10n.format("Building %@ (refresh %d)…", project.displayName, buildCount)
        let coalescer = InstallationEventCoalescer { [weak self] batch in
            Task { @MainActor [weak self] in
                self?.receive(batch)
            }
        }
        do {
            buildProduct = try await installationService.buildForSimulator(
                project: project,
                simulatorUDID: deviceUDID,
                derivedDataURL: derivedDataURL,
                eventHandler: { coalescer.receive($0) }
            )
        } catch {
            receive(coalescer.finish())
            throw error
        }
        receive(coalescer.finish())
        try await installAndLaunch(settings: settings)
    }

    private func installAndLaunch(settings: SimulatorRunSettings) async throws {
        guard let deviceUDID = activeDeviceUDID(settings: settings),
              let product = buildProduct else {
            throw SimulatorSessionError.noAvailableSimulator
        }
        guard let bundleIdentifier = product.bundleIdentifier else {
            throw SimulatorSessionError.unknownBundleIdentifier
        }
        phase = .installing
        statusMessage = L10n.format("Installing %@…", project.displayName)
        await simulatorService.terminate(udid: deviceUDID, bundleIdentifier: bundleIdentifier)
        try await simulatorService.install(udid: deviceUDID, applicationURL: product.applicationURL)
        try await launchApplication(settings: settings)
    }

    private func launchApplication(settings: SimulatorRunSettings) async throws {
        guard let deviceUDID = activeDeviceUDID(settings: settings),
              let bundleIdentifier = buildProduct?.bundleIdentifier else {
            throw SimulatorSessionError.unknownBundleIdentifier
        }
        phase = .launching
        statusMessage = L10n.format("Launching %@…", project.displayName)
        let launchOutput = try await simulatorService.launch(
            udid: deviceUDID,
            bundleIdentifier: bundleIdentifier,
            arguments: settings.launchArguments,
            environment: settings.launchEnvironment(forScheme: project.scheme)
        )
        if !launchOutput.isEmpty {
            appendOutput(L10n.format("Running %@.\n", launchOutput))
        }
        if let simulatedNow = settings.simulatedNowValue() {
            appendOutput(L10n.format(
                "The Debug app will treat %@ as the current date.\n",
                simulatedNow
            ))
        }
        phase = .running
        statusMessage = L10n.text("Watching for changes.")
    }

    private func applyLocationIfNeeded(
        settings: SimulatorRunSettings,
        changed: Bool
    ) async throws {
        guard changed, let deviceUDID = activeDeviceUDID(settings: settings) else { return }
        guard settings.usesLocation,
              let latitude = settings.latitude,
              let longitude = settings.longitude else {
            await simulatorService.clearLocation(udid: deviceUDID)
            return
        }
        try await simulatorService.setLocation(
            udid: deviceUDID,
            latitude: latitude,
            longitude: longitude
        )
        appendOutput(L10n.format("Simulator location set to %@.\n", "\(latitude),\(longitude)"))
    }

    private func activeDeviceUDID(settings: SimulatorRunSettings) -> String? {
        activeDevice?.udid
    }

    private func receive(_ batch: InstallationEventBatch) {
        guard !batch.output.isEmpty else { return }
        appendOutput(batch.output)
    }

    private func appendOutput(_ text: String) {
        guard !text.isEmpty else { return }
        logOutput.append(text)
        if logOutput.count > Self.outputLimit {
            logOutput = "…\n" + String(logOutput.suffix(Self.outputLimit))
        }
    }
}

enum SimulatorSessionError: LocalizedError {
    case noAvailableSimulator
    case unknownBundleIdentifier

    var errorDescription: String? {
        switch self {
        case .noAvailableSimulator:
            L10n.text("No compatible iOS Simulator is available. Install a Simulator runtime from Xcode Settings > Components.")
        case .unknownBundleIdentifier:
            L10n.text("The built app's bundle identifier could not be determined.")
        }
    }
}
