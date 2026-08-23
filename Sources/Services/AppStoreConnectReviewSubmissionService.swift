import Foundation

private struct AppStoreReviewSubmissionSnapshot {
    let id: String
    let state: String
    let items: [AppStoreReviewSubmissionItemSnapshot]

    func contains(_ item: AppStoreConnectReviewItem) -> Bool {
        items.contains { $0.relationshipIDs[item.relationship] == item.id }
    }

    func matchingItem(_ item: AppStoreConnectReviewItem) -> AppStoreReviewSubmissionItemSnapshot? {
        items.first { $0.relationshipIDs[item.relationship] == item.id }
    }
}

private struct AppStoreReviewSubmissionItemSnapshot {
    let id: String
    let state: String
    let relationshipIDs: [String: String]
}

extension AppStoreConnectService {
    func submitForReview(
        appID: String,
        versionID: String,
        additionalItems: [AppStoreConnectReviewItem] = [],
        intent: PublishingIntent
    ) async throws {
        guard intent.submitsForReview else {
            throw AppStoreConnectError.reviewSubmissionNotAllowed
        }

        let appVersionItem = AppStoreConnectReviewItem(
            relationship: "appStoreVersion",
            resourceType: "appStoreVersions",
            id: versionID,
            label: "App Store version"
        )
        let desiredItems = Self.uniqueReviewItems([appVersionItem] + additionalItems)
        var submissions = try await activeReviewSubmissionSnapshots(appID: appID)

        if !submissions.contains(where: { $0.contains(appVersionItem) })
            && !submissions.contains(where: { $0.state == "READY_FOR_REVIEW" }) {
            do {
                let created = try await createReviewSubmission(appID: appID)
                submissions.append(created)
            } catch AppStoreConnectError.requestFailed(let status, _) where status == 409 {
                submissions = try await activeReviewSubmissionSnapshots(appID: appID)
            }
        }

        guard let selected = Self.preferredReviewSubmission(
            submissions,
            appVersionItem: appVersionItem,
            desiredItems: desiredItems
        ) else {
            throw AppStoreConnectError.requestFailed(
                409,
                L10n.text("An active review submission could not be located.")
            )
        }

        try await cancelCompetingEmptyReviewSubmissions(
            submissions,
            keeping: selected.id
        )

        if selected.state == "UNRESOLVED_ISSUES" {
            guard let missingItem = desiredItems.first(where: { !selected.contains($0) }) else {
                try await resolveRejectedReviewItems(in: selected, desiredItems: desiredItems)
                try await submitReviewSubmission(selected.id)
                return
            }
            throw AppStoreConnectError.requestFailed(
                409,
                L10n.format(
                    "The unresolved App Review submission does not include %@, and Apple does not allow adding items to it.",
                    missingItem.label
                )
            )
        }

        for item in desiredItems where !selected.contains(item) {
            try await attachReviewItem(item, to: selected.id)
        }

        let verified = try await reviewSubmissionSnapshot(
            id: selected.id,
            state: selected.state
        )
        guard verified.contains(appVersionItem) else {
            throw AppStoreConnectError.requestFailed(
                409,
                L10n.text("The App Store version was not attached to the active review submission.")
            )
        }
        try await resolveRejectedReviewItems(in: verified, desiredItems: desiredItems)
        try await submitReviewSubmission(selected.id)
    }

    private func activeReviewSubmissionSnapshots(
        appID: String
    ) async throws -> [AppStoreReviewSubmissionSnapshot] {
        let resources = try await pagedData(
            path: "/v1/apps/\(appID)/reviewSubmissions",
            query: ["filter[platform]": "IOS", "limit": "200"]
        )
        let activeStates: Set<String> = ["READY_FOR_REVIEW", "UNRESOLVED_ISSUES"]
        var snapshots: [AppStoreReviewSubmissionSnapshot] = []
        for resource in resources {
            guard let id = resource["id"] as? String,
                  let attributes = resource["attributes"] as? [String: Any],
                  let state = attributes["state"] as? String,
                  activeStates.contains(state) else { continue }
            snapshots.append(try await reviewSubmissionSnapshot(id: id, state: state))
        }
        return snapshots
    }

    private func reviewSubmissionSnapshot(
        id: String,
        state: String
    ) async throws -> AppStoreReviewSubmissionSnapshot {
        let response = try await request(
            method: "GET",
            path: "/v1/reviewSubmissions/\(id)/items",
            query: [
                "include": "appStoreVersion,subscriptionVersion,subscriptionGroupVersion",
                "limit": "200"
            ]
        )
        let resources = response["data"] as? [[String: Any]] ?? []
        let items = resources.compactMap { resource -> AppStoreReviewSubmissionItemSnapshot? in
            guard let itemID = resource["id"] as? String else { return nil }
            let attributes = resource["attributes"] as? [String: Any] ?? [:]
            let relationships = resource["relationships"] as? [String: Any] ?? [:]
            var relationshipIDs: [String: String] = [:]
            for name in ["appStoreVersion", "subscriptionVersion", "subscriptionGroupVersion"] {
                let relationship = relationships[name] as? [String: Any]
                let data = relationship?["data"] as? [String: Any]
                if let relatedID = data?["id"] as? String {
                    relationshipIDs[name] = relatedID
                }
            }
            return AppStoreReviewSubmissionItemSnapshot(
                id: itemID,
                state: attributes["state"] as? String ?? "",
                relationshipIDs: relationshipIDs
            )
        }
        return AppStoreReviewSubmissionSnapshot(id: id, state: state, items: items)
    }

    private func createReviewSubmission(
        appID: String
    ) async throws -> AppStoreReviewSubmissionSnapshot {
        let response = try await request(
            method: "POST",
            path: "/v1/reviewSubmissions",
            body: [
                "data": [
                    "type": "reviewSubmissions",
                    "attributes": ["platform": "IOS"],
                    "relationships": [
                        "app": ["data": ["type": "apps", "id": appID]]
                    ]
                ]
            ]
        )
        return AppStoreReviewSubmissionSnapshot(
            id: try Self.identifier(in: response, named: "review submission"),
            state: "READY_FOR_REVIEW",
            items: []
        )
    }

    private func cancelCompetingEmptyReviewSubmissions(
        _ submissions: [AppStoreReviewSubmissionSnapshot],
        keeping selectedID: String
    ) async throws {
        for submission in submissions
        where submission.id != selectedID
            && submission.state == "READY_FOR_REVIEW"
            && submission.items.isEmpty {
            _ = try await request(
                method: "PATCH",
                path: "/v1/reviewSubmissions/\(submission.id)",
                body: [
                    "data": [
                        "type": "reviewSubmissions",
                        "id": submission.id,
                        "attributes": ["canceled": true]
                    ]
                ]
            )
        }
    }

    private func resolveRejectedReviewItems(
        in submission: AppStoreReviewSubmissionSnapshot,
        desiredItems: [AppStoreConnectReviewItem]
    ) async throws {
        for desiredItem in desiredItems {
            guard let item = submission.matchingItem(desiredItem),
                  item.state == "REJECTED" else { continue }
            _ = try await request(
                method: "PATCH",
                path: "/v1/reviewSubmissionItems/\(item.id)",
                body: [
                    "data": [
                        "type": "reviewSubmissionItems",
                        "id": item.id,
                        "attributes": ["resolved": true]
                    ]
                ]
            )
        }
    }

    private func attachReviewItem(
        _ item: AppStoreConnectReviewItem,
        to submissionID: String
    ) async throws {
        do {
            _ = try await request(
                method: "POST",
                path: "/v1/reviewSubmissionItems",
                body: [
                    "data": [
                        "type": "reviewSubmissionItems",
                        "relationships": [
                            "reviewSubmission": [
                                "data": ["type": "reviewSubmissions", "id": submissionID]
                            ],
                            item.relationship: [
                                "data": ["type": item.resourceType, "id": item.id]
                            ]
                        ]
                    ]
                ]
            )
        } catch AppStoreConnectError.requestFailed(let status, let message) where status == 409 {
            let refreshed = try await reviewSubmissionSnapshot(
                id: submissionID,
                state: "READY_FOR_REVIEW"
            )
            guard refreshed.contains(item) else {
                throw AppStoreConnectError.requestFailed(status, message)
            }
        }
    }

    private func submitReviewSubmission(_ submissionID: String) async throws {
        _ = try await request(
            method: "PATCH",
            path: "/v1/reviewSubmissions/\(submissionID)",
            body: [
                "data": [
                    "type": "reviewSubmissions",
                    "id": submissionID,
                    "attributes": ["submitted": true]
                ]
            ]
        )
    }

    private static func preferredReviewSubmission(
        _ submissions: [AppStoreReviewSubmissionSnapshot],
        appVersionItem: AppStoreConnectReviewItem,
        desiredItems: [AppStoreConnectReviewItem]
    ) -> AppStoreReviewSubmissionSnapshot? {
        if let owner = submissions.first(where: { $0.contains(appVersionItem) }) {
            return owner
        }
        return submissions
            .filter { $0.state == "READY_FOR_REVIEW" }
            .max { left, right in
                desiredItems.filter(left.contains).count < desiredItems.filter(right.contains).count
            }
    }

    private static func uniqueReviewItems(
        _ items: [AppStoreConnectReviewItem]
    ) -> [AppStoreConnectReviewItem] {
        var keys: Set<String> = []
        return items.filter { keys.insert("\($0.relationship)|\($0.id)").inserted }
    }
}
