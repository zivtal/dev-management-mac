import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss
    @State private var isDeviceListExpanded = false
    @State private var showsCancelInstallationConfirmation = false
    @State private var cancellationProjectID: UUID?
    @State private var isOpeningPublishingWindow = false
    @State private var openingPublishingProjectID: UUID?
    @State private var openingPublishingAction = PublishingAction.release
    @State private var subscriptionProjectIDs: Set<UUID> = []
    @State private var measuredHeaderHeight: CGFloat = 40
    @State private var measuredScrollableContentHeight: CGFloat = 100
    @State private var measuredFooterHeight: CGFloat = 28

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
                .reportMenuBarHeight(.header)

            ScrollView {
                scrollableContent
                    .reportMenuBarHeight(.scrollableContent)
            }
            .frame(height: popoverSizing.scrollableHeight)
            .layoutPriority(1)

            Divider()
            footer
                .reportMenuBarHeight(.footer)
        }
        .padding(.vertical, 14)
        .padding(.leading, 14)
        .padding(.trailing, 16)
        .frame(width: showsGitBranchColumn ? 735 : 635)
        .frame(height: popoverSizing.popoverHeight, alignment: .top)
        .background {
            MenuBarOpenObserver {
                Task {
                    async let devices: Void = model.refreshDevices(installWhenDue: true)
                    async let subscriptions: Void = refreshSubscriptionProjects()
                    _ = await (devices, subscriptions)
                }
            }
        }
        .task(id: subscriptionDiscoveryKey) {
            await refreshSubscriptionProjects()
        }
        .onChange(of: model.connectedDevices.isEmpty) { _, isEmpty in
            if isEmpty {
                isDeviceListExpanded = false
            }
        }
        .onChange(of: model.progress) { _, progress in
            if progress == nil {
                showsCancelInstallationConfirmation = false
            }
        }
        .onPreferenceChange(MenuBarHeightPreferenceKey.self) { heights in
            if let height = heights[.header] {
                measuredHeaderHeight = height
            }
            if let height = heights[.scrollableContent] {
                measuredScrollableContentHeight = height
            }
            if let height = heights[.footer] {
                measuredFooterHeight = height
            }
        }
        .overlay {
            if showsCancelInstallationConfirmation {
                cancelInstallationConfirmation
            }
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

    private var popoverSizing: MenuBarLayoutPolicy.Sizing {
        MenuBarLayoutPolicy.sizing(
            contentHeight: measuredScrollableContentHeight,
            headerHeight: measuredHeaderHeight,
            footerHeight: measuredFooterHeight
        )
    }

    private var scrollableContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.isGeneratingOfferCodes {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Generating subscription offer codes…")
                        .font(.subheadline.weight(.medium))
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            } else if !model.activePublishingProgresses.isEmpty
                        || !model.activeInstallationProgresses.isEmpty {
                LazyVStack(spacing: 8) {
                    ForEach(model.activePublishingProgresses, id: \.projectID) {
                        publishingProgressSection($0)
                    }
                    ForEach(model.activeInstallationProgresses, id: \.projectID) {
                        progressSection($0)
                    }
                }
            } else if isDeviceListExpanded
                        || (model.connectedDevices.isEmpty && model.hasIOSProjects) {
                deviceSection
            }

            Divider()
            projectSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: model.hasActiveWork ? "arrow.triangle.2.circlepath" : "square.stack.3d.up.fill")
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Development Management")
                    .font(.headline)
                Group {
                    if !model.connectedDevices.isEmpty {
                        Button {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                isDeviceListExpanded.toggle()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(statusText)
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                    .rotationEffect(.degrees(isDeviceListExpanded ? 90 : 0))
                                    .frame(width: 14, height: 14)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(deviceDisclosureActionText)
                        .accessibilityLabel(deviceDisclosureActionText)
                    } else {
                        Text(statusText)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("Automation", isOn: $model.preferences.automationEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .help("Enable automatic installation")
        }
    }

    private func publishingProgressSection(_ progress: PublishingProgress) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                ProgressView().controlSize(.small)
                Text(progress.phase.title)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button("View") {
                    let menuWindow = NSApplication.shared.keyWindow
                    dismiss()
                    menuWindow?.orderOut(nil)
                    Task { @MainActor in
                        await Task.yield()
                        PublishingLogWindowPresenter.shared.show(
                            model: model,
                            projectID: progress.projectID
                        )
                    }
                }
                .controlSize(.small)
                Button {
                    model.cancelPublishing(projectID: progress.projectID)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Cancel publication")
            }
            Text(L10n.format("Publishing %@ to the App Store", progress.projectName))
                .font(.caption)
                .foregroundStyle(.secondary)
            ProgressView(value: progress.phase.completionFraction)
                .progressViewStyle(.linear)
            HStack {
                Text(progress.phase.friendlyDetail)
                    .lineLimit(2)
                Spacer()
                Text(L10n.format(
                    "Step %d of %d",
                    progress.phase.journeyStage.rawValue + 1,
                    PublishingJourneyStage.allCases.count
                ))
                .monospacedDigit()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            if !progress.latestOutput.isEmpty {
                Text(progress.latestOutput)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func progressSection(_ progress: InstallationProgress) -> some View {
        let cancellationInProgress = progress.projectID.map {
            model.isCancellingInstallation(projectID: $0)
        } ?? false
        ZStack(alignment: .topTrailing) {
            Button {
                let menuWindow = NSApplication.shared.keyWindow
                dismiss()
                menuWindow?.orderOut(nil)
                Task { @MainActor in
                    await Task.yield()
                    if let projectID = progress.projectID {
                        InstallationLogWindowPresenter.shared.show(
                            model: model,
                            projectID: projectID
                        )
                    }
                }
            } label: {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text(progress.phaseTitle)
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Color.clear.frame(width: 22, height: 22)
                    }
                    Text(L10n.format("Installing %@ on %@", progress.projectName, progress.deviceName))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !progress.latestOutput.isEmpty {
                        Text(progress.latestOutput)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }
                }
                .contentShape(Rectangle())
                .padding(10)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .help("Show installation log")
            .accessibilityLabel("Show installation log")

            Button {
                cancellationProjectID = progress.projectID
                showsCancelInstallationConfirmation = true
            } label: {
                if cancellationInProgress {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.borderless)
            .help("Cancel installation")
            .accessibilityLabel("Cancel installation")
            .disabled(cancellationInProgress)
            .padding(9)
        }
    }

    private var cancelInstallationConfirmation: some View {
        ZStack {
            Color.black.opacity(0.38)
                .contentShape(Rectangle())

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Cancel installation?")
                        .font(.headline)
                    Text("Are you sure you want to cancel the current installation?")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Button("Cancel Installation", role: .destructive) {
                        showsCancelInstallationConfirmation = false
                        if let cancellationProjectID {
                            model.cancelInstallation(projectID: cancellationProjectID)
                        }
                        cancellationProjectID = nil
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)

                    Button("Keep Installing", role: .cancel) {
                        showsCancelInstallationConfirmation = false
                        cancellationProjectID = nil
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 360)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(.separator.opacity(0.7), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
        }
        .accessibilityElement(children: .contain)
    }

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.connectedDevices.isEmpty {
                Label("No connected iPhone", systemImage: "iphone.slash")
                    .foregroundStyle(.secondary)
                Text("Connect by USB or enable Connect via network in Xcode.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(model.connectedDevices) { device in
                    HStack {
                        Label(device.name, systemImage: device.symbolName)
                        Spacer()
                        Text(device.connectionDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help(device.model ?? device.connectionDescription)
                    }
                }
            }
        }
    }

    private var projectSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            if model.projects.isEmpty {
                Text("No applications have been added yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
                    GridRow {
                        Text("Application")
                            .frame(width: 160, alignment: .leading)
                        if showsGitBranchColumn {
                            Text("Branch")
                                .frame(width: 90, alignment: .leading)
                        }
                        Text("Devices")
                            .frame(width: 55, alignment: .center)
                        Text("Expires at")
                            .frame(width: 110, alignment: .leading)
                        Text("Last installed")
                            .frame(width: 135, alignment: .leading)
                        Color.clear.frame(width: 118, height: 1)
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)

                    Divider().gridCellColumns(showsGitBranchColumn ? 6 : 5)

                    ForEach(model.projects) { project in
                        GridRow {
                            HStack(spacing: 6) {
                                ProjectIconView(project: project, size: 28, showsStatus: true)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(project.displayName)
                                        .lineLimit(1)
                                    Text(project.versionDisplay)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .frame(width: 160, alignment: .leading)

                            if showsGitBranchColumn {
                                Text(model.activeGitBranch(for: project.id) ?? "—")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 90, alignment: .leading)
                                    .lineLimit(1)
                                    .help(model.activeGitBranch(for: project.id) ?? L10n.text("Not a Git worktree"))
                            }

                            selectedDeviceCountCell(for: project)

                            Text(expirationText(for: project))
                                .font(.caption)
                                .foregroundStyle(expirationColor(for: project))
                                .frame(width: 110, alignment: .leading)
                                .lineLimit(1)

                            Text(lastInstalledText(for: project))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 135, alignment: .leading)
                                .lineLimit(1)

                            HStack(spacing: 6) {
                                if hasSubscriptions(project) {
                                    Button {
                                        openPublishing(
                                            projectID: project.id,
                                            action: .offerCodes
                                        )
                                    } label: {
                                        if isOpeningPublishingWindow,
                                           openingPublishingProjectID == project.id,
                                           openingPublishingAction == .offerCodes {
                                            ProgressView()
                                                .controlSize(.small)
                                                .frame(width: 14)
                                        } else {
                                            Image(systemName: "ticket.fill")
                                                .frame(width: 14)
                                        }
                                    }
                                    .buttonStyle(.borderless)
                                    .foregroundStyle(.orange)
                                    .help(L10n.format("Create a redeem code for %@…", project.displayName))
                                    .accessibilityLabel(L10n.format("Create a redeem code for %@…", project.displayName))
                                    .disabled(model.hasActiveWork || isOpeningPublishingWindow)
                                } else if canPublish(project) {
                                    Color.clear.frame(width: 14, height: 14)
                                }

                                if canPublish(project) {
                                    Button {
                                        openPublishing(projectID: project.id, action: .release)
                                    } label: {
                                        if isOpeningPublishingWindow,
                                           openingPublishingProjectID == project.id,
                                           openingPublishingAction == .release {
                                            ProgressView()
                                                .controlSize(.small)
                                                .frame(width: 14)
                                        } else if model.isPublishing(projectID: project.id) {
                                            Image(systemName: "arrow.triangle.2.circlepath")
                                                .frame(width: 14)
                                        } else {
                                            Image(systemName: "paperplane.fill")
                                                .frame(width: 14)
                                        }
                                    }
                                    .buttonStyle(.borderless)
                                    .foregroundStyle(.blue)
                                    .help(model.isPublishing(projectID: project.id)
                                        ? L10n.format("Show publishing progress for %@", project.displayName)
                                        : L10n.format("Publish %@…", project.displayName))
                                    .accessibilityLabel(model.isPublishing(projectID: project.id)
                                        ? L10n.format("Show publishing progress for %@", project.displayName)
                                        : L10n.format("Publish %@…", project.displayName))
                                    .disabled(
                                        model.isInstalling(projectID: project.id)
                                            || isOpeningPublishingWindow
                                    )
                                } else {
                                    Color.clear.frame(width: 14, height: 14)
                                }

                                if !project.isMacOSApplication {
                                    Button {
                                        openSimulatorRun(projectID: project.id)
                                    } label: {
                                        Image(systemName: "iphone.and.arrow.forward")
                                            .frame(width: 14)
                                    }
                                    .buttonStyle(.borderless)
                                    .foregroundStyle(
                                        model.isSimulatorSessionActive(projectID: project.id)
                                            ? Color.green
                                            : Color.purple
                                    )
                                    .help(L10n.format("Run %@ in the Simulator…", project.displayName))
                                    .accessibilityLabel(L10n.format("Run %@ in the Simulator…", project.displayName))
                                } else {
                                    Color.clear.frame(width: 14, height: 14)
                                }

                                Button {
                                    model.setProjectEnabled(!project.isEnabled, projectID: project.id)
                                } label: {
                                    Image(systemName: project.isEnabled ? "pause.fill" : "play.fill")
                                        .frame(width: 14)
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(project.isEnabled ? Color.primary : Color.green)
                                .help(projectActivationActionText(for: project))
                                .accessibilityLabel(projectActivationActionText(for: project))

                                Button {
                                    model.installNow(projectID: project.id)
                                } label: {
                                    Image(systemName: model.isInstallationQueued(for: project.id)
                                        ? "clock.arrow.circlepath"
                                        : "arrow.clockwise")
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(
                                    model.isInstallationQueued(for: project.id)
                                        ? Color.orange
                                        : Color.primary
                                )
                                .help(model.isInstallationQueued(for: project.id)
                                    ? L10n.text("Waiting for device connection")
                                    : L10n.text("Install now"))
                                .disabled(
                                    !project.isEnabled
                                        || !model.hasAvailableInstallationTarget(for: project)
                                        || model.isInstallationQueued(for: project.id)
                                        || model.isInstalling(projectID: project.id)
                                        || model.isPublishing(projectID: project.id)
                                )
                            }
                            .frame(width: 118, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button {
                model.installAll()
            } label: {
                Label("Install All Now", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(model.projects.filter(\.isEnabled).isEmpty || model.isGeneratingOfferCodes)

            Button {
                model.refreshNow()
            } label: {
                Label("Check now", systemImage: "arrow.clockwise")
            }
            .disabled(model.isRefreshingDevices)

            Menu {
                ForEach(model.projects.filter(canPublish)) { project in
                    Button {
                        openPublishing(projectID: project.id, action: .release)
                    } label: {
                        if model.isPublishing(projectID: project.id) {
                            Label(
                                L10n.format("%@ — Publishing…", project.displayName),
                                systemImage: "arrow.triangle.2.circlepath"
                            )
                        } else {
                            Text(project.displayName)
                        }
                    }
                    .disabled(model.isInstalling(projectID: project.id))
                }
            } label: {
                if isOpeningPublishingWindow {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.small)
                        Text("Opening Publish…")
                    }
                } else {
                    Label("Publish…", systemImage: "paperplane.fill")
                }
            }
            .disabled(
                isOpeningPublishingWindow
                    || !model.projects.contains {
                        !$0.isMacOSApplication
                    }
            )

            Spacer(minLength: 8)

            Button {
                let menuWindow = NSApplication.shared.keyWindow
                dismiss()
                menuWindow?.orderOut(nil)
                Task { @MainActor in
                    await Task.yield()
                    openSettings()
                    for _ in 0..<10 {
                        try? await Task.sleep(for: .milliseconds(50))
                        if let settingsWindow = NSApplication.shared.windows.first(where: {
                            $0.styleMask.contains(.titled)
                                && $0.styleMask.contains(.closable)
                                && $0.canBecomeKey
                        }) {
                            settingsWindow.makeKeyAndOrderFront(nil)
                            settingsWindow.orderFrontRegardless()
                            NSRunningApplication.current.activate(options: [
                                .activateAllWindows
                            ])
                            NSApplication.shared.activate(ignoringOtherApps: true)
                            break
                        }
                    }
                }
            } label: {
                Label("Settings…", systemImage: "gear")
            }

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .controlSize(.small)
    }

    private func canPublish(_ project: ManagedProject) -> Bool {
        !project.isMacOSApplication
    }

    private var showsGitBranchColumn: Bool {
        !model.gitBranchesByProjectID.isEmpty
    }

    private func hasSubscriptions(_ project: ManagedProject) -> Bool {
        canPublish(project) && subscriptionProjectIDs.contains(project.id)
    }

    private var subscriptionDiscoveryKey: String {
        let projects = model.projects
            .map { "\($0.id.uuidString)|\($0.folderPath)|\($0.applicationPlatform?.rawValue ?? "")" }
            .joined(separator: ";")
        return "\(model.preferences.appStoreLocale ?? "")|\(projects)"
    }

    @MainActor
    private func refreshSubscriptionProjects() async {
        let projects = model.projects.filter(canPublish)
        let locale = model.preferences.appStoreLocale?.nilIfEmpty ?? "en-US"
        let discoveredIDs = await Task.detached(priority: .utility) {
            let discovery = StoreKitSubscriptionDiscoveryService()
            return Set(projects.compactMap { project -> UUID? in
                guard let catalog = try? discovery.discover(
                    project: project,
                    defaultLocale: locale
                ), catalog.groups.contains(where: { !$0.subscriptions.isEmpty }) else {
                    return nil
                }
                return project.id
            })
        }.value
        guard !Task.isCancelled else { return }
        subscriptionProjectIDs = discoveredIDs
    }

    private func openSimulatorRun(projectID: UUID) {
        let menuWindow = NSApplication.shared.keyWindow
        Task { @MainActor in
            await Task.yield()
            SimulatorRunWindowPresenter.shared.show(model: model, projectID: projectID)
            dismiss()
            menuWindow?.orderOut(nil)
        }
    }

    private func openPublishing(
        projectID: UUID,
        action: PublishingAction
    ) {
        guard !isOpeningPublishingWindow else { return }
        isOpeningPublishingWindow = true
        openingPublishingProjectID = projectID
        openingPublishingAction = action
        let menuWindow = NSApplication.shared.keyWindow
        Task { @MainActor in
            await Task.yield()
            if action == .offerCodes {
                RedeemCodesWindowPresenter.shared.show(
                    model: model,
                    projectID: projectID
                )
            } else {
                PublishingWindowPresenter.shared.show(
                    model: model,
                    projectID: projectID,
                    action: action
                )
            }
            dismiss()
            menuWindow?.orderOut(nil)
            isOpeningPublishingWindow = false
            openingPublishingProjectID = nil
            openingPublishingAction = .release
        }
    }

    private var statusText: String {
        if model.isGeneratingOfferCodes { return L10n.text("Generating subscription offer codes…") }
        let activeTaskCount = model.activePublishingProgresses.count
            + model.activeInstallationProgresses.count
        if activeTaskCount > 1 {
            return L10n.format("%d tasks in progress", activeTaskCount)
        }
        if let publishing = model.publishingProgress { return publishing.phase.title }
        if model.progress != nil { return L10n.text("Installation in progress") }
        if !model.preferences.automationEnabled { return L10n.text("Automation is paused") }
        if model.connectedDevices.isEmpty, model.hasMacOSProjects, model.hasIOSProjects {
            return L10n.text("This Mac is ready; waiting for an iPhone")
        }
        if model.connectedDevices.isEmpty, model.hasMacOSProjects {
            return L10n.text("This Mac is ready")
        }
        if model.connectedDevices.isEmpty { return L10n.text("Waiting for an iPhone") }
        return L10n.format("%d connected device(s)", model.connectedDevices.count)
    }

    private var deviceDisclosureActionText: String {
        L10n.text(isDeviceListExpanded ? "Hide connected devices" : "Show connected devices")
    }

    private func selectedDeviceCountCell(for project: ManagedProject) -> some View {
        if project.isMacOSApplication {
            return Text("Mac")
                .font(.caption)
                .frame(width: 55, alignment: .center)
                .help(L10n.text("Installs on this Mac"))
                .accessibilityLabel(L10n.text("Installs on this Mac"))
        }
        let count = model.selectedDeviceCount(for: project)
        let description = count == 1
            ? L10n.text("One device selected")
            : L10n.format("%d devices selected", count)
        return Text(verbatim: "\(count)")
            .font(.caption.monospacedDigit())
            .frame(width: 55, alignment: .center)
            .help(description)
            .accessibilityLabel(description)
    }

    private func expirationText(for project: ManagedProject) -> String {
        guard let expirationDate = model.expirationDate(for: project.id) else {
            return L10n.text("Unknown")
        }
        return expirationDate.formatted(date: .abbreviated, time: .shortened)
    }

    private func expirationColor(for project: ManagedProject) -> Color {
        guard let expirationDate = model.expirationDate(for: project.id) else {
            return .secondary
        }
        if expirationDate <= Date() { return .red }
        if SchedulingPolicy.profileRenewalDate(for: expirationDate).map({ $0 <= Date() }) == true {
            return .orange
        }
        return .secondary
    }

    private func projectActivationActionText(for project: ManagedProject) -> String {
        project.isEnabled
            ? L10n.text("Pause application installations")
            : L10n.text("Resume application installations")
    }

    private func lastInstalledText(for project: ManagedProject) -> String {
        let connectedUDID = project.isMacOSApplication
            ? ManagedProject.localMacInstallationTargetID
            : (model.installableDevices.count == 1 ? model.installableDevices.first?.udid : nil)
        guard let date = model.lastInstallation(for: project.id, deviceUDID: connectedUDID) else {
            return L10n.text("Never")
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

enum MenuBarLayoutPolicy {
    struct Sizing: Equatable {
        let popoverHeight: CGFloat
        let scrollableHeight: CGFloat
    }

    static let minimumPopoverHeight: CGFloat = 600
    static let maximumPopoverHeight: CGFloat = 600

    // Header, footer, one divider, three 12-point VStack gaps, and 14-point
    // vertical padding on each edge remain outside the scrolling viewport.
    private static let fixedVerticalChromeHeight: CGFloat = 65

    static func sizing(
        contentHeight: CGFloat,
        headerHeight: CGFloat,
        footerHeight: CGFloat
    ) -> Sizing {
        let minimumHeight = minimumPopoverHeight
        let maximumHeight = maximumPopoverHeight
        let resolvedHeaderHeight = max(0, headerHeight.isFinite ? headerHeight : 0)
        let resolvedFooterHeight = max(0, footerHeight.isFinite ? footerHeight : 0)
        let chromeHeight = resolvedHeaderHeight
            + resolvedFooterHeight
            + fixedVerticalChromeHeight
        let minimumScrollableHeight = max(0, minimumHeight - chromeHeight)
        let maximumScrollableHeight = max(
            minimumScrollableHeight,
            maximumHeight - chromeHeight
        )
        let resolvedContentHeight = max(0, contentHeight.isFinite ? contentHeight : 0)
        let scrollableHeight = min(
            maximumScrollableHeight,
            max(minimumScrollableHeight, resolvedContentHeight)
        )
        let popoverHeight = min(
            maximumHeight,
            max(minimumHeight, chromeHeight + scrollableHeight)
        )
        return Sizing(
            popoverHeight: popoverHeight,
            scrollableHeight: scrollableHeight
        )
    }
}

private enum MenuBarMeasuredRegion: Hashable {
    case header
    case scrollableContent
    case footer
}

private struct MenuBarHeightPreferenceKey: PreferenceKey {
    static let defaultValue: [MenuBarMeasuredRegion: CGFloat] = [:]

    static func reduce(
        value: inout [MenuBarMeasuredRegion: CGFloat],
        nextValue: () -> [MenuBarMeasuredRegion: CGFloat]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, newValue in newValue })
    }
}

private extension View {
    func reportMenuBarHeight(_ region: MenuBarMeasuredRegion) -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: MenuBarHeightPreferenceKey.self,
                    value: [region: geometry.size.height]
                )
            }
        }
    }
}

private struct MenuBarOpenObserver: NSViewRepresentable {
    let onOpen: () -> Void

    func makeNSView(context: Context) -> MenuBarOpenObserverView {
        let view = MenuBarOpenObserverView()
        view.onOpen = onOpen
        return view
    }

    func updateNSView(_ nsView: MenuBarOpenObserverView, context: Context) {
        nsView.onOpen = onOpen
    }
}

private final class MenuBarOpenObserverView: NSView {
    var onOpen: (() -> Void)?

    private var didReportCurrentVisibility = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        didReportCurrentVisibility = false

        guard let window else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowOcclusionDidChange),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: window
        )

        if window.isVisible {
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, self.window === window, window?.isVisible == true else { return }
                self.reportOpening()
            }
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func windowOcclusionDidChange() {
        if window?.isVisible == true {
            reportOpening()
        } else {
            didReportCurrentVisibility = false
        }
    }

    private func reportOpening() {
        guard !didReportCurrentVisibility else { return }
        didReportCurrentVisibility = true
        onOpen?()
    }
}
