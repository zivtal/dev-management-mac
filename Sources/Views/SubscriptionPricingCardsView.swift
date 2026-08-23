import Foundation
import SwiftUI

enum SubscriptionPriceSaveStatus: Equatable {
    case success(String)
    case failure(String)
}

enum SubscriptionPriceValidation {
    static func normalized(_ rawValue: String) -> String? {
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard !normalized.isEmpty,
              let value = Decimal(
                string: normalized,
                locale: Locale(identifier: "en_US_POSIX")
              ),
              value > 0 else {
            return nil
        }
        return normalized
    }
}

enum SubscriptionTerritoryValidation {
    static func normalized(_ rawValue: String) -> String? {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard normalized.count == 3,
              normalized.unicodeScalars.allSatisfy(CharacterSet.letters.contains) else {
            return nil
        }
        return normalized
    }
}

enum SubscriptionPriceDraftPolicy {
    static func currentPrices(
        configured: [String: String],
        definitions: [AppStoreSubscriptionDefinition],
        liveGroups: [AppStoreConnectSubscriptionGroupSnapshot],
        referenceDate: Date = Date()
    ) -> [String: String] {
        var result = configured
        let liveSubscriptions = liveGroups.flatMap(\.subscriptions)
        for definition in definitions {
            guard let live = liveSubscriptions.first(where: {
                $0.productID == definition.productID
            }), let price = live.currentPrice(
                in: definition.baseTerritory?.nilIfEmpty ?? "USA",
                referenceDate: referenceDate
            ) else { continue }
            result[definition.productID] = price
        }
        return result
    }
}

enum SubscriptionPriceSaveError: LocalizedError {
    case invalidPrice(String)
    case invalidBaseTerritory(String)

    var errorDescription: String? {
        switch self {
        case .invalidPrice(let productID):
            L10n.format("Enter a valid price greater than zero for %@.", productID)
        case .invalidBaseTerritory(let productID):
            L10n.format("Choose a valid three-letter base territory for %@.", productID)
        }
    }
}

struct SubscriptionPricingCardsView: View {
    let groups: [AppStoreSubscriptionGroupDefinition]
    @Binding var prices: [String: String]
    @Binding var baseTerritories: [String: String]
    let territoryIDs: [String]
    let hasChanges: Bool
    let isSaving: Bool
    let saveStatus: SubscriptionPriceSaveStatus?
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                VStack(alignment: .leading, spacing: 10) {
                    Text(verbatim: group.referenceName)
                        .font(.headline)
                    ForEach(group.subscriptions, id: \.productID) { subscription in
                        productCard(subscription)
                    }
                }
            }

            Text("Current prices are loaded from App Store Connect. Changes are saved when you publish, and Apple’s nearest valid price point is used when an exact value is unavailable.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let saveStatus {
                saveStatusView(saveStatus)
            }

            HStack {
                Spacer()
                Button {
                    onSave()
                } label: {
                    if isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Save Subscription Prices", systemImage: "square.and.arrow.down")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasChanges || isSaving || hasInvalidPrice)
            }
        }
        .padding(.top, 6)
    }

    private func productCard(_ subscription: AppStoreSubscriptionDefinition) -> some View {
        let price = priceBinding(for: subscription.productID)
        let baseTerritory = baseTerritoryBinding(for: subscription.productID)
        let isInvalid = SubscriptionPriceValidation.normalized(price.wrappedValue) == nil
        let territoryIsInvalid = SubscriptionTerritoryValidation.normalized(
            baseTerritory.wrappedValue
        ) == nil
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: subscription.referenceName)
                        .font(.subheadline.weight(.semibold))
                    Text(verbatim: subscription.productID)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Text(verbatim: friendlyPeriod(subscription.period))
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Base price")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Price", text: price)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(isInvalid ? Color.red : Color.clear, lineWidth: 1.5)
                        }
                    if isInvalid {
                        Text("Enter a price greater than zero.")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Base territory")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    AppStoreTerritoryPicker(
                        title: "Base territory",
                        selection: baseTerritory,
                        territoryIDs: territoryIDs
                    )
                    .labelsHidden()
                    .frame(width: 190)
                    if territoryIsInvalid {
                        Text("Choose a base territory.")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Availability")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(subscription.availableInAllTerritories == true
                        ? "All territories"
                        : "Configured territories")
                }
                Spacer()
            }
        }
        .padding(11)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    }

    private var hasInvalidPrice: Bool {
        groups.flatMap(\.subscriptions).contains {
            SubscriptionPriceValidation.normalized(prices[$0.productID] ?? "") == nil
                || SubscriptionTerritoryValidation.normalized(
                    baseTerritories[$0.productID] ?? ""
                ) == nil
        }
    }

    private func priceBinding(for productID: String) -> Binding<String> {
        Binding(
            get: { prices[productID] ?? "" },
            set: { prices[productID] = $0 }
        )
    }

    private func baseTerritoryBinding(for productID: String) -> Binding<String> {
        Binding(
            get: { baseTerritories[productID] ?? "USA" },
            set: { baseTerritories[productID] = $0.uppercased() }
        )
    }

    private func friendlyPeriod(_ period: String) -> String {
        switch period.uppercased() {
        case "ONE_MONTH": L10n.text("Monthly")
        case "ONE_YEAR": L10n.text("Yearly")
        default: period.replacingOccurrences(of: "_", with: " ").lowercased().capitalized
        }
    }

    @ViewBuilder
    private func saveStatusView(_ status: SubscriptionPriceSaveStatus) -> some View {
        switch status {
        case .success(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
}
