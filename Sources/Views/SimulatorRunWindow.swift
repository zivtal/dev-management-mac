import AppKit
import SwiftUI

@MainActor
final class SimulatorRunWindowPresenter {
    static let shared = SimulatorRunWindowPresenter()

    private var windowControllers = PerProjectWindowRegistry<NSWindowController>()
    private var closeObservers: [UUID: NSObjectProtocol] = [:]

    private init() {}

    func show(model: AppModel, projectID: UUID) {
        guard let project = model.projects.first(where: { $0.id == projectID }),
              let session = model.simulatorSession(for: projectID) else {
            close(projectID: projectID)
            return
        }
        if let existingController = windowControllers[projectID] {
            existingController.window?.title = windowTitle(for: project)
            bringToFront(existingController)
            return
        }
        let rootView = SimulatorRunWindowView(projectID: projectID, session: session)
            .environmentObject(model)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = windowTitle(for: project)
        panel.contentViewController = NSHostingController(rootView: rootView)
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 640, height: 560)
        if let screen = NSApplication.shared.keyWindow?.screen
            ?? NSScreen.main
            ?? NSScreen.screens.first {
            panel.setFrame(
                PerProjectWindowPlacement.cascadedFrame(
                    size: panel.frame.size,
                    in: screen.visibleFrame,
                    openWindowCount: windowControllers.projectIDs.count
                ),
                display: false
            )
        } else {
            panel.center()
        }
        let windowController = NSWindowController(window: panel)
        windowControllers.register(windowController, for: projectID)
        closeObservers[projectID] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { [weak self, weak windowController, weak model] _ in
            MainActor.assumeIsolated {
                guard let self, let windowController else { return }
                self.removeWindow(projectID: projectID, matching: windowController)
                model?.simulatorSessions[projectID]?.stop()
            }
        }
        bringToFront(windowController)
    }

    func close(projectID: UUID) {
        guard let controller = windowControllers[projectID] else { return }
        removeWindow(projectID: projectID, matching: controller)
        controller.close()
    }

    private func windowTitle(for project: ManagedProject) -> String {
        L10n.format("%@ — Simulator", project.displayName)
    }

    private func bringToFront(_ windowController: NSWindowController) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        windowController.showWindow(nil)
        windowController.window?.makeKeyAndOrderFront(nil)
    }

    private func removeWindow(projectID: UUID, matching controller: NSWindowController) {
        guard windowControllers.remove(projectID: projectID, matching: controller) != nil else { return }
        if let observer = closeObservers.removeValue(forKey: projectID) {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

struct SimulatorRunWindowView: View {
    let projectID: UUID
    @ObservedObject var session: SimulatorSessionController
    @EnvironmentObject private var model: AppModel

    @State private var selectedDeviceUDID: String?
    @State private var isLocationEnabled = false
    @State private var latitudeText = ""
    @State private var longitudeText = ""
    @State private var isDateSimulated = false
    @State private var simulatedDate = Date()
    @State private var isTimeSimulated = false
    @State private var simulatedTime = Date()
    @State private var debugNowVariableName = ""
    @State private var selectedLanguage: String?
    @State private var availableLanguages: [String] = []
    @State private var didLoadSettings = false

    private static let automaticDeviceTag = "automatic"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    deviceSection
                    locationSection
                    dateTimeSection
                    languageSection
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            statusBar
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            logView
                .frame(minHeight: 140)
            Divider()
            controlBar
                .padding(16)
        }
        .task {
            loadSettingsIfNeeded()
            await session.refreshDevices()
            await loadLanguages()
        }
    }

    private var project: ManagedProject? {
        model.projects.first(where: { $0.id == projectID })
    }

    private var deviceSection: some View {
        GroupBox {
            HStack(spacing: 8) {
                Picker(selection: deviceSelectionBinding) {
                    Text("Automatic (booted or newest iPhone)")
                        .tag(Self.automaticDeviceTag)
                    ForEach(session.availableDevices) { device in
                        Text(deviceTitle(device)).tag(device.udid)
                    }
                } label: {
                    Text("Simulator device")
                }
                if session.isRefreshingDevices {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await session.refreshDevices() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh the Simulator list")
                    .accessibilityLabel(L10n.text("Refresh the Simulator list"))
                }
            }
            .padding(4)
        } label: {
            Label("Device", systemImage: "iphone")
        }
    }

    private var locationSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Set the Simulator location", isOn: $isLocationEnabled)
                if isLocationEnabled {
                    HStack(spacing: 8) {
                        TextField("Latitude", text: $latitudeText, prompt: Text(verbatim: "34.6937"))
                        TextField("Longitude", text: $longitudeText, prompt: Text(verbatim: "135.5023"))
                    }
                    .textFieldStyle(.roundedBorder)
                    if !isLocationInputValid {
                        Text("Enter a valid latitude,longitude pair.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Location", systemImage: "location.fill")
        }
    }

    private var dateTimeSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Simulate the current date (Debug builds only)", isOn: $isDateSimulated)
                if isDateSimulated {
                    DatePicker(
                        "Date",
                        selection: $simulatedDate,
                        displayedComponents: .date
                    )
                    Toggle("Also simulate the time of day", isOn: $isTimeSimulated)
                    if isTimeSimulated {
                        DatePicker(
                            "Time",
                            selection: $simulatedTime,
                            displayedComponents: .hourAndMinute
                        )
                    }
                    HStack(spacing: 8) {
                        Text("Environment variable")
                        TextField(
                            "Environment variable",
                            text: $debugNowVariableName,
                            prompt: Text(verbatim: defaultVariableName)
                        )
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .font(.body.monospaced())
                    }
                    Text("The app reads this variable in Debug builds to fake the current date.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Date & time", systemImage: "calendar.badge.clock")
        }
    }

    private var languageSection: some View {
        GroupBox {
            Picker(selection: languageSelectionBinding) {
                Text("Simulator default").tag("")
                ForEach(availableLanguages, id: \.self) { language in
                    Text(verbatim: language).tag(language)
                }
            } label: {
                Text("App language")
            }
            .padding(4)
        } label: {
            Label("Language", systemImage: "globe")
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if session.phase.isActivelyWorking {
                ProgressView().controlSize(.small)
            } else if session.phase == .running {
                Image(systemName: "play.circle.fill").foregroundStyle(.green)
            } else if session.phase == .failed {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else {
                Image(systemName: "pause.circle").foregroundStyle(.secondary)
            }
            Text(statusText)
                .font(.callout)
                .lineLimit(2)
            Spacer()
            if session.buildCount > 0 {
                Text(L10n.format("Refresh %d", session.buildCount))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(session.logOutput.isEmpty ? L10n.text("The build log appears here.") : session.logOutput)
                    .font(.caption.monospaced())
                    .foregroundStyle(session.logOutput.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .textSelection(.enabled)
                    .id("logEnd")
            }
            .background(.quaternary.opacity(0.4))
            .onChange(of: session.logOutput) {
                proxy.scrollTo("logEnd", anchor: .bottom)
            }
        }
    }

    private var controlBar: some View {
        HStack(spacing: 10) {
            if session.isSessionActive {
                Button(role: .destructive) {
                    session.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                Button {
                    saveSettings()
                    session.rebuildNow()
                } label: {
                    Label("Rebuild now", systemImage: "hammer.fill")
                }
                .disabled(session.phase.isActivelyWorking)
                Spacer()
                Button {
                    saveSettings()
                    session.apply(settings: currentSettings)
                } label: {
                    Label("Apply changes", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasUnappliedChanges || !isLocationInputValid)
            } else {
                Spacer()
                Button {
                    saveSettings()
                    session.start(settings: currentSettings)
                } label: {
                    Label("Run in Simulator", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isLocationInputValid)
            }
        }
    }

    private var statusText: String {
        switch session.phase {
        case .idle:
            session.statusMessage.isEmpty
                ? L10n.text("Ready to run in the Simulator.")
                : session.statusMessage
        case .booting, .building, .installing, .launching:
            session.statusMessage
        case .running:
            L10n.text("Running. Source changes rebuild and relaunch automatically.")
        case .failed:
            session.statusMessage
        }
    }

    private var defaultVariableName: String {
        project.map {
            SimulatorRunSettings.defaultDebugNowVariableName(forScheme: $0.scheme)
        } ?? "APP_DEBUG_NOW"
    }

    private var deviceSelectionBinding: Binding<String> {
        Binding(
            get: { selectedDeviceUDID ?? Self.automaticDeviceTag },
            set: { selectedDeviceUDID = $0 == Self.automaticDeviceTag ? nil : $0 }
        )
    }

    private var languageSelectionBinding: Binding<String> {
        Binding(
            get: { selectedLanguage ?? "" },
            set: { selectedLanguage = $0.isEmpty ? nil : $0 }
        )
    }

    private var isLocationInputValid: Bool {
        guard isLocationEnabled else { return true }
        guard let latitude = Double(latitudeText.trimmingCharacters(in: .whitespaces)),
              let longitude = Double(longitudeText.trimmingCharacters(in: .whitespaces)) else {
            return false
        }
        return SimulatorRunSettings.isValidCoordinate(latitude: latitude, longitude: longitude)
    }

    private var hasUnappliedChanges: Bool {
        guard let applied = session.appliedSettings else { return true }
        return currentSettings != applied
    }

    private var currentSettings: SimulatorRunSettings {
        var settings = SimulatorRunSettings()
        settings.deviceUDID = selectedDeviceUDID
        settings.isLocationEnabled = isLocationEnabled
        if isLocationEnabled {
            settings.latitude = Double(latitudeText.trimmingCharacters(in: .whitespaces))
            settings.longitude = Double(longitudeText.trimmingCharacters(in: .whitespaces))
        }
        if isDateSimulated {
            settings.simulatedDate = Self.dateFormatter.string(from: simulatedDate)
            if isTimeSimulated {
                settings.simulatedTime = Self.timeFormatter.string(from: simulatedTime)
            }
        }
        let variableName = debugNowVariableName.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.debugNowVariableName = variableName.isEmpty ? nil : variableName
        settings.language = selectedLanguage
        return settings
    }

    private func deviceTitle(_ device: SimulatorDevice) -> String {
        device.isBooted
            ? L10n.format("%@ (booted)", device.displayTitle)
            : device.displayTitle
    }

    private func loadSettingsIfNeeded() {
        guard !didLoadSettings else { return }
        didLoadSettings = true
        guard let saved = project?.simulatorRunSettings else { return }
        selectedDeviceUDID = saved.deviceUDID
        isLocationEnabled = saved.isLocationEnabled == true
        if let latitude = saved.latitude { latitudeText = "\(latitude)" }
        if let longitude = saved.longitude { longitudeText = "\(longitude)" }
        if let savedDate = saved.simulatedDate,
           let date = Self.dateFormatter.date(from: savedDate) {
            isDateSimulated = true
            simulatedDate = date
        }
        if let savedTime = saved.simulatedTime,
           let time = Self.timeFormatter.date(from: savedTime) {
            isTimeSimulated = true
            simulatedTime = time
        }
        debugNowVariableName = saved.debugNowVariableName ?? ""
        selectedLanguage = saved.language
    }

    private func saveSettings() {
        model.saveSimulatorRunSettings(currentSettings, projectID: projectID)
    }

    @MainActor
    private func loadLanguages() async {
        guard let project else { return }
        let locale = model.preferences.appStoreLocale?.nilIfEmpty ?? "en-US"
        let languages = await Task.detached(priority: .utility) {
            ProjectLocalizationDiscoveryService()
                .discover(project: project, defaultLocale: locale)
        }.value
        availableLanguages = languages
        if let selectedLanguage, !languages.contains(selectedLanguage) {
            availableLanguages.append(selectedLanguage)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
