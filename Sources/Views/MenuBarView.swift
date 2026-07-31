import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let progress = model.progress {
                progressSection(progress)
            } else {
                deviceSection
            }

            Divider()
            projectSection
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 480)
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
                Text("Dev Reinstaller")
                    .font(.headline)
                Text(statusText)
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
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text(progress.phaseTitle)
                    .font(.subheadline.weight(.medium))
                Spacer()
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
        .padding(10)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
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
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
                    GridRow {
                        Text("Application")
                            .frame(width: 145, alignment: .leading)
                        Text("Version")
                            .frame(width: 80, alignment: .leading)
                        Text("Last installed")
                            .frame(width: 135, alignment: .leading)
                        Color.clear.frame(width: 18, height: 1)
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)

                    Divider().gridCellColumns(4)

                    ForEach(model.projects) { project in
                        GridRow {
                            HStack(spacing: 6) {
                                ProjectIconView(project: project, size: 28, showsStatus: true)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(project.displayName)
                                        .lineLimit(1)
                                    Text(scheduleText(for: project))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .frame(width: 145, alignment: .leading)

                            Text(project.versionDisplay)
                                .font(.caption.monospacedDigit())
                                .frame(width: 80, alignment: .leading)
                                .lineLimit(1)

                            Text(lastInstalledText(for: project))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 135, alignment: .leading)
                                .lineLimit(1)

                            Button {
                                model.installNow(projectID: project.id)
                            } label: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .buttonStyle(.borderless)
                            .help("Install now")
                            .disabled(model.selectedInstallableDevices(for: project).isEmpty || model.progress != nil)
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
                openSettings()
                Task { @MainActor in
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

    private func scheduleText(for project: ManagedProject) -> String {
        guard project.isEnabled else { return L10n.text("Paused") }
        guard let nextDate = model.nextInstallation(for: project.id) else {
            return L10n.text("Ready for first installation")
        }
        if nextDate <= Date() { return L10n.text("Installation is due") }
        return L10n.format("Next: %@", nextDate.formatted(date: .abbreviated, time: .shortened))
    }

    private func lastInstalledText(for project: ManagedProject) -> String {
        let connectedUDID = model.installableDevices.count == 1 ? model.installableDevices.first?.udid : nil
        guard let date = model.lastInstallation(for: project.id, deviceUDID: connectedUDID) else {
            return L10n.text("Never")
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
