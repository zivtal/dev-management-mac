import XCTest
@testable import DevManagement

/// Collected-data App Privacy answers publish through the same Apple endpoints as
/// the no-data declaration, one record per category, purpose, and protection. The
/// plan is the single source for both the web session and the Fastlane payload.
final class AppStorePrivacyUsagePlanTests: XCTestCase {
    private func draft(_ uses: [AppStorePrivacyDataUse]?, collects: Bool = true) -> AppStorePrivacyDraft {
        AppStorePrivacyDraft(
            collectsData: collects,
            dataTypes: uses.map { AppStorePrivacyCatalog.groups(for: $0) } ?? [],
            notes: [],
            dataUses: uses
        )
    }

    func testCatalogGroupsEveryCategoryUnderTheExistingDataTypeNames() {
        let groupNames = AppStorePrivacyCatalog.groups.map(\.name)
        XCTAssertEqual(groupNames, [
            "Contact Info", "Health & Fitness", "Financial Info", "Location",
            "Sensitive Info", "Contacts", "User Content", "Browsing History",
            "Search History", "Identifiers", "Purchases", "Usage Data",
            "Diagnostics", "Other Data"
        ])
        XCTAssertEqual(AppStorePrivacyCatalog.group(forCategory: "USER_ID"), "Identifiers")
        XCTAssertEqual(AppStorePrivacyCatalog.group(forCategory: "CRASH_DATA"), "Diagnostics")
        XCTAssertNil(AppStorePrivacyCatalog.group(forCategory: "NOPE"))
        XCTAssertEqual(AppStorePrivacyCatalog.purposes.map(\.id), [
            "THIRD_PARTY_ADVERTISING", "DEVELOPERS_ADVERTISING", "ANALYTICS",
            "PRODUCT_PERSONALIZATION", "APP_FUNCTIONALITY", "OTHER_PURPOSES"
        ])
        let ids = AppStorePrivacyCatalog.groups.flatMap { $0.categories.map(\.id) }
        XCTAssertEqual(Set(ids).count, ids.count, "category ids must be unique")
    }

    func testNoDataDraftPlansTheSingleNotCollectedRecord() throws {
        let records = try AppStorePrivacyUsagePlan.records(for: draft(nil, collects: false))
        XCTAssertEqual(records, [AppStorePrivacyUsageRecord(category: nil, purpose: nil, dataProtection: "DATA_NOT_COLLECTED")])
        XCTAssertTrue(AppStorePrivacyUsagePlan.isComplete(draft(nil, collects: false)))
    }

    func testCollectedDataPlansOneRecordPerPurposeAndProtection() throws {
        let uses = [
            AppStorePrivacyDataUse(category: "USER_ID", purposes: ["APP_FUNCTIONALITY", "ANALYTICS"],
                                   linkedToUser: true, usedForTracking: true),
            AppStorePrivacyDataUse(category: "CRASH_DATA", purposes: ["APP_FUNCTIONALITY"],
                                   linkedToUser: false, usedForTracking: false)
        ]
        let records = try AppStorePrivacyUsagePlan.records(for: draft(uses))
        XCTAssertEqual(records, [
            .init(category: "USER_ID", purpose: "APP_FUNCTIONALITY", dataProtection: "DATA_LINKED_TO_YOU"),
            .init(category: "USER_ID", purpose: "APP_FUNCTIONALITY", dataProtection: "DATA_USED_TO_TRACK_YOU"),
            .init(category: "USER_ID", purpose: "ANALYTICS", dataProtection: "DATA_LINKED_TO_YOU"),
            .init(category: "USER_ID", purpose: "ANALYTICS", dataProtection: "DATA_USED_TO_TRACK_YOU"),
            .init(category: "CRASH_DATA", purpose: "APP_FUNCTIONALITY", dataProtection: "DATA_NOT_LINKED_TO_YOU")
        ])
        XCTAssertTrue(AppStorePrivacyUsagePlan.isComplete(draft(uses)))
    }

    func testIncompleteCollectedDataIsNeverPublished() {
        let noUses = draft([])
        let noPurposes = draft([AppStorePrivacyDataUse(category: "USER_ID", purposes: [], linkedToUser: true, usedForTracking: false)])
        let legacy = AppStorePrivacyDraft(collectsData: true, dataTypes: ["Identifiers"], notes: [])
        for candidate in [noUses, noPurposes, legacy] {
            XCTAssertFalse(AppStorePrivacyUsagePlan.isComplete(candidate))
            XCTAssertThrowsError(try AppStorePrivacyUsagePlan.records(for: candidate)) { error in
                guard case AppStorePrivacyPublishingError.collectedDataNeedsDetails = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }
    }

    func testUnknownAppleIdentifiersAreRejected() {
        let badCategory = draft([AppStorePrivacyDataUse(category: "Identifiers", purposes: ["APP_FUNCTIONALITY"], linkedToUser: false, usedForTracking: false)])
        let badPurpose = draft([AppStorePrivacyDataUse(category: "USER_ID", purposes: ["FUN"], linkedToUser: false, usedForTracking: false)])
        XCTAssertFalse(AppStorePrivacyUsagePlan.isComplete(badCategory))
        XCTAssertFalse(AppStorePrivacyUsagePlan.isComplete(badPurpose))
        XCTAssertThrowsError(try AppStorePrivacyUsagePlan.records(for: badCategory))
        XCTAssertThrowsError(try AppStorePrivacyUsagePlan.records(for: badPurpose))
    }

    func testFastlanePayloadMirrorsTheUploadActionShape() throws {
        let uses = [
            AppStorePrivacyDataUse(category: "EMAIL_ADDRESS", purposes: ["APP_FUNCTIONALITY"],
                                   linkedToUser: true, usedForTracking: true),
            AppStorePrivacyDataUse(category: "PRODUCT_INTERACTION", purposes: ["ANALYTICS"],
                                   linkedToUser: false, usedForTracking: false)
        ]
        let payload = try AppStorePrivacyPublishingService.payload(for: draft(uses))
        XCTAssertEqual(payload, [
            FastlaneAppPrivacyUsage(category: "EMAIL_ADDRESS", purposes: ["APP_FUNCTIONALITY"],
                                    dataProtections: ["DATA_LINKED_TO_YOU", "DATA_USED_TO_TRACK_YOU"]),
            FastlaneAppPrivacyUsage(category: "PRODUCT_INTERACTION", purposes: ["ANALYTICS"],
                                    dataProtections: ["DATA_NOT_LINKED_TO_YOU"])
        ])
        XCTAssertEqual(
            try AppStorePrivacyPublishingService.payload(for: draft(nil, collects: false)),
            [FastlaneAppPrivacyUsage(dataProtections: ["DATA_NOT_COLLECTED"])]
        )
    }

    func testRecordsSerializeForThePageScript() throws {
        let records = try AppStorePrivacyUsagePlan.records(for: draft([
            AppStorePrivacyDataUse(category: "USER_ID", purposes: ["ANALYTICS"], linkedToUser: false, usedForTracking: false)
        ]))
        let arguments = AppStorePrivacyUsagePlan.scriptArguments(records)
        XCTAssertEqual(arguments as? [[String: String]], [
            ["category": "USER_ID", "purpose": "ANALYTICS", "dataProtection": "DATA_NOT_LINKED_TO_YOU"]
        ])
        let noData = AppStorePrivacyUsagePlan.scriptArguments(
            try AppStorePrivacyUsagePlan.records(for: draft(nil, collects: false))
        )
        XCTAssertEqual(noData as? [[String: String]], [["dataProtection": "DATA_NOT_COLLECTED"]])
    }

    func testLegacyManifestsWithoutDataUsesStillDecode() throws {
        let json = #"{"collectsData":true,"dataTypes":["Identifiers"],"notes":["n"]}"#
        let decoded = try JSONDecoder().decode(AppStorePrivacyDraft.self, from: Data(json.utf8))
        XCTAssertNil(decoded.dataUses)
        XCTAssertEqual(decoded.dataTypes, ["Identifiers"])
        let encoded = try JSONEncoder().encode(decoded)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("dataUses"))
    }

    func testCompleteCollectedDraftFollowsTheAutomaticPath() {
        let complete = draft([
            AppStorePrivacyDataUse(category: "USER_ID", purposes: ["APP_FUNCTIONALITY"], linkedToUser: true, usedForTracking: false)
        ])
        let incomplete = draft([
            AppStorePrivacyDataUse(category: "USER_ID", purposes: [], linkedToUser: true, usedForTracking: false)
        ])
        let authorized = AppStorePrivacyAttestation(
            confirmedBy: "Publisher", confirmedAt: "2026-10-14T12:00:00Z",
            projectFingerprint: nil, automaticPublishingAuthorizedAt: "2026-10-14T12:00:00Z"
        )
        let manual = AppStorePrivacyAttestation(confirmedBy: "Publisher", confirmedAt: "2026-10-14T12:00:00Z", projectFingerprint: nil)
        func state(_ draft: AppStorePrivacyDraft, _ attestation: AppStorePrivacyAttestation?) -> AppStorePrivacyConfigurationState {
            AppStorePrivacyConfigurationPolicy.state(for: AppStoreComplianceConfiguration(
                privacyDraft: draft, privacyAttestation: attestation, evidence: nil, confidence: nil
            ))
        }
        XCTAssertEqual(state(complete, nil), .needsAutomaticAuthorization)
        XCTAssertEqual(state(complete, authorized), .automaticallyAuthorized)
        XCTAssertEqual(state(complete, manual), .confirmed, "a manual confirmation still counts")
        XCTAssertEqual(state(incomplete, nil), .needsManualConfirmation)
        XCTAssertEqual(state(incomplete, authorized), .needsManualConfirmation)
        XCTAssertEqual(state(incomplete, manual), .confirmed)
        var published = authorized
        published.publishedAt = "2026-10-14T12:30:00Z"
        XCTAssertEqual(state(complete, published), .confirmed)
    }
}
