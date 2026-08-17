import AppKit
import SwiftUI

private enum RedeemCodeDetailTab: String, CaseIterable {
    case oneTime
    case custom

    var title: String {
        switch self {
        case .oneTime: L10n.text("One-Time Codes")
        case .custom: L10n.text("Custom Codes")
        }
    }
}

struct RedeemCodeOfferDetailView: View {
    let offer: AppStoreConnectOfferSnapshot
    let details: AppStoreConnectOfferCodeDetailSnapshot?
    let isLoading: Bool
    let errorMessage: String?
    let onRetry: () -> Void

    @State private var selectedTab = RedeemCodeDetailTab.oneTime

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Code type", selection: $selectedTab) {
                ForEach(RedeemCodeDetailTab.allCases, id: \.self) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)

            if isLoading, details == nil {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text("Loading code batches and one-time values from App Store Connect…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Could not load redeem codes", systemImage: "exclamationmark.triangle.fill")
                } description: {
                    Text(verbatim: errorMessage)
                } actions: {
                    Button("Try Again", action: onRetry)
                }
            } else if let details {
                switch selectedTab {
                case .oneTime:
                    oneTimeContent(details)
                case .custom:
                    customContent(details)
                }
            }
        }
        .accessibilityLabel(L10n.format("Redeem-code details for %@", offer.name))
    }

    private func oneTimeContent(_ details: AppStoreConnectOfferCodeDetailSnapshot) -> some View {
        Form {
            Section("Availability") {
                Label(
                    "Available batches are shown first. Apple does not expose which individual one-time values were redeemed, so used values cannot be sorted separately.",
                    systemImage: "info.circle"
                )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Section("One-Time Code Batches") {
                if details.oneTimeBatches.isEmpty {
                    Text("No one-time code batches exist for this offer.")
                        .foregroundStyle(.secondary)
                }
                ForEach(details.oneTimeBatches) { batch in
                    DisclosureGroup {
                        LabeledContent("Created", value: displayDate(batch.createdDate))
                        LabeledContent("Expires", value: displayDate(batch.expirationDate))
                        if let environment = batch.environment?.nilIfEmpty {
                            LabeledContent("Environment", value: friendlyState(environment))
                        }
                        if batch.codes.isEmpty {
                            Text("Apple has not made the downloadable values available.")
                                .foregroundStyle(.secondary)
                        } else {
                            Button("Copy All Values") {
                                copy(batch.codes.joined(separator: "\n"))
                            }
                            ForEach(Array(batch.codes.enumerated()), id: \.offset) { _, code in
                                HStack {
                                    Text(verbatim: code)
                                        .font(.body.monospaced())
                                        .textSelection(.enabled)
                                    Spacer()
                                    Button {
                                        copy(code)
                                    } label: {
                                        Image(systemName: "doc.on.doc")
                                    }
                                    .buttonStyle(.borderless)
                                    .help(L10n.text("Copy Code"))
                                }
                            }
                        }
                    } label: {
                        batchLabel(
                            title: L10n.format("%d one-time code(s)", batch.numberOfCodes),
                            active: batch.active
                        )
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func customContent(_ details: AppStoreConnectOfferCodeDetailSnapshot) -> some View {
        Form {
            Section("Availability") {
                Label(
                    "Active custom-code batches are shown first. Apple reports each batch’s redemption cap, but not its remaining redemption count through this API.",
                    systemImage: "info.circle"
                )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Section("Custom Code Batches") {
                if details.customBatches.isEmpty {
                    Text("No custom code batches exist for this offer.")
                        .foregroundStyle(.secondary)
                }
                ForEach(details.customBatches) { batch in
                    VStack(alignment: .leading, spacing: 8) {
                        batchLabel(title: batch.customCode, active: batch.active)
                        LabeledContent("Redemption cap", value: String(batch.numberOfCodes))
                        LabeledContent("Created", value: displayDate(batch.createdDate))
                        LabeledContent("Expires", value: displayDate(batch.expirationDate))
                        if let url = batch.redemptionURL {
                            Text(verbatim: url.absoluteString)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                            HStack {
                                Button("Copy Redemption Link") {
                                    copy(url.absoluteString)
                                }
                                Link("Open Redemption Page", destination: url)
                            }
                        }
                        Button("Copy Code") {
                            copy(batch.customCode)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func batchLabel(title: String, active: Bool) -> some View {
        HStack {
            Text(verbatim: title)
                .font(.subheadline.weight(.semibold))
            Spacer()
            Label(
                active ? L10n.text("Available") : L10n.text("Inactive or Expired"),
                systemImage: active ? "checkmark.circle.fill" : "xmark.circle.fill"
            )
            .font(.caption)
            .foregroundStyle(active ? .green : .secondary)
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func displayDate(_ value: String?) -> String {
        value?.nilIfEmpty ?? L10n.text("No expiration")
    }

    private func friendlyState(_ rawValue: String) -> String {
        rawValue
            .split(separator: "_")
            .map { $0.lowercased().capitalized }
            .joined(separator: " ")
    }
}
