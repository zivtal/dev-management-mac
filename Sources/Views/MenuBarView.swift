import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss
    @State private var isDeviceListExpanded = false
    @State private var showsCancelInstallationConfirmation = false
    @State private var isOpeningPublishingWindow = false
    @State private var openingPublishingProjectID: UUID?
    @State private var openingPublishingAction = PublishingAction.release
    @State private var subscriptionProjectIDs: Set<UUID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if model.isGeneratingOfferCodes {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Generating subscription offer codes…")
                        .font(.subheadline.weight(.medium))
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            } else if let publishing = model.publishingProgress {
                publishingProgressSection(publishing)
            } else if let progress = model.progress {
                progressSection(progress)
            } else if isDeviceListExpanded
                        || (model.connectedDevices.isEmpty && model.hasIOSProjects) {
                deviceSection
            }

            Divider()
            projectSection
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 615)
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

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: model.hasActiveWork ? "arrow.triangle.2.circlepath" : "square.stack.3d.up.fill")
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Development Management")
                    .font(.headline)
                Group {
                    if !model.hasActiveWork, !model.connectedDevices.isEmpty {
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
                        PublishingLogWindowPresenter.shared.show(model: model)
                    }
                }
                .controlSize(.small)
                Button {
                    model.cancelPublishing()
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
        ZStack(alignment: .topTrailing) {
            Button {
                let menuWindow = NSApplication.shared.keyWindow
                dismiss()
                menuWindow?.orderOut(nil)
                Task { @MainActor in
                    await Task.yield()
                    InstallationLogWindowPresenter.shared.show(model: model)
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
                showsCancelInstallationConfirmation = true
            } label: {
                if model.isCancellingInstallation {
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
            .disabled(model.isCancellingInstallation)
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
                        model.cancelActiveInstallation()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)

                    Button("Keep Installing", role: .cancel) {
                        showsCancelInstallationConfirmation = false
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
                        Text("Devices")
                            .frame(width: 55, alignment: .center)
                        Text("Expires at")
                            .frame(width: 110, alignment: .leading)
                        Text("Last installed")
                            .frame(width: 135, alignment: .leading)
                        Color.clear.frame(width: 98, height: 1)
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)

                    Divider().gridCellColumns(5)

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
                                        } else {
                                            Image(systemName: "paperplane.fill")
                                                .frame(width: 14)
                                        }
                                    }
                                    .buttonStyle(.borderless)
                                    .foregroundStyle(.blue)
                                    .help(L10n.format("Publish %@…", project.displayName))
                                    .accessibilityLabel(L10n.format("Publish %@…", project.displayName))
                                    .disabled(model.hasActiveWork || isOpeningPublishingWindow)
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
                                    Image(systemName: "arrow.clockwise")
                                }
                                .buttonStyle(.borderless)
                                .help("Install now")
                                .disabled(
                                    !project.isEnabled
                                        || !model.hasAvailableInstallationTarget(for: project)
                                        || model.hasActiveWork
                                )
                            }
                            .frame(width: 98, alignment: .trailing)
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
            .disabled(model.projects.filter(\.isEnabled).isEmpty || model.hasActiveWork)

            Button {
                model.refreshNow()
            } label: {
                Label("Check now", systemImage: "arrow.clockwise")
            }
            .disabled(model.isRefreshingDevices || model.hasActiveWork)

            Button {
                openPublishing(projectID: nil, action: .release)
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
                model.hasActiveWork || isOpeningPublishingWindow
                    || !model.projects.contains {
                        !$0.isMacOSApplication && $0.installMethod == .xcodebuild
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
        !project.isMacOSApplication && project.installMethod == .xcodebuild
    }

    private func hasSubscriptions(_ project: ManagedProject) -> Bool {
        canPublish(project) && subscriptionProjectIDs.contains(project.id)
    }

    private var subscriptionDiscoveryKey: String {
        let projects = model.projects
            .map { "\($0.id.uuidString)|\($0.folderPath)|\($0.installMethod.rawValue)|\($0.applicationPlatform?.rawValue ?? "")" }
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

    private func openPublishing(
        projectID: UUID?,
        action: PublishingAction
    ) {
        guard !isOpeningPublishingWindow else { return }
        isOpeningPublishingWindow = true
        openingPublishingProjectID = projectID
        openingPublishingAction = action
        let menuWindow = NSApplication.shared.keyWindow
        Task { @MainActor in
            await Task.yield()
            if action == .offerCodes, let projectID {
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
