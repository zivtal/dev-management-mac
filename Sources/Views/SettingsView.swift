import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView(selection: $model.selectedSettingsSection) {
            GeneralSettingsView()
                .environmentObject(model)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsSection.general)

            ProjectsSettingsView()
                .environmentObject(model)
                .tabItem { Label("Applications", systemImage: "app.badge") }
                .tag(SettingsSection.applications)

            PublishingSettingsView()
                .environmentObject(model)
                .tabItem { Label("Publishing", systemImage: "paperplane") }
                .tag(SettingsSection.publishing)

            SandboxTestersSettingsView()
                .environmentObject(model)
                .tabItem { Label("Sandbox", systemImage: "testtube.2") }
                .tag(SettingsSection.sandbox)

            ActivityView()
                .environmentObject(model)
                .tabItem { Label("Activity", systemImage: "list.bullet.rectangle") }
                .tag(SettingsSection.activity)

            DevicesSettingsView()
                .environmentObject(model)
                .tabItem { Label("Devices", systemImage: "iphone.and.arrow.forward") }
                .tag(SettingsSection.devices)
        }
        .frame(minWidth: 820, idealWidth: 900, minHeight: 620, idealHeight: 720)
        .tint(.blue)
        .background(SettingsWindowConfigurator())
        .onAppear {
            model.setSettingsWindowOpen(true)
        }
        .onDisappear {
            model.setSettingsWindowOpen(false)
        }
        .alert(
            Text("Something went wrong"),
            isPresented: Binding(
                get: { model.presentedError != nil },
                set: { if !$0 { model.presentedError = nil } }
            ),
            actions: { Button("OK") { model.presentedError = nil } },
            message: { Text(model.presentedError ?? "") }
        )
    }
}

private struct SettingsWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> SettingsWindowSizingView {
        SettingsWindowSizingView()
    }

    func updateNSView(_ nsView: SettingsWindowSizingView, context: Context) {}
}

private final class SettingsWindowSizingView: NSView {
    private static let verticalScreenInset: CGFloat = 96

    private weak var configuredWindow: NSWindow?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, configuredWindow !== window else { return }
        configuredWindow = window

        DispatchQueue.main.async { [weak window] in
            guard let window, let screen = window.screen ?? NSScreen.main else { return }
            let visibleFrame = screen.visibleFrame
            let targetHeight = max(
                window.frame.height,
                visibleFrame.height - Self.verticalScreenInset
            )
            let targetWidth = max(window.frame.width, min(900, visibleFrame.width * 0.8))
            let targetSize = NSSize(
                width: min(targetWidth, visibleFrame.width),
                height: min(targetHeight, visibleFrame.height)
            )

            var targetFrame = window.frame
            targetFrame.size = targetSize
            targetFrame.origin.x = visibleFrame.midX - targetSize.width / 2
            targetFrame.origin.y = visibleFrame.midY - targetSize.height / 2
            window.setFrame(targetFrame, display: true)
        }
    }
}

private struct GeneralSettingsView: View {
    private enum BackupPasswordRequest: Identifiable {
        case export
        case importEncrypted(Data)

        var id: String {
            switch self {
            case .export: "export"
            case .importEncrypted: "import"
            }
        }
    }

    @EnvironmentObject private var model: AppModel
    @State private var backupPasswordRequest: BackupPasswordRequest?
    @State private var pendingImport: SettingsArchive?
    @State private var backupMessage: String?

    var body: some View {
        Form {
            Section("Automatic installation") {
                Toggle("Check and install automatically", isOn: $model.preferences.automationEnabled)
                Stepper(value: $model.preferences.reinstallAfterDays, in: 1...30) {
                    LabeledContent("Reinstall interval") {
                        Text(L10n.format("%d days", model.preferences.reinstallAfterDays))
                    }
                }
                Text("The interval is tracked separately for each application and each selected iPhone or iPad. A newly added application is installed at the next connection. Development-signed apps are rebuilt three days before their provisioning profile expires.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Background operation") {
                Toggle(
                    "Open Development Management at login",
                    isOn: Binding(
                        get: { model.preferences.launchAtLogin },
                        set: { model.setLaunchAtLogin($0) }
                    )
                )
                Text("The application has no Dock window and remains available from the menu bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(L10n.text("settings.launch_at_login.default_description"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Notifications") {
                Toggle(
                    "Notify after every successful application installation",
                    isOn: Binding(
                        get: { model.preferences.notificationsEnabled != false },
                        set: { model.preferences.notificationsEnabled = $0 }
                    )
                )
                Text("Each notification includes the application, device name and model, and connection type.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Backup") {
                HStack {
                    Button("Export Settings…") { backupPasswordRequest = .export }
                    Button("Import Settings…") { chooseImportFile() }
                        .disabled(model.hasActiveWork)
                }
                Text("The export includes every preference, the application list with each application's settings, publishing and sandbox settings, and all stored credentials, including OpenAI and App Store Connect private keys. Importing replaces the current configuration.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let backupMessage {
                    Text(backupMessage)
                        .font(.caption)
                        .textSelection(.enabled)
                }
            }

            Section("About") {
                LabeledContent("Version") {
                    Text(appVersion).monospacedDigit()
                }
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
        .sheet(item: $backupPasswordRequest) { request in
            switch request {
            case .export:
                SettingsBackupPasswordSheet(mode: .export) { password in
                    DispatchQueue.main.async { exportSettings(password: password) }
                }
            case .importEncrypted(let data):
                SettingsBackupPasswordSheet(mode: .importEncrypted) { password in
                    DispatchQueue.main.async { decodeImport(data: data, password: password) }
                }
            }
        }
        .confirmationDialog(
            "Replace current settings?",
            isPresented: Binding(
                get: { pendingImport != nil },
                set: { if !$0 { pendingImport = nil } }
            ),
            presenting: pendingImport
        ) { archive in
            Button("Import and Replace", role: .destructive) {
                applyImport(archive)
            }
            Button("Cancel", role: .cancel) {}
        } message: { archive in
            Text(L10n.format(
                "All current preferences, applications, publishing settings, and stored credentials will be replaced by the export from %@ containing %d applications. The activity log is kept.",
                archive.exportedAt.formatted(date: .abbreviated, time: .shortened),
                archive.projects.count
            ))
        }
    }

    private func exportSettings(password: String?) {
        let panel = NSSavePanel()
        panel.title = L10n.text("Export Development Management settings")
        panel.prompt = L10n.text("Export")
        panel.nameFieldStringValue = SettingsTransferService.defaultExportFilename()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.exportSettings(to: url, password: password)
            backupMessage = password?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? L10n.format("Encrypted settings exported to %@.", url.path)
                : L10n.format("Unencrypted settings exported to %@. Keep this file private; it contains your keys.", url.path)
        } catch {
            model.presentedError = error.localizedDescription
        }
    }

    private func chooseImportFile() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("Choose a Development Management settings export")
        panel.prompt = L10n.text("Import")
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            if SettingsTransferService.isEncrypted(data) {
                backupPasswordRequest = .importEncrypted(data)
            } else {
                decodeImport(data: data, password: nil)
            }
        } catch {
            model.presentedError = error.localizedDescription
        }
    }

    private func decodeImport(data: Data, password: String?) {
        do {
            pendingImport = try SettingsTransferService.decode(data, password: password)
        } catch {
            model.presentedError = error.localizedDescription
        }
    }

    private func applyImport(_ archive: SettingsArchive) {
        do {
            try model.importSettings(archive)
            backupMessage = L10n.format(
                "Settings imported: %d applications restored.",
                archive.projects.count
            )
        } catch {
            model.presentedError = error.localizedDescription
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return L10n.format("%@ (build %@)", version, build)
    }
}

private struct DevicesSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Connected devices")
                        .font(.title2.bold())
                    Text("Choose installation devices separately for each application in the Applications tab.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.refreshNow()
                } label: {
                    Label("Refresh devices", systemImage: "arrow.clockwise")
                }
                .disabled(model.isRefreshingDevices)
            }

            if model.connectedDevices.isEmpty {
                ContentUnavailableView(
                    "No connected devices",
                    systemImage: "iphone.slash",
                    description: Text("USB and Wi‑Fi connections are supported. For Wi‑Fi, enable Connect via network for the device in Xcode.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(model.connectedDevices) {
                    TableColumn("Device") { device in
                        Label(device.name, systemImage: device.symbolName)
                            .fontWeight(.medium)
                    }
                    .width(min: 150, ideal: 190)

                    TableColumn("Model") { device in
                        Text(device.model ?? L10n.text("Unknown"))
                    }
                    .width(min: 170, ideal: 220)

                    TableColumn("System") { device in
                        Text(device.platformDescription)
                    }
                    .width(min: 75, ideal: 90)

                    TableColumn("Connection") { device in
                        Text(device.connectionDescription)
                    }
                    .width(min: 90, ideal: 110)

                    TableColumn("Installation") { device in
                        if device.supportsAppInstallation {
                            Text("Choose per application")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Companion device")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .width(min: 115, ideal: 140)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .padding()
    }
}

private struct SettingsBackupPasswordSheet: View {
    enum Mode {
        case export
        case importEncrypted
    }

    let mode: Mode
    let onContinue: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirmation = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text(mode == .export ? "Protect the settings export" : "Enter the export password"))
                .font(.title3.bold())
            Text(L10n.text(mode == .export
                ? "The file will contain your OpenAI and App Store Connect private keys and other credentials. Enter a password to encrypt it, or leave it blank to save a plain JSON file."
                : "This settings file is encrypted. Enter the password that was used when it was exported."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Password", text: $password)
                .textContentType(.password)
            if mode == .export {
                SecureField("Confirm password", text: $confirmation)
                    .textContentType(.password)
                if !passwordsMatch {
                    Text("The passwords do not match.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.text(mode == .export ? "Export…" : "Import")) {
                    let value = password.isEmpty ? nil : password
                    dismiss()
                    onContinue(value)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canContinue)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private var passwordsMatch: Bool {
        mode != .export || password == confirmation
    }

    private var canContinue: Bool {
        switch mode {
        case .export: passwordsMatch
        case .importEncrypted: !password.isEmpty
        }
    }
}
