import Foundation

/// One App Store Connect `appDataUsages` record: the triple Apple stores for an
/// App Privacy answer. The no-data declaration has no category or purpose.
struct AppStorePrivacyUsageRecord: Equatable, Hashable, Sendable {
    let category: String?
    let purpose: String?
    let dataProtection: String
}

/// Turns a reviewed draft into the records both publishers send. Mirrors Fastlane's
/// `upload_app_privacy_details_to_app_store`: one record per purpose and protection,
/// so what works through Fastlane works through the Apple web session too.
enum AppStorePrivacyUsagePlan {
    /// True when nothing is assumed: no data, or every selected category names at
    /// least one purpose and every identifier is one Apple accepts.
    static func isComplete(_ draft: AppStorePrivacyDraft) -> Bool {
        (try? records(for: draft)) != nil
    }

    static func records(for draft: AppStorePrivacyDraft) throws -> [AppStorePrivacyUsageRecord] {
        guard draft.collectsData else {
            return [AppStorePrivacyUsageRecord(
                category: nil, purpose: nil, dataProtection: AppStorePrivacyCatalog.dataNotCollected
            )]
        }
        guard let uses = draft.dataUses, !uses.isEmpty else {
            throw AppStorePrivacyPublishingError.collectedDataNeedsDetails
        }
        let knownCategories = Set(AppStorePrivacyCatalog.categoryIDs)
        let knownPurposes = Set(AppStorePrivacyCatalog.purposeIDs)
        var records: [AppStorePrivacyUsageRecord] = []
        for use in uses {
            guard knownCategories.contains(use.category), !use.purposes.isEmpty,
                  use.purposes.allSatisfy(knownPurposes.contains) else {
                throw AppStorePrivacyPublishingError.collectedDataNeedsDetails
            }
            let linkage = use.linkedToUser
                ? AppStorePrivacyCatalog.dataLinkedToYou
                : AppStorePrivacyCatalog.dataNotLinkedToYou
            for purpose in use.purposes {
                records.append(AppStorePrivacyUsageRecord(
                    category: use.category, purpose: purpose, dataProtection: linkage
                ))
                if use.usedForTracking {
                    records.append(AppStorePrivacyUsageRecord(
                        category: use.category, purpose: purpose,
                        dataProtection: AppStorePrivacyCatalog.dataUsedToTrackYou
                    ))
                }
            }
        }
        return records
    }

    /// Plain dictionaries for `callAsyncJavaScript`; absent keys stand for null.
    static func scriptArguments(_ records: [AppStorePrivacyUsageRecord]) -> [[String: String]] {
        records.map { record in
            var values = ["dataProtection": record.dataProtection]
            if let category = record.category { values["category"] = category }
            if let purpose = record.purpose { values["purpose"] = purpose }
            return values
        }
    }

    static func fastlaneUsages(for draft: AppStorePrivacyDraft) throws -> [FastlaneAppPrivacyUsage] {
        guard draft.collectsData else {
            return [FastlaneAppPrivacyUsage(dataProtections: [AppStorePrivacyCatalog.dataNotCollected])]
        }
        _ = try records(for: draft)
        return (draft.dataUses ?? []).map { use in
            var protections = [use.linkedToUser
                ? AppStorePrivacyCatalog.dataLinkedToYou
                : AppStorePrivacyCatalog.dataNotLinkedToYou]
            if use.usedForTracking { protections.append(AppStorePrivacyCatalog.dataUsedToTrackYou) }
            return FastlaneAppPrivacyUsage(
                category: use.category, purposes: use.purposes, dataProtections: protections
            )
        }
    }
}
