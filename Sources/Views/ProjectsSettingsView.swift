import AppKit
import SwiftUI

struct ProjectsSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection: Set<UUID> = []
    @State private var showsRemoveConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Managed applications")
                    .font(.title2.bold())
                Text("Add the source folder of each iOS application. An install script is optional.")
                    .foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top])
            .padding(.bottom, 12)

            applicationTable
                .padding(.horizontal)

            actionBar
                .padding(.horizontal)

            if let selectedProject {
                Divider().padding(.top, 12)
                projectDetails(selectedProject)
            } else {
                Text("Select an application to edit its build settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 100)
            }
        }
        .confirmationDialog(
            Text("Remove application?"),
            isPresented: $showsRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                let selectedIDs = selection
                selectedIDs.forEach(model.removeProject(id:))
                selection = []
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The source folder and its files will not be deleted.")
        }
    }

    private var applicationTable: some View {
        Table(model.projects, selection: $selection) {
            TableColumn("Application") { project in
                HStack(spacing: 9) {
                    ProjectIconView(project: project, size: 30, showsStatus: true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(project.displayName)
                            .fontWeight(.medium)
                            .lineLimit(1)
                        Text(project.folderPath)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 3)
            }
            .width(min: 235, ideal: 320)

            TableColumn("Version") { project in
                Text(project.versionDisplay)
                    .monospacedDigit()
            }
            .width(min: 90, ideal: 110)

            TableColumn("Last installed") { project in
                Text(lastInstalledText(for: project))
                    .foregroundStyle(.secondary)
            }
            .width(min: 145, ideal: 170)

            TableColumn("Status") { project in
                Label(
                    project.isEnabled ? L10n.text("Enabled") : L10n.text("Paused"),
                    systemImage: project.isEnabled ? "checkmark.circle.fill" : "pause.circle"
                )
                .foregroundStyle(project.isEnabled ? .green : .secondary)
                .labelStyle(.titleAndIcon)
            }
            .width(min: 95, ideal: 110)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .frame(minHeight: 185, idealHeight: 250, maxHeight: 300)
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(.separator, lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private var actionBar: some View {
        HStack(spacing: 0) {
            Button(action: chooseProjectFolder) {
                if model.isDiscoveringProject {
                    ProgressView().controlSize(.small).frame(width: 20)
                } else {
                    Image(systemName: "plus")
                }
            }
            .help("Add application…")
            .disabled(model.isDiscoveringProject || model.progress != nil)

            Divider().frame(height: 20).padding(.horizontal, 6)

            Button {
                showsRemoveConfirmation = true
            } label: {
                Image(systemName: "minus")
            }
            .help("Remove")
            .disabled(selection.isEmpty || model.progress != nil)

            Divider().frame(height: 20).padding(.horizontal, 10)

            Button {
                model.installAll()
            } label: {
                Label("Install All Now", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(model.projects.filter(\.isEnabled).isEmpty || model.progress != nil)

            if model.pendingInstallAllCount > 0 {
                Text(L10n.format("Waiting to install %d application(s)", model.pendingInstallAllCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 10)
            }

            Spacer()
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func projectDetails(_ project: ManagedProject) -> some View {
        Form {
            Section {
                HStack {
                    Toggle(
                        "Enabled",
                        isOn: Binding(
                            get: { project.isEnabled },
                            set: { value in model.updateProject(id: project.id) { $0.isEnabled = value } }
                        )
                    )
                    Spacer()
                    Button {
                        model.installNow(projectID: project.id)
                    } label: {
                        Label("Install now", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.selectedInstallableDevices(for: project).isEmpty || model.progress != nil)

                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([project.folderURL])
                    } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                }

                Picker(
                    "Installation method",
                    selection: Binding(
                        get: { project.installMethod },
                        set: { value in model.updateProject(id: project.id) { $0.installMethod = value } }
                    )
                ) {
                    if project.installScriptPath != nil {
                        Text(InstallMethod.installScript.title).tag(InstallMethod.installScript)
                    }
                    Text(InstallMethod.xcodebuild.title).tag(InstallMethod.xcodebuild)
                }

                if project.installMethod == .xcodebuild {
                    Picker(
                        "Scheme",
                        selection: Binding(
                            get: { project.scheme },
                            set: { model.setProjectScheme($0, for: project.id) }
                        )
                    ) {
                        ForEach(project.availableSchemes, id: \.self) { Text($0).tag($0) }
                    }

                    Picker(
                        "Configuration",
                        selection: Binding(
                            get: { project.configuration },
                            set: { model.setProjectConfiguration($0, for: project.id) }
                        )
                    ) {
                        ForEach(project.availableConfigurations, id: \.self) { Text($0).tag($0) }
                    }
                }
            }

            Section("Install on devices") {
                HStack {
                    LabeledContent("Supported devices") {
                        HStack(spacing: 6) {
                            if model.isRefreshingCompatibility(for: project.id) {
                                ProgressView().controlSize(.small)
                            }
                            Text(project.deviceCompatibilityDescription)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button {
                        model.refreshNow()
                    } label: {
                        Label("Refresh devices", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isRefreshingDevices || model.progress != nil)
                }

                Text("Only devices supported by the selected Xcode scheme are shown. Selection is saved separately for this application.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                let compatibleDevices = model.compatibleConnectedDevices(for: project)
                if compatibleDevices.isEmpty {
                    Label("No compatible iPhone or iPad is currently connected.", systemImage: "iphone.slash")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(compatibleDevices) { device in
                        Toggle(
                            isOn: Binding(
                                get: { model.isDeviceInstallationEnabled(device.udid, for: project.id) },
                                set: { model.setDeviceInstallationEnabled($0, deviceUDID: device.udid, for: project.id) }
                            )
                        ) {
                            HStack {
                                Label(device.name, systemImage: device.symbolName)
                                Spacer()
                                Text(L10n.format("%@ · %@", device.model ?? device.platformDescription, device.connectionDescription))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 245)
    }

    private var selectedProject: ManagedProject? {
        guard let id = selection.first else { return nil }
        return model.projects.first { $0.id == id }
    }

    private func chooseProjectFolder() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("Choose an iOS application folder")
        panel.prompt = L10n.text("Add")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK, let folderURL = panel.url else { return }
        Task {
            await model.addProject(folderURL: folderURL)
            if let added = model.projects.first(where: { $0.folderPath == folderURL.standardizedFileURL.path }) {
                selection = [added.id]
            }
        }
    }

    private func lastInstalledText(for project: ManagedProject) -> String {
        guard let date = model.lastInstallation(for: project.id) else { return L10n.text("Never") }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
