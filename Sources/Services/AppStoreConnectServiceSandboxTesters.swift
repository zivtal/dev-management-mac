import Foundation

extension AppStoreConnectService {
    func fetchSandboxTesters() async throws -> [SandboxTester] {
        try await pagedData(
            path: "/v2/sandboxTesters",
            query: ["limit": "200"]
        )
        .compactMap(Self.sandboxTester)
        .sorted {
            $0.accountName.localizedCaseInsensitiveCompare($1.accountName)
                == .orderedAscending
        }
    }

    func clearSandboxPurchaseHistory(testerIDs: [String]) async throws {
        let uniqueTesterIDs = Array(Set(testerIDs)).sorted()
        guard !uniqueTesterIDs.isEmpty else { return }

        _ = try await request(
            method: "POST",
            path: "/v2/sandboxTestersClearPurchaseHistoryRequest",
            body: Self.sandboxPurchaseHistoryRequestBody(
                testerIDs: uniqueTesterIDs
            )
        )
    }

    static func sandboxPurchaseHistoryRequestBody(
        testerIDs: [String]
    ) -> [String: Any] {
        [
            "data": [
                "type": "sandboxTestersClearPurchaseHistoryRequest",
                "relationships": [
                    "sandboxTesters": [
                        "data": testerIDs.map {
                            ["type": "sandboxTesters", "id": $0]
                        }
                    ]
                ]
            ]
        ]
    }

    static func sandboxTester(_ resource: [String: Any]) -> SandboxTester? {
        guard resource["type"] as? String == "sandboxTesters",
              let id = resource["id"] as? String,
              let attributes = resource["attributes"] as? [String: Any],
              let accountName = attributes["acAccountName"] as? String else {
            return nil
        }
        return SandboxTester(
            id: id,
            accountName: accountName,
            firstName: attributes["firstName"] as? String ?? "",
            lastName: attributes["lastName"] as? String ?? "",
            territory: attributes["territory"] as? String,
            subscriptionRenewalRate: attributes["subscriptionRenewalRate"] as? String,
            interruptPurchases: attributes["interruptPurchases"] as? Bool ?? false
        )
    }
}
