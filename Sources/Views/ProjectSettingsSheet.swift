import AppKit
import SwiftUI

struct ProjectSettingsSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var isRefreshingSchemes = false
    @State private var schemeRefreshError: String?
    let projectID: UUID

    private var project: ManagedProject? {
        model.projects.first { $0.id == projectID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let project {
                HStack {
                    ProjectIconView(project: project, iconURL: model.projectIconURL(for: projectID), size: 36)
                    VStack(alignment: .leading) {
                        Text(project.displayName).font(.title2.bold())
                        Text("Application settings").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
                projectActions(project)
                Divider()
                HStack(alignment: .top, spacing: 20) {
                    projectConfigurationCard(project)
                        .frame(width: 390)
                    Group {
                        if project.isMacOSApplication {
                            macInstallationSection(project)
                        } else {
                            deviceTargetsSection(project)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
        }
        .padding(20)
        .frame(width: 900, height: sheetHeight)
        .onChange(of: project == nil) { _, removed in
            if removed { dismiss() }
        }
        .task { await refreshSchemes() }
        .alert("Something went wrong", isPresented: Binding(
            get: { schemeRefreshError != nil || model.presentedError != nil },
            set: { if !$0 { schemeRefreshError = nil; model.presentedError = nil } }
        )) {
            Button("OK") { schemeRefreshError = nil; model.presentedError = nil }
        } message: {
            Text(schemeRefreshError ?? model.presentedError ?? "")
        }
    }

    private var sheetHeight: CGFloat {
        min(720, max(500, (NSScreen.main?.visibleFrame.height ?? 900) - 160))
    }

    private func projectActions(_ project: ManagedProject) -> some View {
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
                        || model.isInstalling(projectID: project.id)
                        || model.isPublishing(projectID: project.id)
                )

                if project.effectiveApplicationPlatform == .iOS {
                    Button {
                        PublishingWindowPresenter.shared.show(model: model, projectID: project.id)
                    } label: {
                        if model.isPublishing(projectID: project.id) {
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
                    .disabled(
                        model.isInstalling(projectID: project.id)
                            || model.isGeneratingOfferCodes
                    )
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
    }

    private func projectConfigurationCard(_ project: ManagedProject) -> some View {
        VStack(spacing: 0) {
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
                HStack {
                Picker(
                    "Scheme",
                    selection: Binding(
                        get: { project.scheme },
                        set: { model.setProjectScheme($0, for: project.id) }
                    )
                ) {
                    if !project.availableSchemes.contains(project.scheme) {
                        Text(project.scheme).tag(project.scheme)
                    }
                    ForEach(project.availableSchemes, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                Button {
                    Task { await refreshSchemes() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh schemes")
                .disabled(isRefreshingSchemes)
                }
            }

            if !project.availableSchemes.contains(project.scheme) {
                Text("This scheme is no longer available. Choose a current Xcode scheme above.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(12)
            } else if project.applicationPlatform == nil && project.bundleIdentifier == nil
                        && !isRefreshingSchemes && !model.isRefreshingCompatibility(for: project.id) {
                Text("Xcode has not detected an installable application for this scheme. Choose an app scheme, such as the project's iOS, macOS, or watchOS scheme.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(12)
            }

            settingsDivider

            if project.effectiveApplicationPlatform == .iOS {
                settingsPickerRow("Watch scheme") {
                    Picker("Watch scheme", selection: Binding(
                        get: { project.companionWatch?.scheme ?? "" },
                        set: { model.setCompanionWatchScheme($0.isEmpty ? nil : $0, for: project.id) }
                    )) {
                        Text("None").tag("")
                        if let selected = project.companionWatch?.scheme,
                           !project.availableSchemes.contains(selected) {
                            Text(selected).tag(selected)
                        }
                        ForEach(project.availableSchemes.filter { $0 != project.scheme }, id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                    .labelsHidden()
                }
                if project.companionWatch != nil && project.companionWatch?.isVerified != true
                    && !model.isRefreshingCompatibility(for: project.id) {
                    Text("Choose an installable watchOS application scheme for Watch installation.")
                        .font(.caption).foregroundStyle(.orange).padding(12)
                }
                settingsDivider
            }

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

            settingsPickerRow("Build branch") {
                VStack(alignment: .trailing, spacing: 4) {
                    Picker(
                        "Build branch",
                        selection: Binding(
                            get: { project.normalizedBuildBranch ?? "" },
                            set: { model.setProjectBuildBranch($0.isEmpty ? nil : $0, for: project.id) }
                        )
                    ) {
                        Text(workingCopyTitle(model.activeGitBranch(for: project.id))).tag("")
                        let options = project.buildBranchOptions(
                            available: model.availableGitBranches(for: project.id)
                        )
                        if !options.isEmpty {
                            Divider()
                        }
                        ForEach(options, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .disabled(
                        model.activeGitBranch(for: project.id) == nil
                            && model.availableGitBranches(for: project.id).isEmpty
                    )
                    Text(
                        project.buildsFromWorkingCopy
                            ? "Installs build the working copy exactly as checked out."
                            : "Installs build this branch's committed tip from a separate checkout; the repository's checked-out branch is never changed."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 6)
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
                        .disabled(model.isRefreshingDeveloperTeams)
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
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                    Text("Supported devices")
                        .fontWeight(.medium)
                    Spacer()
                    if model.isRefreshingCompatibility(for: project.id) {
                        ProgressView().controlSize(.small)
                    }
                    Button {
                        model.refreshNow()
                    } label: {
                        Label("Refresh devices", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isRefreshingDevices)
                    }
                    Text(project.deviceCompatibilityDescription)
                        .foregroundStyle(.secondary)
                    if project.companionWatch?.isVerified == true {
                        Text("Apple Watch").foregroundStyle(.secondary)
                    }
                }
                .padding(12)

                settingsDivider

                VStack(alignment: .leading, spacing: 3) {
                    Text("Select the devices allowed to receive this application. Newly discovered devices are never selected automatically. Selection is saved separately for each application.")
                    if project.selectedDeviceUDIDs == nil {
                        Text("Older settings saved only excluded devices. Select your intended devices once to resume installations for this application.")
                            .foregroundStyle(.orange)
                    }
                    Text("Drag devices to set their installation order. The order is saved separately for this application.")
                    if project.isWatchOSApplication || project.companionWatch != nil {
                        Text("Pair your Apple Watch with Xcode and enable Developer Mode on both the Watch and its iPhone. Install the iPhone companion first if the Watch app requires it.")
                    } else {
                        Text("Choose a Watch scheme to install on iPhone and Apple Watch together.")
                    }
                    if project.companionWatch != nil {
                        Text("Install now builds both selected schemes, installing on iPhone before Apple Watch. Configuration and signing team apply to both.")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)

                settingsDivider

                if project.companionWatch?.isVerified == true && !compatibleDevices.contains(where: \.isAppleWatch) {
                    Label("No connected Apple Watch is available in Xcode.", systemImage: "applewatch")
                        .font(.caption).foregroundStyle(.secondary).padding(12)
                }

                if compatibleDevices.isEmpty {
                    Label(
                        project.isWatchOSApplication
                            ? L10n.text("No connected Apple Watch is available in Xcode.")
                            : L10n.text("No compatible iPhone or iPad is currently connected."),
                        systemImage: project.isWatchOSApplication ? "applewatch" : "iphone.slash"
                    )
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
                .frame(width: 90, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
    }

    private func workingCopyTitle(_ branch: String?) -> String {
        if let branch {
            return L10n.format("Working copy (%@)", branch)
        }
        return L10n.text("Working copy")
    }

    private func refreshSchemes() async {
        guard !isRefreshingSchemes else { return }
        isRefreshingSchemes = true
        defer { isRefreshingSchemes = false }
        do {
            try await model.refreshProjectSchemes(projectID: projectID)
        } catch {
            schemeRefreshError = error.localizedDescription
        }
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

}
