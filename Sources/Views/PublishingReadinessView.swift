import SwiftUI

struct PublishingReadinessView: View {
    let report: PublishingReadinessReport
    let target: String
    let onEditApp: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: summarySymbol)
                    .font(.system(size: 27))
                    .foregroundStyle(summaryColor)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(summaryTitle)
                        .font(.headline)
                    Text(summaryDetail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(verbatim: target)
                    .font(.caption.monospaced().weight(.medium))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.quaternary, in: Capsule())
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 245), spacing: 10)],
                alignment: .leading,
                spacing: 10
            ) {
                ForEach(report.items) { item in
                    readinessItem(item)
                }
            }

            if !report.allowsPublication {
                HStack {
                    Text("Resolve every highlighted item before either release action. Both actions synchronize the complete App Store and TestFlight setup.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("App Settings…", action: onEditApp)
                    Button("Account Settings…", action: onOpenSettings)
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(summaryColor.opacity(0.28), lineWidth: 1)
        }
    }

    private func readinessItem(_ item: PublishingReadinessItem) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Group {
                if item.state == .checking {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: symbol(for: item.state))
                        .foregroundStyle(color(for: item.state))
                }
            }
            .frame(width: 17, height: 17)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.title)
                    .font(.subheadline.weight(.medium))
                Text(verbatim: item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(10)
        .background(color(for: item.state).opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    private var summaryTitle: String {
        if !report.blockers.isEmpty {
            return L10n.format("%d item(s) need attention", report.blockers.count)
        }
        if report.isChecking {
            return L10n.text("Checking release readiness…")
        }
        return L10n.text("Ready for the App Store")
    }

    private var summaryDetail: String {
        if !report.blockers.isEmpty {
            return L10n.text("App Store publication will wait until every required item is ready.")
        }
        if report.isChecking {
            return L10n.text("Reading the project and its current App Store Connect status.")
        }
        return L10n.text("Development Management can complete the automated release from here.")
    }

    private var summarySymbol: String {
        if !report.blockers.isEmpty { return "exclamationmark.triangle.fill" }
        if report.isChecking { return "ellipsis.circle.fill" }
        return "checkmark.seal.fill"
    }

    private var summaryColor: Color {
        if !report.blockers.isEmpty { return .red }
        if report.isChecking { return .blue }
        return .green
    }

    private func symbol(for state: PublishingReadinessItem.State) -> String {
        switch state {
        case .ready: "checkmark.circle.fill"
        case .checking: "ellipsis.circle.fill"
        case .attention: "info.circle.fill"
        case .blocked: "exclamationmark.circle.fill"
        }
    }

    private func color(for state: PublishingReadinessItem.State) -> Color {
        switch state {
        case .ready: .green
        case .checking: .blue
        case .attention: .orange
        case .blocked: .red
        }
    }
}
