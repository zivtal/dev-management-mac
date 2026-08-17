import AppKit
import SwiftUI

@MainActor
final class PublishingLogWindowPresenter {
    static let shared = PublishingLogWindowPresenter()

    private var windowController: NSWindowController?

    private init() {}

    func show(model: AppModel) {
        if windowController == nil {
            let rootView = PublishingLogWindowView()
                .environmentObject(model)
            let hostingController = NSHostingController(rootView: rootView)
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .utilityWindow],
                backing: .buffered,
                defer: false
            )
            panel.title = L10n.text("Publishing Log")
            panel.contentViewController = hostingController
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.minSize = NSSize(width: 720, height: 520)
            panel.center()
            windowController = NSWindowController(window: panel)
        }

        NSApplication.shared.activate(ignoringOtherApps: true)
        windowController?.showWindow(nil)
        windowController?.window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        windowController?.close()
    }
}

private struct PublishingLogWindowView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let log = model.publishingLog {
            PublishingProgressView(
                log: log,
                progress: model.publishingProgress,
                onCancel: model.cancelPublishing,
                onBackToReview: {
                    let projectID = log.projectID
                    model.presentedError = nil
                    PublishingLogWindowPresenter.shared.close()
                    PublishingWindowPresenter.shared.show(model: model, projectID: projectID)
                },
                onDone: PublishingLogWindowPresenter.shared.close
            )
        } else {
            ContentUnavailableView(
                "No publishing log",
                systemImage: "doc.text.magnifyingglass",
                description: Text("Start an App Store publication or TestFlight upload to see its live output here.")
            )
            .frame(minWidth: 720, minHeight: 520)
        }
    }
}

struct PublishingProgressView: View {
    let log: PublishingLogSession
    let progress: PublishingProgress?
    let onCancel: () -> Void
    let onBackToReview: () -> Void
    let onDone: () -> Void

    @State private var showsTechnicalDetails = true

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            statusHeader
            journey
            currentWork
            technicalDetails
            Spacer(minLength: 0)
            footer
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusHeader: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.13))
                if log.state == .inProgress {
                    ProgressView().controlSize(.regular)
                } else {
                    Image(systemName: statusSymbol)
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(statusColor)
                }
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 4) {
                Text(statusTitle)
                    .font(.title2.bold())
                Text(statusDetail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .trailing, spacing: 3) {
                    Text(log.projectName)
                        .fontWeight(.semibold)
                    Text(elapsedText(at: context.date))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var journey: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("Release progress")
                    .font(.headline)
                Spacer()
                Text(L10n.format(
                    "Step %d of %d",
                    currentStage.rawValue + 1,
                    PublishingJourneyStage.allCases.count
                ))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            ProgressView(value: completionFraction)
                .progressViewStyle(.linear)

            HStack(alignment: .top, spacing: 8) {
                ForEach(PublishingJourneyStage.allCases) { stage in
                    stageView(stage)
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func stageView(_ stage: PublishingJourneyStage) -> some View {
        let state = visualState(for: stage)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: state.symbol)
                    .foregroundStyle(state.color)
                Text(stage.title)
                    .font(.subheadline.weight(state.isCurrent ? .semibold : .regular))
                    .lineLimit(1)
            }
            Text(stage.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(10)
        .background(state.color.opacity(state.isCurrent ? 0.11 : 0.04), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(state.color.opacity(state.isCurrent ? 0.35 : 0.10), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private var currentWork: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(currentWorkTitle)
                        .font(.headline)
                    Text(currentWorkDetail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if log.state == .inProgress {
                    Text(L10n.format("%d%%", Int(completionFraction * 100)))
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.blue)
                }
            }

            if log.state == .inProgress, let output = progress?.latestOutput.nilIfEmpty {
                Label(output, systemImage: "terminal")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }

            if let result = log.result {
                HStack(spacing: 16) {
                    resultValue("Version", result.version)
                    resultValue("Build", result.buildNumber)
                    resultValue(
                        "Destination",
                        result.submittedForReview
                            ? L10n.text("TestFlight and App Review")
                            : L10n.text("App Store Connect and TestFlight")
                    )
                    if result.reusedExistingBuild {
                        resultValue("Build source", L10n.text("Existing TestFlight build"))
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(statusColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
    }

    private var technicalDetails: some View {
        DisclosureGroup("Technical details", isExpanded: $showsTechnicalDetails) {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(log.output.isEmpty ? L10n.text("Waiting for the first update…") : log.output)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(12)

                    Color.clear
                        .frame(height: 1)
                        .id("publishing-log-bottom")
                }
                .onAppear { scrollToBottom(proxy) }
                .onChange(of: log.output) { _, _ in scrollToBottom(proxy) }
            }
            .frame(minHeight: 110, maxHeight: 230)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            .padding(.top, 8)
        }
    }

    private var footer: some View {
        HStack {
            if log.state == .inProgress {
                Label(
                    "You can close this window. Publishing continues in the menu bar.",
                    systemImage: "menubar.rectangle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Copy Log") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(log.output, forType: .string)
            }
            .disabled(log.output.isEmpty)
            switch log.state {
            case .inProgress:
                Button("Cancel Publication", role: .destructive, action: onCancel)
            case .succeeded:
                Button("Done", action: onDone)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            case .failed, .cancelled:
                Button("Close", action: onDone)
                Button("Review and Try Again", action: onBackToReview)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func resultValue(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L10n.text(title))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .fontWeight(.medium)
                .textSelection(.enabled)
        }
    }

    private var currentStage: PublishingJourneyStage {
        if log.state == .succeeded {
            return log.result?.intent == .testFlight ? .testFlight : .review
        }
        return log.phase.journeyStage
    }

    private var completionFraction: Double {
        switch log.state {
        case .succeeded: 1
        case .inProgress: progress?.phase.completionFraction ?? log.phase.completionFraction
        case .failed, .cancelled: log.phase.completionFraction
        }
    }

    private var statusTitle: String {
        switch log.state {
        case .inProgress: L10n.text("Publishing is underway")
        case .succeeded: L10n.text("Your release is on its way")
        case .failed: L10n.text("Publishing needs attention")
        case .cancelled: L10n.text("Publishing was canceled")
        }
    }

    private var statusDetail: String {
        switch log.state {
        case .inProgress:
            L10n.text("Development Management is completing the release steps automatically.")
        case .succeeded:
            log.result?.submittedForReview == true
                ? L10n.text("The build is available in TestFlight and the release was submitted to Apple.")
                : L10n.text("The complete App Store and TestFlight setup is synchronized, the build is available to internal testers, and nothing was submitted for App Review.")
        case .failed:
            log.failureMessage?.nilIfEmpty
                ?? L10n.text("Review the issue below, adjust the settings, and try again.")
        case .cancelled:
            L10n.text("No further release steps will run. Completed uploads may remain in App Store Connect.")
        }
    }

    private var currentWorkTitle: String {
        switch log.state {
        case .inProgress: progress?.phase.title ?? log.phase.title
        case .succeeded:
            L10n.text(log.result?.intent == .testFlight
                ? "TestFlight upload completed successfully"
                : "Publication completed successfully")
        case .failed: L10n.text("Stopped at this step")
        case .cancelled: L10n.text("Publication canceled")
        }
    }

    private var currentWorkDetail: String {
        switch log.state {
        case .inProgress: progress?.phase.friendlyDetail ?? log.phase.friendlyDetail
        case .succeeded: L10n.text("The automated workflow completed every requested step.")
        case .failed: log.phase.friendlyDetail
        case .cancelled: L10n.text("Return to the release overview whenever you are ready to continue.")
        }
    }

    private var statusSymbol: String {
        switch log.state {
        case .inProgress: "arrow.triangle.2.circlepath"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .cancelled: "stop.circle.fill"
        }
    }

    private var statusColor: Color {
        switch log.state {
        case .inProgress: .blue
        case .succeeded: .green
        case .failed: .red
        case .cancelled: .orange
        }
    }

    private func elapsedText(at now: Date) -> String {
        let end = log.finishedAt ?? now
        return L10n.format(
            "Runtime %@",
            RuntimeDurationFormatter.string(from: end.timeIntervalSince(log.startedAt))
        )
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            proxy.scrollTo("publishing-log-bottom", anchor: .bottom)
        }
    }

    private func visualState(for stage: PublishingJourneyStage) -> StageVisualState {
        if log.state == .succeeded,
           log.result?.intent == .testFlight,
           stage == .configure || stage == .review {
            return StageVisualState(symbol: "minus.circle.fill", color: .secondary, isCurrent: false)
        }
        if log.state == .succeeded || stage.rawValue < currentStage.rawValue {
            return StageVisualState(symbol: "checkmark.circle.fill", color: .green, isCurrent: false)
        }
        if stage == currentStage {
            switch log.state {
            case .inProgress:
                return StageVisualState(symbol: "circle.dotted", color: .blue, isCurrent: true)
            case .failed:
                return StageVisualState(symbol: "xmark.circle.fill", color: .red, isCurrent: true)
            case .cancelled:
                return StageVisualState(symbol: "stop.circle.fill", color: .orange, isCurrent: true)
            case .succeeded:
                return StageVisualState(symbol: "checkmark.circle.fill", color: .green, isCurrent: false)
            }
        }
        return StageVisualState(symbol: "circle", color: .secondary, isCurrent: false)
    }

    private struct StageVisualState {
        let symbol: String
        let color: Color
        let isCurrent: Bool
    }
}
