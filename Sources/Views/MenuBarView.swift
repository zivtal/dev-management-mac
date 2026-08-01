import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss
    @State private var isDeviceListExpanded = false
    @State private var showsCancelInstallationConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let progress = model.progress {
                progressSection(progress)
            } else if model.connectedDevices.isEmpty || isDeviceListExpanded {
                deviceSection
            }

            Divider()
            projectSection
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 585)
        .background {
            MenuBarOpenObserver {
                Task {
                    await model.refreshDevices(installWhenDue: true)
                }
            }
        }
        .onChange(of: model.connectedDevices.isEmpty) { _, isEmpty in
            if isEmpty {
                isDeviceListExpanded = false
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
            Image(systemName: model.progress == nil ? "square.stack.3d.up.fill" : "arrow.triangle.2.circlepath")
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("Development Management")
                    .font(.headline)
                Group {
                    if model.progress == nil, !model.connectedDevices.isEmpty {
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

    @ViewBuilder
    private func progressSection(_ progress: InstallationProgress) -> some View {
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
        .overlay(alignment: .topTrailing) {
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
            .alert(
                "Cancel installation?",
                isPresented: $showsCancelInstallationConfirmation
            ) {
                Button("Keep Installing", role: .cancel) {}
                Button("Cancel Installation", role: .destructive) {
                    model.cancelActiveInstallation()
                }
            } message: {
                Text("Are you sure you want to cancel the current installation?")
            }
        }
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
                        Text("Next build")
                            .frame(width: 110, alignment: .leading)
                        Text("Last installed")
                            .frame(width: 135, alignment: .leading)
                        Color.clear.frame(width: 48, height: 1)
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

                            Text(nextBuildText(for: project))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 110, alignment: .leading)
                                .lineLimit(1)

                            Text(lastInstalledText(for: project))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 135, alignment: .leading)
                                .lineLimit(1)

                            HStack(spacing: 6) {
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
                                        || model.selectedInstallableDevices(for: project).isEmpty
                                        || model.progress != nil
                                )
                            }
                            .frame(width: 48, alignment: .trailing)
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
            .disabled(model.projects.filter(\.isEnabled).isEmpty || model.progress != nil)

            Button {
                model.refreshNow()
            } label: {
                Label("Check now", systemImage: "arrow.clockwise")
            }
            .disabled(model.isRefreshingDevices || model.progress != nil)

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

    private var statusText: String {
        if model.progress != nil { return L10n.text("Installation in progress") }
        if !model.preferences.automationEnabled { return L10n.text("Automation is paused") }
        if model.connectedDevices.isEmpty { return L10n.text("Waiting for an iPhone") }
        return L10n.format("%d connected device(s)", model.connectedDevices.count)
    }

    private var deviceDisclosureActionText: String {
        L10n.text(isDeviceListExpanded ? "Hide connected devices" : "Show connected devices")
    }

    private func selectedDeviceCountCell(for project: ManagedProject) -> some View {
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

    private func nextBuildText(for project: ManagedProject) -> String {
        guard project.isEnabled else { return L10n.text("Paused") }
        guard let nextDate = model.nextInstallation(for: project.id) else {
            return L10n.text("Ready for first installation")
        }
        if nextDate <= Date() { return L10n.text("Installation is due") }
        return nextDate.formatted(date: .abbreviated, time: .shortened)
    }

    private func projectActivationActionText(for project: ManagedProject) -> String {
        project.isEnabled
            ? L10n.text("Pause application installations")
            : L10n.text("Resume application installations")
    }

    private func lastInstalledText(for project: ManagedProject) -> String {
        let connectedUDID = model.installableDevices.count == 1 ? model.installableDevices.first?.udid : nil
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
