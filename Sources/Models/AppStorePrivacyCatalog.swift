import Foundation

/// Apple's App Privacy identifiers as App Store Connect's `appDataUsages`
/// endpoints and Fastlane's upload action use them. Group names match the
/// `dataTypes` checklist already stored in publishing manifests; every title is
/// also its localization key.
enum AppStorePrivacyCatalog {
    struct Category: Equatable, Sendable, Identifiable {
        let id: String
        let title: String
    }

    struct Group: Equatable, Sendable, Identifiable {
        let name: String
        let categories: [Category]
        var id: String { name }
    }

    struct Purpose: Equatable, Sendable, Identifiable {
        let id: String
        let title: String
    }

    static let groups: [Group] = [
        Group(name: "Contact Info", categories: [
            Category(id: "NAME", title: "Name"),
            Category(id: "EMAIL_ADDRESS", title: "Email Address"),
            Category(id: "PHONE_NUMBER", title: "Phone Number"),
            Category(id: "PHYSICAL_ADDRESS", title: "Physical Address"),
            Category(id: "OTHER_CONTACT_INFO", title: "Other User Contact Info")
        ]),
        Group(name: "Health & Fitness", categories: [
            Category(id: "HEALTH", title: "Health"),
            Category(id: "FITNESS", title: "Fitness")
        ]),
        Group(name: "Financial Info", categories: [
            Category(id: "PAYMENT_INFO", title: "Payment Info"),
            Category(id: "CREDIT_INFO", title: "Credit Info"),
            Category(id: "OTHER_FINANCIAL_INFO", title: "Other Financial Info")
        ]),
        Group(name: "Location", categories: [
            Category(id: "PRECISE_LOCATION", title: "Precise Location"),
            Category(id: "COARSE_LOCATION", title: "Coarse Location")
        ]),
        Group(name: "Sensitive Info", categories: [
            Category(id: "SENSITIVE_INFO", title: "Sensitive Info")
        ]),
        Group(name: "Contacts", categories: [
            Category(id: "CONTACTS", title: "Contacts")
        ]),
        Group(name: "User Content", categories: [
            Category(id: "EMAILS_OR_TEXT_MESSAGES", title: "Emails or Text Messages"),
            Category(id: "PHOTOS_OR_VIDEOS", title: "Photos or Videos"),
            Category(id: "AUDIO_DATA", title: "Audio Data"),
            Category(id: "GAMEPLAY_CONTENT", title: "Gameplay Content"),
            Category(id: "CUSTOMER_SUPPORT", title: "Customer Support"),
            Category(id: "OTHER_USER_CONTENT", title: "Other User Content")
        ]),
        Group(name: "Browsing History", categories: [
            Category(id: "BROWSING_HISTORY", title: "Browsing History")
        ]),
        Group(name: "Search History", categories: [
            Category(id: "SEARCH_HISTORY", title: "Search History")
        ]),
        Group(name: "Identifiers", categories: [
            Category(id: "USER_ID", title: "User ID"),
            Category(id: "DEVICE_ID", title: "Device ID")
        ]),
        Group(name: "Purchases", categories: [
            Category(id: "PURCHASE_HISTORY", title: "Purchase History")
        ]),
        Group(name: "Usage Data", categories: [
            Category(id: "PRODUCT_INTERACTION", title: "Product Interaction"),
            Category(id: "ADVERTISING_DATA", title: "Advertising Data"),
            Category(id: "OTHER_USAGE_DATA", title: "Other Usage Data")
        ]),
        Group(name: "Diagnostics", categories: [
            Category(id: "CRASH_DATA", title: "Crash Data"),
            Category(id: "PERFORMANCE_DATA", title: "Performance Data"),
            Category(id: "OTHER_DIAGNOSTIC_DATA", title: "Other Diagnostic Data")
        ]),
        Group(name: "Other Data", categories: [
            Category(id: "OTHER_DATA_TYPES", title: "Other Data Types")
        ])
    ]

    static let purposes: [Purpose] = [
        Purpose(id: "THIRD_PARTY_ADVERTISING", title: "Third-Party Advertising"),
        Purpose(id: "DEVELOPERS_ADVERTISING", title: "Developer’s Advertising or Marketing"),
        Purpose(id: "ANALYTICS", title: "Analytics"),
        Purpose(id: "PRODUCT_PERSONALIZATION", title: "Product Personalization"),
        Purpose(id: "APP_FUNCTIONALITY", title: "App Functionality"),
        Purpose(id: "OTHER_PURPOSES", title: "Other Purposes")
    ]

    static let dataNotCollected = "DATA_NOT_COLLECTED"
    static let dataLinkedToYou = "DATA_LINKED_TO_YOU"
    static let dataNotLinkedToYou = "DATA_NOT_LINKED_TO_YOU"
    static let dataUsedToTrackYou = "DATA_USED_TO_TRACK_YOU"

    static var groupNames: [String] { groups.map(\.name) }
    static var categoryIDs: [String] { groups.flatMap { $0.categories.map(\.id) } }
    static var purposeIDs: [String] { purposes.map(\.id) }

    private static let groupByCategory: [String: String] = Dictionary(
        uniqueKeysWithValues: groups.flatMap { group in group.categories.map { ($0.id, group.name) } }
    )

    static func group(forCategory id: String) -> String? { groupByCategory[id] }

    static func category(_ id: String) -> Category? {
        groups.lazy.flatMap(\.categories).first { $0.id == id }
    }

    /// Group names for the categories in use, in catalog order, without duplicates.
    static func groups(for uses: [AppStorePrivacyDataUse]) -> [String] {
        let used = Set(uses.compactMap { group(forCategory: $0.category) })
        return groupNames.filter(used.contains)
    }
}
