import AppKit
import SwiftUI

@MainActor
final class InstallationLogWindowPresenter {
    static let shared = InstallationLogWindowPresenter()

    private var windowController: NSWindowController?

    private init() {}

    func show(model: AppModel) {
        if windowController == nil {
            let rootView = InstallationLogView()
                .environmentObject(model)
            let hostingController = NSHostingController(rootView: rootView)
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
                backing: .buffered,
                defer: false
            )
            panel.title = L10n.text("Installation Log")
            panel.contentViewController = hostingController
            panel.isFloatingPanel = false
            panel.isReleasedWhenClosed = false
            panel.minSize = NSSize(width: 560, height: 360)
            panel.center()
            windowController = NSWindowController(window: panel)
        }

        NSApplication.shared.activate(ignoringOtherApps: true)
        windowController?.showWindow(nil)
        windowController?.window?.makeKeyAndOrderFront(nil)
    }
}

private struct InstallationLogView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let log = model.installationLog {
                header(log)
                Divider()
                logOutput(log)
                footer(log)
            } else {
                ContentUnavailableView(
                    "No installation log",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Start an installation to see its live output here.")
                )
            }
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 360)
    }

    private func header(_ log: InstallationLogSession) -> some View {
        HStack(spacing: 10) {
            statusImage(log.state)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(log.statusTitle)
                    .font(.headline)
                Text(L10n.format("Installing %@ on %@", log.projectName, log.deviceName))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if log.state == .inProgress {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private func logOutput(_ log: InstallationLogSession) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(log.output.isEmpty ? L10n.text("Waiting for command output…") : log.output)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(log.output.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)

                Color.clear
                    .frame(height: 1)
                    .id("installation-log-bottom")
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .onAppear { scrollToBottom(proxy) }
            .onChange(of: log.revision) { _, _ in scrollToBottom(proxy) }
        }
    }

    private func footer(_ log: InstallationLogSession) -> some View {
        HStack {
            Text(log.startedAt, style: .time)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Copy Log") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(log.output, forType: .string)
            }
            .disabled(log.output.isEmpty)
        }
    }

    @ViewBuilder
    private func statusImage(_ state: InstallationLogSession.State) -> some View {
        switch state {
        case .inProgress:
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.blue)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            proxy.scrollTo("installation-log-bottom", anchor: .bottom)
        }
    }
}
