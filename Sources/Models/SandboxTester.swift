import Foundation

struct SandboxTester: Equatable, Identifiable, Sendable {
    let id: String
    let accountName: String
    let firstName: String
    let lastName: String
    let territory: String?
    let subscriptionRenewalRate: String?
    let interruptPurchases: Bool

    var displayName: String {
        let name = [firstName, lastName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return name.isEmpty ? accountName : name
    }

    var subscriptionRenewalDescription: String {
        switch subscriptionRenewalRate {
        case "MONTHLY_RENEWAL_EVERY_THREE_MINUTES":
            L10n.text("Every 3 minutes")
        case "MONTHLY_RENEWAL_EVERY_FIVE_MINUTES":
            L10n.text("Every 5 minutes")
        case "MONTHLY_RENEWAL_EVERY_FIFTEEN_MINUTES":
            L10n.text("Every 15 minutes")
        case "MONTHLY_RENEWAL_EVERY_THIRTY_MINUTES":
            L10n.text("Every 30 minutes")
        case "MONTHLY_RENEWAL_EVERY_ONE_HOUR":
            L10n.text("Every hour")
        case let value?:
            value
        case nil:
            L10n.text("Unknown")
        }
    }
}
