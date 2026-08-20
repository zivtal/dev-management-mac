import AppKit
import CoreTransferable
import SwiftUI

struct ProjectsSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection: Set<UUID> = []
    @State private var showsRemoveConfirmation = false

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Managed applications")
                        .font(.title2.bold())
                    Text("Add the source folder of each iOS or macOS application. An install script is optional.")
                        .foregroundStyle(.secondary)
                }
                .padding([.horizontal, .top])
                .padding(.bottom, 12)

                applicationTable
                    .padding(.horizontal)

                actionBar
                    .padding(.horizontal)

                if let selectedProject {
                    Divider().padding(.top, 8)
                    GeometryReader { detailsGeometry in
                        projectDetails(selectedProject)
                            .frame(
                                width: detailsGeometry.size.width,
                                height: detailsGeometry.size.height
                            )
                    }
                    .frame(minHeight: 150)
                } else {
                    Text("Select an application to edit its build settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(
                width: geometry.size.width,
                height: geometry.size.height,
                alignment: .top
            )
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
        .onAppear {
            model.refreshDeveloperTeams()
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
                Toggle(
                    isOn: Binding(
                        get: { project.isEnabled },
                        set: { model.setProjectEnabled($0, projectID: project.id) }
                    )
                ) {
                    Text(project.isEnabled ? L10n.text("Enabled") : L10n.text("Paused"))
                        .foregroundStyle(project.isEnabled ? .green : .secondary)
                }
                .toggleStyle(.switch)
                .help(
                    project.isEnabled
                        ? L10n.text("Pause application installations")
                        : L10n.text("Resume application installations")
                )
            }
            .width(min: 120, ideal: 145)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .frame(minHeight: 120, idealHeight: 175, maxHeight: 220)
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
            .disabled(model.isDiscoveringProject || model.hasActiveWork)

            Divider().frame(height: 20).padding(.horizontal, 6)

            Button {
                showsRemoveConfirmation = true
            } label: {
                Image(systemName: "minus")
            }
            .help("Remove")
            .disabled(selection.isEmpty || model.hasActiveWork)

            Divider().frame(height: 20).padding(.horizontal, 10)

            Button {
                model.installAll()
            } label: {
                Label("Install All Now", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(model.projects.filter(\.isEnabled).isEmpty || model.hasActiveWork)

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
        VStack(alignment: .leading, spacing: 16) {
            projectConfigurationCard(project)
            Group {
                if project.isMacOSApplication {
                    macInstallationSection(project)
                } else {
                    deviceTargetsSection(project)
                }
            }
            .frame(maxHeight: .infinity)
            .layoutPriority(1)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func projectConfigurationCard(_ project: ManagedProject) -> some View {
        VStack(spacing: 0) {
            HStack {
                Toggle(
                    "Allow installations",
                    isOn: Binding(
                        get: { project.isEnabled },
                        set: { model.setProjectEnabled($0, projectID: project.id) }
                    )
                )
                .help(
                    project.isEnabled
                        ? L10n.text("Pause application installations")
                        : L10n.text("Resume application installations")
                )
                Spacer()
                Button {
                    model.installNow(projectID: project.id)
                } label: {
                    Label(
                        model.isInstallationQueued(for: project.id)
                            ? "Waiting for device connection"
                            : "Install now",
                        systemImage: model.isInstallationQueued(for: project.id)
                            ? "clock.arrow.circlepath"
                            : "arrow.clockwise"
                    )
                }
                .disabled(
                    !project.isEnabled
                        || !model.hasAvailableInstallationTarget(for: project)
                        || model.isInstallationQueued(for: project.id)
                        || model.hasActiveWork
                )

                if !project.isMacOSApplication {
                    Button {
                        PublishingWindowPresenter.shared.show(model: model, projectID: project.id)
                    } label: {
                        if model.publishingProgress?.projectID == project.id {
                            Label {
                                Text("Publishing…")
                            } icon: {
                                ProgressView().controlSize(.small)
                            }
                        } else {
                            Label("Publish…", systemImage: "paperplane.fill")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.hasActiveWork)
                    .help("Build, upload, and submit this application to the App Store")
                }

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([project.folderURL])
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)

            settingsDivider

            settingsPickerRow("Platform") {
                HStack {
                    Text(project.effectiveApplicationPlatform.title)
                    Spacer()
                    if model.isRefreshingCompatibility(for: project.id) {
                        ProgressView().controlSize(.small)
                    }
                }
            }

            settingsDivider

            settingsPickerRow("Build method") {
                Text("Direct Xcode build")
            }

            settingsDivider

            settingsPickerRow("Scheme") {
                Picker(
                    "Scheme",
                    selection: Binding(
                        get: { project.scheme },
                        set: { model.setProjectScheme($0, for: project.id) }
                    )
                ) {
                    ForEach(project.availableSchemes, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
            }

            settingsDivider

            settingsPickerRow("Configuration") {
                Picker(
                    "Configuration",
                    selection: Binding(
                        get: { project.configuration },
                        set: { model.setProjectConfiguration($0, for: project.id) }
                    )
                ) {
                    ForEach(project.availableConfigurations, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
            }

            settingsDivider

            settingsPickerRow("Signing team") {
                HStack(spacing: 8) {
                        Picker(
                            "Signing team",
                            selection: Binding(
                                get: { project.signingTeamID ?? "" },
                                set: { teamID in
                                    model.updateProject(id: project.id) {
                                        $0.signingTeamID = teamID.isEmpty ? nil : teamID
                                    }
                                }
                            )
                        ) {
                            Text("Automatic").tag("")
                            ForEach(model.developerTeams) { team in
                                Text(team.displayName).tag(team.id)
                            }
                            if let selectedTeamID = project.signingTeamID,
                               !model.developerTeams.contains(where: { $0.id == selectedTeamID }) {
                                Text(L10n.format("Team %@", selectedTeamID)).tag(selectedTeamID)
                            }
                        }
                        .labelsHidden()

                        Button {
                            model.refreshDeveloperTeams()
                        } label: {
                            if model.isRefreshingDeveloperTeams {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .buttonStyle(.borderless)
                        .help("Refresh signing teams")
                        .disabled(model.isRefreshingDeveloperTeams || model.hasActiveWork)
                }
            }

            settingsDivider

            Text(signingTeamGuidance(for: project))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
        }
        .background(settingsCardBackground)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func deviceTargetsSection(_ project: ManagedProject) -> some View {
        let compatibleDevices = model.compatibleConnectedDevices(for: project)

        return VStack(alignment: .leading, spacing: 8) {
            Text("Install on devices")
                .font(.headline)
                .padding(.horizontal, 2)

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text("Supported devices")
                        .fontWeight(.medium)
                    Spacer()
                    if model.isRefreshingCompatibility(for: project.id) {
                        ProgressView().controlSize(.small)
                    }
                    Text(project.deviceCompatibilityDescription)
                        .foregroundStyle(.secondary)
                    Button {
                        model.refreshNow()
                    } label: {
                        Label("Refresh devices", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isRefreshingDevices || model.hasActiveWork)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 44)

                settingsDivider

                VStack(alignment: .leading, spacing: 3) {
                    Text("Only devices supported by the selected Xcode scheme are shown. Selection is saved separately for this application.")
                    Text("Drag devices to set their installation order. The order is saved separately for this application.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)

                settingsDivider

                if compatibleDevices.isEmpty {
                    Label("No compatible iPhone or iPad is currently connected.", systemImage: "iphone.slash")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(12)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(compatibleDevices) { device in
                                deviceTargetRow(device, project: project)
                                Divider().padding(.leading, 12)
                            }
                        }
                    }
                    .scrollIndicators(.automatic)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minHeight: 130, maxHeight: .infinity)
            .background(settingsCardBackground)
        }
    }

    private func macInstallationSection(_ project: ManagedProject) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Install on this Mac")
                .font(.headline)
                .padding(.horizontal, 2)

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Label("This Mac", systemImage: "desktopcomputer")
                        .fontWeight(.medium)
                    Spacer()
                    Text("/Applications")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 44)

                settingsDivider

                VStack(alignment: .leading, spacing: 5) {
                    Text("Development Management builds the selected macOS scheme without repository workflow scripts, creates and verifies a DMG, stops the existing application if it is running, replaces it in Applications, and launches the new build.")
                    Text(L10n.format("DMG output: %@", project.macOSDMGURL.path))
                        .textSelection(.enabled)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .background(settingsCardBackground)
        }
    }

    private func deviceTargetRow(_ device: ConnectedDevice, project: ManagedProject) -> some View {
        Toggle(
            isOn: Binding(
                get: { model.isDeviceInstallationEnabled(device.udid, for: project.id) },
                set: {
                    model.setDeviceInstallationEnabled(
                        $0,
                        deviceUDID: device.udid,
                        for: project.id
                    )
                }
            )
        ) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Label(device.name, systemImage: device.symbolName)
                    Text(lastInstallationText(for: device, project: project))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(L10n.format(
                        "%@ · %@",
                        device.model ?? device.platformDescription,
                        device.connectionDescription
                    ))
                    Text(installedDeviceVersionText(for: device, project: project))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.tertiary)
                    .frame(width: 24, height: 32)
                    .contentShape(Rectangle())
                    .draggable(device.udid) {
                        Label(device.name, systemImage: device.symbolName)
                            .padding(8)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .help("Drag to change installation order")
            }
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, 12)
        .frame(minHeight: 54)
        .dropDestination(for: String.self) { deviceUDIDs, location in
            guard let draggedDeviceUDID = deviceUDIDs.first,
                  draggedDeviceUDID != device.udid
            else {
                return false
            }
            model.moveInstallationDevice(
                draggedDeviceUDID,
                relativeTo: device.udid,
                placeAfterDestination: location.y >= 27,
                for: project.id
            )
            return true
        }
    }

    private func lastInstallationText(for device: ConnectedDevice, project: ManagedProject) -> String {
        guard let record = model.lastInstallationRecord(
            for: project.id,
            deviceUDID: device.udid
        ) else {
            return L10n.text("Not installed yet by Development Management")
        }
        return L10n.format(
            "Last installed: %@ · Version %@",
            record.installedAt.formatted(date: .abbreviated, time: .shortened),
            record.installedVersion ?? L10n.text("Unknown")
        )
    }

    private func installedDeviceVersionText(
        for device: ConnectedDevice,
        project: ManagedProject
    ) -> String {
        guard project.bundleIdentifier != nil else {
            return L10n.text("Installed version is unavailable")
        }
        guard model.didCheckInstalledApplications(on: device.udid) else {
            return model.isRefreshingDevices
                ? L10n.text("Checking installed version…")
                : L10n.text("Installed version is unavailable")
        }
        guard let version = model.installedApplication(
            for: project,
            deviceUDID: device.udid
        )?.versionDisplay else {
            return L10n.text("Not installed on this device")
        }
        return L10n.format("Installed on device: %@", version)
    }

    private func settingsPickerRow<Content: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 20)
            content()
                .frame(width: 300)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
    }

    private var settingsDivider: some View {
        Divider().padding(.leading, 12)
    }

    private var settingsCardBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor))
    }

    private func signingTeamGuidance(for project: ManagedProject) -> String {
        if project.isMacOSApplication {
            return L10n.text("Automatic uses the macOS project's signing settings. Choosing a team here overrides it without changing project files.")
        }
        if model.developerTeams.isEmpty {
            return L10n.text("No Apple Development signing teams were found. Add the account and certificate in Xcode, then refresh.")
        }
        return L10n.text("Automatic uses the project's signing team when available, or a unique matching team from Xcode provisioning profiles. Choosing a team here overrides it without changing project files.")
    }

    private var selectedProject: ManagedProject? {
        guard let id = selection.first else { return nil }
        return model.projects.first { $0.id == id }
    }

    private func chooseProjectFolder() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("Choose an iOS or macOS application folder")
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
