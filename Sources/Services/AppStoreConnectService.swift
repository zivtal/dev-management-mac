import CryptoKit
import Foundation

struct AppStoreScreenshotAsset: Equatable, Sendable {
    let url: URL
    let displayType: String
}

struct AppStoreConnectPublication: Sendable {
    let appID: String
    let versionID: String
    let localizationID: String
    let isVersionOnlyUpdate: Bool
}

enum AppStoreConnectError: LocalizedError {
    case invalidPrivateKey
    case invalidResponse
    case requestFailed(Int, String)
    case applicationNotFound(String)
    case missingIdentifier(String)
    case buildProcessingTimedOut
    case incompleteSubscriptionConfiguration(String)
    case missingSubscriptionPrice(String)
    case missingSubscriptionReviewScreenshot(String)
    case subscriptionNotFound(String)
    case offerCodeReferenceNameConflict(String)

    var errorDescription: String? {
        switch self {
        case .invalidPrivateKey:
            return L10n.text("The App Store Connect private key is invalid. Import the .p8 key again.")
        case .invalidResponse:
            return L10n.text("App Store Connect returned an invalid response.")
        case .requestFailed(let status, let message):
            return L10n.format("App Store Connect request failed (HTTP %d): %@", status, message)
        case .applicationNotFound(let bundleIdentifier):
            return L10n.format("No App Store Connect application has bundle identifier %@.", bundleIdentifier)
        case .missingIdentifier(let name):
            return L10n.format("App Store Connect did not return the %@ identifier.", name)
        case .buildProcessingTimedOut:
            return L10n.text("The build upload succeeded, but App Store processing did not finish before the timeout.")
        case .incompleteSubscriptionConfiguration(let productID):
            return L10n.format("The app references subscription %@, but it is missing from a local .storekit file or app-store-publishing.json.", productID)
        case .missingSubscriptionPrice(let productID):
            return L10n.format("Subscription %@ needs a base price in its .storekit file or app-store-publishing.json.", productID)
        case .missingSubscriptionReviewScreenshot(let productID):
            return L10n.format("Subscription %@ needs a paywall review screenshot. Add a subscription screenshot to the project or set reviewScreenshot in app-store-publishing.json.", productID)
        case .subscriptionNotFound(let productID):
            return L10n.format("Subscription %@ does not exist in App Store Connect. Publish the app and subscription before generating production offer codes.", productID)
        case .offerCodeReferenceNameConflict(let referenceName):
            return L10n.format("Offer %@ already exists with different terms. Offer terms cannot be edited; choose a new reference name.", referenceName)
        }
    }
}

final class AppStoreConnectService {
    private let session: URLSession
    private let issuerID: String
    private let keyID: String
    private let privateKey: P256.Signing.PrivateKey
    private let baseURL = URL(string: "https://api.appstoreconnect.apple.com")!

    init(
        issuerID: String,
        keyID: String,
        privateKeyPEM: String,
        session: URLSession = .shared
    ) throws {
        self.issuerID = issuerID
        self.keyID = keyID
        self.session = session
        do {
            privateKey = try P256.Signing.PrivateKey(pemRepresentation: privateKeyPEM)
        } catch {
            throw AppStoreConnectError.invalidPrivateKey
        }
    }

    func preparePublication(
        bundleIdentifier: String,
        version: String,
        locale: String,
        metadata: AppStoreMetadata,
        copyright: String,
        supportURL: String,
        review: AppStoreReviewConfiguration,
        releaseAutomatically: Bool
    ) async throws -> AppStoreConnectPublication {
        let appID = try await findApplication(bundleIdentifier: bundleIdentifier)
        let isVersionOnlyUpdate = try await hasPublishedVersion(appID: appID, otherThan: version)
        let versionID = try await findOrCreateVersion(
            appID: appID,
            version: version,
            copyright: copyright,
            releaseAutomatically: releaseAutomatically
        )
        let localizationID = try await findOrCreateLocalization(
            versionID: versionID,
            locale: locale
        )
        do {
            try await updateLocalization(
                localizationID,
                metadata: metadata,
                supportURL: supportURL,
                includesReleaseNotes: true
            )
        } catch AppStoreConnectError.requestFailed(let status, _) where status == 409 || status == 422 {
            // App Store Connect rejects release notes for an application's first version.
            try await updateLocalization(
                localizationID,
                metadata: metadata,
                supportURL: supportURL,
                includesReleaseNotes: false
            )
        }
        try await configureReviewDetails(versionID: versionID, review: review)
        return AppStoreConnectPublication(
            appID: appID,
            versionID: versionID,
            localizationID: localizationID,
            isVersionOnlyUpdate: isVersionOnlyUpdate
        )
    }

    func configureFirstPublication(
        appID: String,
        configuration: AppStoreApplicationConfiguration?,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws {
        guard let configuration, !configuration.isEmpty else {
            onOutput(L10n.text("No app-store-publishing.json application overrides were found; existing app-level settings are preserved.\n"))
            return
        }

        if let contentRights = configuration.contentRightsDeclaration?.nilIfEmpty {
            _ = try await request(
                method: "PATCH",
                path: "/v1/apps/\(appID)",
                body: [
                    "data": [
                        "type": "apps",
                        "id": appID,
                        "attributes": ["contentRightsDeclaration": contentRights]
                    ]
                ]
            )
            onOutput(L10n.text("Updated the app content-rights declaration.\n"))
        }

        if configuration.primaryCategory?.nilIfEmpty != nil
            || configuration.secondaryCategory?.nilIfEmpty != nil
            || configuration.ageRating?.isEmpty == false {
            let infos = try await pagedData(
                path: "/v1/apps/\(appID)/appInfos",
                query: ["limit": "200"]
            )
            let info = infos.first(where: {
                let attributes = $0["attributes"] as? [String: Any]
                let state = attributes?["appStoreState"] as? String
                return state != "READY_FOR_SALE" && state != "REPLACED_WITH_NEW_INFO"
            }) ?? infos.first
            guard let info, let infoID = info["id"] as? String else {
                throw AppStoreConnectError.missingIdentifier("app information")
            }
            var relationships: [String: Any] = [:]
            if let category = configuration.primaryCategory?.nilIfEmpty {
                relationships["primaryCategory"] = [
                    "data": ["type": "appCategories", "id": category.uppercased()]
                ]
            }
            if let category = configuration.secondaryCategory?.nilIfEmpty {
                relationships["secondaryCategory"] = [
                    "data": ["type": "appCategories", "id": category.uppercased()]
                ]
            }
            if !relationships.isEmpty {
                _ = try await request(
                    method: "PATCH",
                    path: "/v1/appInfos/\(infoID)",
                    body: [
                        "data": [
                            "type": "appInfos",
                            "id": infoID,
                            "relationships": relationships
                        ]
                    ]
                )
                onOutput(L10n.text("Updated the App Store categories.\n"))
            }
            if let ageRating = configuration.ageRating, !ageRating.isEmpty {
                let response = try await request(
                    method: "GET",
                    path: "/v1/appInfos/\(infoID)/ageRatingDeclaration"
                )
                let ageRatingID = try Self.identifier(in: response, named: "age rating declaration")
                _ = try await request(
                    method: "PATCH",
                    path: "/v1/ageRatingDeclarations/\(ageRatingID)",
                    body: [
                        "data": [
                            "type": "ageRatingDeclarations",
                            "id": ageRatingID,
                            "attributes": ageRating.mapValues(\.jsonObject)
                        ]
                    ]
                )
                onOutput(L10n.text("Updated the age-rating declaration.\n"))
            }
        }

        if configuration.availableInAllTerritories == true {
            try await ensureAppAvailability(appID: appID, onOutput: onOutput)
        }
        if configuration.isFree == true {
            try await ensureFreeAppPrice(
                appID: appID,
                baseTerritory: configuration.baseTerritory?.nilIfEmpty ?? "USA",
                onOutput: onOutput
            )
        }
    }

    func reconcileSubscriptions(
        appID: String,
        catalog: AppStoreSubscriptionCatalog,
        requiresReviewAssets: Bool,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> [AppStoreConnectReviewItem] {
        guard !catalog.detectedProductIDs.isEmpty || !catalog.groups.isEmpty else {
            onOutput(L10n.text("No StoreKit subscriptions were detected in the app project.\n"))
            return []
        }

        let existingGroups = try await pagedData(
            path: "/v1/apps/\(appID)/subscriptionGroups",
            query: ["limit": "200"]
        )
        var existingSubscriptions: [String: [String: Any]] = [:]
        var existingSubscriptionGroupIDs: [String: String] = [:]
        var existingGroupNames: [String: String] = [:]
        for group in existingGroups {
            guard let groupID = group["id"] as? String else { continue }
            let groupAttributes = group["attributes"] as? [String: Any]
            existingGroupNames[groupID] = groupAttributes?["referenceName"] as? String
            for subscription in try await pagedData(
                path: "/v1/subscriptionGroups/\(groupID)/subscriptions",
                query: ["limit": "200"]
            ) {
                if let attributes = subscription["attributes"] as? [String: Any],
                   let productID = attributes["productId"] as? String {
                    existingSubscriptions[productID] = subscription
                    existingSubscriptionGroupIDs[productID] = groupID
                }
            }
        }

        let definitions = catalog.groups.flatMap(\.subscriptions)
        let definitionIDs = Set(definitions.map(\.productID))
        if let incomplete = catalog.detectedProductIDs
            .subtracting(Set(existingSubscriptions.keys))
            .subtracting(definitionIDs)
            .sorted()
            .first {
            throw AppStoreConnectError.incompleteSubscriptionConfiguration(incomplete)
        }
        if let missingPrice = definitions.first(where: {
            existingSubscriptions[$0.productID] == nil && $0.basePrice?.nilIfEmpty == nil
        }) {
            throw AppStoreConnectError.missingSubscriptionPrice(missingPrice.productID)
        }

        var reviewItems: [AppStoreConnectReviewItem] = []
        for groupDefinition in catalog.groups {
            try Task.checkCancellation()
            let matchingGroup = existingGroups.first(where: {
                let attributes = $0["attributes"] as? [String: Any]
                return (attributes?["referenceName"] as? String)?
                    .caseInsensitiveCompare(groupDefinition.referenceName) == .orderedSame
            })
            let groupID: String
            if let matchingGroup, let existingID = matchingGroup["id"] as? String {
                groupID = existingID
                onOutput(L10n.format("Using existing subscription group %@.\n", groupDefinition.referenceName))
            } else {
                let created = try await request(
                    method: "POST",
                    path: "/v1/subscriptionGroups",
                    body: [
                        "data": [
                            "type": "subscriptionGroups",
                            "attributes": ["referenceName": groupDefinition.referenceName],
                            "relationships": [
                                "app": ["data": ["type": "apps", "id": appID]]
                            ]
                        ]
                    ]
                )
                groupID = try Self.identifier(in: created, named: "subscription group")
                onOutput(L10n.format("Created subscription group %@.\n", groupDefinition.referenceName))
            }

            let groupVersionID = try await findOrCreateSubscriptionGroupVersion(groupID: groupID)
            try await upsertGroupLocalizations(
                groupDefinition.localizations ?? [],
                versionID: groupVersionID
            )
            reviewItems.append(
                AppStoreConnectReviewItem(
                    relationship: "subscriptionGroupVersion",
                    resourceType: "subscriptionGroupVersions",
                    id: groupVersionID,
                    label: groupDefinition.referenceName
                )
            )

            for definition in groupDefinition.subscriptions {
                try Task.checkCancellation()
                let subscriptionID: String
                if let existing = existingSubscriptions[definition.productID],
                   let existingID = existing["id"] as? String {
                    subscriptionID = existingID
                    try await updateSubscriptionIfEditable(definition, subscriptionID: subscriptionID)
                    onOutput(L10n.format("Using existing subscription %@.\n", definition.productID))
                } else {
                    let created = try await request(
                        method: "POST",
                        path: "/v1/subscriptions",
                        body: Self.subscriptionCreateBody(definition, groupID: groupID)
                    )
                    subscriptionID = try Self.identifier(in: created, named: "subscription")
                    existingSubscriptions[definition.productID] = created["data"] as? [String: Any]
                    onOutput(L10n.format("Created subscription %@.\n", definition.productID))
                }

                if definition.availableInAllTerritories == true {
                    try await ensureSubscriptionAvailability(
                        subscriptionID: subscriptionID,
                        onOutput: onOutput
                    )
                }
                if let price = definition.basePrice?.nilIfEmpty {
                    try await reconcileSubscriptionPrices(
                        subscriptionID: subscriptionID,
                        productID: definition.productID,
                        basePrice: price,
                        baseTerritory: definition.baseTerritory?.nilIfEmpty ?? "USA",
                        allTerritories: definition.availableInAllTerritories == true,
                        onOutput: onOutput
                    )
                }
                try await ensureSubscriptionReviewScreenshot(
                    subscriptionID: subscriptionID,
                    definition: definition,
                    projectDirectory: catalog.projectDirectory,
                    required: requiresReviewAssets,
                    onOutput: onOutput
                )

                let versionID = try await findOrCreateSubscriptionVersion(
                    subscriptionID: subscriptionID
                )
                try await upsertSubscriptionLocalizations(
                    definition.localizations ?? [],
                    versionID: versionID
                )
                reviewItems.append(
                    AppStoreConnectReviewItem(
                        relationship: "subscriptionVersion",
                        resourceType: "subscriptionVersions",
                        id: versionID,
                        label: definition.productID
                    )
                )
                onOutput(L10n.format("Subscription %@ is ready for the review submission.\n", definition.productID))
            }
        }

        let configuredIDs = Set(definitions.map(\.productID))
        for productID in catalog.detectedProductIDs.subtracting(configuredIDs).sorted() {
            guard let existing = existingSubscriptions[productID],
                  let subscriptionID = existing["id"] as? String else { continue }
            if let groupID = existingSubscriptionGroupIDs[productID] {
                let groupVersionID = try await findOrCreateSubscriptionGroupVersion(groupID: groupID)
                if !reviewItems.contains(where: { $0.id == groupVersionID }) {
                    reviewItems.append(
                        AppStoreConnectReviewItem(
                            relationship: "subscriptionGroupVersion",
                            resourceType: "subscriptionGroupVersions",
                            id: groupVersionID,
                            label: existingGroupNames[groupID] ?? groupID
                        )
                    )
                }
            }
            if requiresReviewAssets {
                do {
                    _ = try await request(
                        method: "GET",
                        path: "/v1/subscriptions/\(subscriptionID)/appStoreReviewScreenshot"
                    )
                } catch AppStoreConnectError.requestFailed(let status, _) where status == 404 {
                    throw AppStoreConnectError.missingSubscriptionReviewScreenshot(productID)
                }
            }
            let draft = try await findOrCreateSubscriptionVersion(
                subscriptionID: subscriptionID
            )
            reviewItems.append(
                AppStoreConnectReviewItem(
                    relationship: "subscriptionVersion",
                    resourceType: "subscriptionVersions",
                    id: draft,
                    label: productID
                )
            )
        }
        return reviewItems
    }

    func generateSubscriptionOfferCodes(
        bundleIdentifier: String,
        request generation: SubscriptionOfferCodeGenerationRequest
    ) async throws -> SubscriptionOfferCodeGenerationResult {
        let appID = try await findApplication(bundleIdentifier: bundleIdentifier)
        let subscriptionID = try await findSubscription(
            appID: appID,
            productID: generation.productID
        )
        let existingOffers = try await pagedData(
            path: "/v1/subscriptions/\(subscriptionID)/offerCodes",
            query: ["limit": "200"]
        )
        let matchingOffer = existingOffers.first(where: {
            let attributes = $0["attributes"] as? [String: Any]
            return (attributes?["name"] as? String)?
                .caseInsensitiveCompare(generation.offer.referenceName) == .orderedSame
        })

        let offerID: String
        if let matchingOffer, let existingID = matchingOffer["id"] as? String {
            guard Self.offerMatches(matchingOffer, configuration: generation.offer) else {
                throw AppStoreConnectError.offerCodeReferenceNameConflict(
                    generation.offer.referenceName
                )
            }
            offerID = existingID
        } else {
            let created = try await request(
                method: "POST",
                path: "/v1/subscriptionOfferCodes",
                body: Self.subscriptionOfferCreateBody(
                    generation.offer,
                    subscriptionID: subscriptionID
                )
            )
            offerID = try Self.identifier(in: created, named: "subscription offer code")
        }

        switch generation.kind {
        case .oneTime:
            guard let expirationDate = generation.expirationDate else {
                throw AppStoreConnectError.invalidResponse
            }
            let created = try await request(
                method: "POST",
                path: "/v1/subscriptionOfferCodeOneTimeUseCodes",
                body: Self.oneTimeOfferCodeCreateBody(
                    offerID: offerID,
                    numberOfCodes: generation.numberOfCodes,
                    expirationDate: expirationDate
                )
            )
            let batchID = try Self.identifier(in: created, named: "one-time offer-code batch")
            var csv: Data?
            for attempt in 0..<24 {
                try Task.checkCancellation()
                csv = try await requestCSV(
                    path: "/v1/subscriptionOfferCodeOneTimeUseCodes/\(batchID)/values"
                )
                if csv?.isEmpty == false { break }
                if attempt < 23 {
                    try await Task.sleep(for: .seconds(5))
                }
            }
            return SubscriptionOfferCodeGenerationResult(
                offerID: offerID,
                batchID: batchID,
                customCode: nil,
                oneTimeCodeCSV: csv
            )

        case .custom:
            let customCode = generation.customCode?.uppercased() ?? ""
            let created = try await request(
                method: "POST",
                path: "/v1/subscriptionOfferCodeCustomCodes",
                body: Self.customOfferCodeCreateBody(
                    offerID: offerID,
                    customCode: customCode,
                    numberOfCodes: generation.numberOfCodes,
                    expirationDate: generation.expirationDate
                )
            )
            let batchID = try Self.identifier(in: created, named: "custom offer-code batch")
            return SubscriptionOfferCodeGenerationResult(
                offerID: offerID,
                batchID: batchID,
                customCode: customCode,
                oneTimeCodeCSV: nil
            )
        }
    }

    func uploadScreenshots(
        _ screenshots: [AppStoreScreenshotAsset],
        localizationID: String,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws {
        for group in Dictionary(grouping: screenshots, by: \AppStoreScreenshotAsset.displayType).sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation()
            let displayType = group.key
            let setResponse = try await request(
                method: "GET",
                path: "/v1/appStoreVersionLocalizations/\(localizationID)/appScreenshotSets",
                query: ["filter[screenshotDisplayType]": displayType, "include": "appScreenshots", "limit": "50"]
            )
            let existingScreenshots = (setResponse["included"] as? [[String: Any]])?.filter {
                $0["type"] as? String == "appScreenshots"
            } ?? []
            if !existingScreenshots.isEmpty {
                onOutput(L10n.format("Keeping %d existing screenshot(s) for %@.\n", existingScreenshots.count, displayType))
                continue
            }

            let screenshotSetID: String
            if let existingSet = (setResponse["data"] as? [[String: Any]])?.first,
               let id = existingSet["id"] as? String {
                screenshotSetID = id
            } else {
                let created = try await request(
                    method: "POST",
                    path: "/v1/appScreenshotSets",
                    body: [
                        "data": [
                            "type": "appScreenshotSets",
                            "attributes": ["screenshotDisplayType": displayType],
                            "relationships": [
                                "appStoreVersionLocalization": [
                                    "data": ["type": "appStoreVersionLocalizations", "id": localizationID]
                                ]
                            ]
                        ]
                    ]
                )
                screenshotSetID = try Self.identifier(in: created, named: "screenshot set")
            }

            for screenshot in group.value.prefix(10) {
                try await uploadScreenshot(
                    screenshot,
                    screenshotSetID: screenshotSetID,
                    onOutput: onOutput
                )
            }
        }
    }

    func waitForBuild(
        appID: String,
        buildNumber: String,
        timeout: TimeInterval = 30 * 60,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            let response = try await request(
                method: "GET",
                path: "/v1/builds",
                query: [
                    "filter[app]": appID,
                    "filter[version]": buildNumber,
                    "sort": "-uploadedDate",
                    "limit": "10"
                ]
            )
            if let build = (response["data"] as? [[String: Any]])?.first,
               let id = build["id"] as? String {
                let attributes = build["attributes"] as? [String: Any]
                let state = attributes?["processingState"] as? String ?? "PROCESSING"
                if state == "VALID" { return id }
                if state == "FAILED" || state == "INVALID" {
                    throw AppStoreConnectError.requestFailed(422, L10n.format("Build processing finished with state %@.", state))
                }
                onOutput(L10n.format("App Store build processing: %@.\n", state))
            } else {
                onOutput(L10n.text("Waiting for the uploaded build to appear in App Store Connect…\n"))
            }
            try await Task.sleep(for: .seconds(30))
        }
        throw AppStoreConnectError.buildProcessingTimedOut
    }

    func attachBuild(_ buildID: String, toVersion versionID: String) async throws {
        _ = try await request(
            method: "PATCH",
            path: "/v1/appStoreVersions/\(versionID)/relationships/build",
            body: ["data": ["type": "builds", "id": buildID]]
        )
    }

    func submitForReview(
        appID: String,
        versionID: String,
        additionalItems: [AppStoreConnectReviewItem] = []
    ) async throws {
        let submissionResponse: [String: Any]
        do {
            submissionResponse = try await request(
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
        } catch AppStoreConnectError.requestFailed(let status, _) where status == 409 {
            let existing = try await request(
                method: "GET",
                path: "/v1/apps/\(appID)/reviewSubmissions",
                query: [
                    "filter[platform]": "IOS",
                    "filter[state]": "READY_FOR_REVIEW,UNRESOLVED_ISSUES",
                    "limit": "50"
                ]
            )
            guard let unresolved = (existing["data"] as? [[String: Any]])?.first else {
                throw AppStoreConnectError.requestFailed(409, L10n.text("An active review submission could not be located."))
            }
            submissionResponse = ["data": unresolved]
        }
        let submissionID = try Self.identifier(in: submissionResponse, named: "review submission")

        let appVersionItem = AppStoreConnectReviewItem(
            relationship: "appStoreVersion",
            resourceType: "appStoreVersions",
            id: versionID,
            label: "App Store version"
        )
        for item in [appVersionItem] + additionalItems {
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
            } catch AppStoreConnectError.requestFailed(let status, _) where status == 409 {
                // The item is already attached to this active review submission.
            }
        }

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

    static func jwt(
        issuerID: String,
        keyID: String,
        privateKey: P256.Signing.PrivateKey,
        now: Date = Date()
    ) throws -> String {
        let header: [String: Any] = ["alg": "ES256", "kid": keyID, "typ": "JWT"]
        let issuedAt = Int(now.timeIntervalSince1970)
        let payload: [String: Any] = [
            "iss": issuerID,
            "iat": issuedAt,
            "exp": issuedAt + 1_100,
            "aud": "appstoreconnect-v1"
        ]
        let encodedHeader = base64URL(try JSONSerialization.data(withJSONObject: header))
        let encodedPayload = base64URL(try JSONSerialization.data(withJSONObject: payload))
        let signingInput = "\(encodedHeader).\(encodedPayload)"
        guard let signingData = signingInput.data(using: .utf8) else {
            throw AppStoreConnectError.invalidPrivateKey
        }
        let signature = try privateKey.signature(for: signingData)
        return "\(signingInput).\(base64URL(signature.rawRepresentation))"
    }

    private func findApplication(bundleIdentifier: String) async throws -> String {
        let response = try await request(
            method: "GET",
            path: "/v1/apps",
            query: ["filter[bundleId]": bundleIdentifier, "limit": "1"]
        )
        guard let app = (response["data"] as? [[String: Any]])?.first,
              let appID = app["id"] as? String else {
            throw AppStoreConnectError.applicationNotFound(bundleIdentifier)
        }
        return appID
    }

    private func findSubscription(appID: String, productID: String) async throws -> String {
        let groups = try await pagedData(
            path: "/v1/apps/\(appID)/subscriptionGroups",
            query: ["limit": "200"]
        )
        for group in groups {
            guard let groupID = group["id"] as? String else { continue }
            let subscriptions = try await pagedData(
                path: "/v1/subscriptionGroups/\(groupID)/subscriptions",
                query: ["limit": "200"]
            )
            if let subscription = subscriptions.first(where: {
                let attributes = $0["attributes"] as? [String: Any]
                return attributes?["productId"] as? String == productID
            }), let subscriptionID = subscription["id"] as? String {
                return subscriptionID
            }
        }
        throw AppStoreConnectError.subscriptionNotFound(productID)
    }

    private func hasPublishedVersion(appID: String, otherThan version: String) async throws -> Bool {
        let versions = try await pagedData(
            path: "/v1/apps/\(appID)/appStoreVersions",
            query: ["filter[platform]": "IOS", "limit": "200"]
        )
        return Self.isVersionOnlyUpdate(versions: versions, currentVersion: version)
    }

    static func isVersionOnlyUpdate(
        versions: [[String: Any]],
        currentVersion: String
    ) -> Bool {
        let publishedStates: Set<String> = [
            "READY_FOR_SALE",
            "PREORDER_READY_FOR_SALE",
            "REPLACED_WITH_NEW_VERSION",
            "DEVELOPER_REMOVED_FROM_SALE",
            "REMOVED_FROM_SALE"
        ]
        return versions.contains { item in
            guard let attributes = item["attributes"] as? [String: Any],
                  let state = attributes["appStoreState"] as? String,
                  publishedStates.contains(state) else { return false }
            return attributes["versionString"] as? String != currentVersion
        }
    }

    private func configureReviewDetails(
        versionID: String,
        review: AppStoreReviewConfiguration
    ) async throws {
        guard !review.contactFirstName.isEmpty
                || !review.contactLastName.isEmpty
                || !review.contactPhone.isEmpty
                || !review.contactEmail.isEmpty
                || !review.notes.isEmpty
                || review.demoAccountRequired else { return }
        let attributes: [String: Any] = [
            "contactFirstName": review.contactFirstName,
            "contactLastName": review.contactLastName,
            "contactPhone": review.contactPhone,
            "contactEmail": review.contactEmail,
            "demoAccountRequired": review.demoAccountRequired,
            "notes": review.notes,
            "demoAccountName": review.demoAccountRequired ? (review.demoAccountName ?? "") : "",
            "demoAccountPassword": review.demoAccountRequired ? (review.demoAccountPassword ?? "") : ""
        ]
        do {
            let existing = try await request(
                method: "GET",
                path: "/v1/appStoreVersions/\(versionID)/appStoreReviewDetail"
            )
            let reviewID = try Self.identifier(in: existing, named: "App Review details")
            _ = try await request(
                method: "PATCH",
                path: "/v1/appStoreReviewDetails/\(reviewID)",
                body: [
                    "data": [
                        "type": "appStoreReviewDetails",
                        "id": reviewID,
                        "attributes": attributes
                    ]
                ]
            )
        } catch AppStoreConnectError.requestFailed(let status, _) where status == 404 {
            _ = try await request(
                method: "POST",
                path: "/v1/appStoreReviewDetails",
                body: [
                    "data": [
                        "type": "appStoreReviewDetails",
                        "attributes": attributes,
                        "relationships": [
                            "appStoreVersion": [
                                "data": ["type": "appStoreVersions", "id": versionID]
                            ]
                        ]
                    ]
                ]
            )
        }
    }

    private func ensureAppAvailability(
        appID: String,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws {
        do {
            _ = try await request(method: "GET", path: "/v1/apps/\(appID)/appAvailabilityV2")
            onOutput(L10n.text("Keeping the existing app territory availability.\n"))
            return
        } catch AppStoreConnectError.requestFailed(let status, _) where status == 404 {
            // Create the initial availability below.
        }
        let territories = try await pagedData(path: "/v1/territories", query: ["limit": "200"])
        let territoryIDs = territories.compactMap { $0["id"] as? String }
        let linkages = territoryIDs.map {
            ["type": "territoryAvailabilities", "id": "availability-\($0)"]
        }
        let included: [[String: Any]] = territoryIDs.map {
            [
                "type": "territoryAvailabilities",
                "id": "availability-\($0)",
                "attributes": ["available": true],
                "relationships": [
                    "territory": ["data": ["type": "territories", "id": $0]]
                ]
            ]
        }
        _ = try await request(
            method: "POST",
            path: "/v2/appAvailabilities",
            body: [
                "data": [
                    "type": "appAvailabilities",
                    "attributes": ["availableInNewTerritories": true],
                    "relationships": [
                        "app": ["data": ["type": "apps", "id": appID]],
                        "territoryAvailabilities": ["data": linkages]
                    ]
                ],
                "included": included
            ]
        )
        onOutput(L10n.format("Enabled app availability in %d territories.\n", territoryIDs.count))
    }

    private func ensureFreeAppPrice(
        appID: String,
        baseTerritory: String,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws {
        do {
            _ = try await request(method: "GET", path: "/v1/apps/\(appID)/appPriceSchedule")
            onOutput(L10n.text("Keeping the existing app price schedule.\n"))
            return
        } catch AppStoreConnectError.requestFailed(let status, _) where status == 404 {
            // Create the initial free price schedule below.
        }
        let points = try await pagedData(
            path: "/v1/apps/\(appID)/appPricePoints",
            query: ["filter[territory]": baseTerritory, "limit": "200"]
        )
        guard let free = points.first(where: {
            let attributes = $0["attributes"] as? [String: Any]
            return Self.pricesEqual(attributes?["customerPrice"], "0")
        }), let pointID = free["id"] as? String else {
            throw AppStoreConnectError.requestFailed(
                422,
                L10n.format("No free app price point was returned for %@.", baseTerritory)
            )
        }
        let inlinePriceID = "initial-free-price"
        _ = try await request(
            method: "POST",
            path: "/v1/appPriceSchedules",
            body: [
                "data": [
                    "type": "appPriceSchedules",
                    "relationships": [
                        "app": ["data": ["type": "apps", "id": appID]],
                        "baseTerritory": [
                            "data": ["type": "territories", "id": baseTerritory]
                        ],
                        "manualPrices": [
                            "data": [["type": "appPrices", "id": inlinePriceID]]
                        ]
                    ]
                ],
                "included": [[
                    "type": "appPrices",
                    "id": inlinePriceID,
                    "relationships": [
                        "appPricePoint": [
                            "data": ["type": "appPricePoints", "id": pointID]
                        ]
                    ]
                ]]
            ]
        )
        onOutput(L10n.format("Configured the app as Free with base territory %@.\n", baseTerritory))
    }

    static func subscriptionCreateBody(
        _ definition: AppStoreSubscriptionDefinition,
        groupID: String
    ) -> [String: Any] {
        var attributes: [String: Any] = [
            "name": definition.referenceName,
            "productId": definition.productID,
            "subscriptionPeriod": definition.period
        ]
        if definition.familySharable == true {
            // Apple treats Family Sharing as effectively one-way once subscribers exist.
            attributes["familySharable"] = true
        }
        if let groupLevel = definition.groupLevel {
            attributes["groupLevel"] = groupLevel
        }
        if let reviewNote = definition.reviewNote?.nilIfEmpty {
            attributes["reviewNote"] = reviewNote
        }
        return [
            "data": [
                "type": "subscriptions",
                "attributes": attributes,
                "relationships": [
                    "group": [
                        "data": ["type": "subscriptionGroups", "id": groupID]
                    ]
                ]
            ]
        ]
    }

    static func subscriptionOfferCreateBody(
        _ configuration: SubscriptionOfferConfiguration,
        subscriptionID: String
    ) -> [String: Any] {
        [
            "data": [
                "type": "subscriptionOfferCodes",
                "attributes": [
                    "name": configuration.referenceName,
                    "customerEligibilities": configuration.customerEligibilities
                        .map(\.rawValue)
                        .sorted(),
                    "offerEligibility": configuration.stackWithIntroductoryOffer
                        ? "STACK_WITH_INTRO_OFFERS"
                        : "REPLACE_INTRO_OFFERS",
                    "duration": configuration.duration.rawValue,
                    "offerMode": "FREE_TRIAL",
                    "numberOfPeriods": 1,
                    "autoRenewEnabled": configuration.autoRenewEnabled
                ],
                "relationships": [
                    "subscription": [
                        "data": ["type": "subscriptions", "id": subscriptionID]
                    ],
                    "prices": ["data": []]
                ]
            ]
        ]
    }

    static func oneTimeOfferCodeCreateBody(
        offerID: String,
        numberOfCodes: Int,
        expirationDate: Date,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> [String: Any] {
        [
            "data": [
                "type": "subscriptionOfferCodeOneTimeUseCodes",
                "attributes": [
                    "numberOfCodes": numberOfCodes,
                    "expirationDate": dayString(expirationDate, calendar: calendar),
                    "environment": "PRODUCTION"
                ],
                "relationships": [
                    "offerCode": [
                        "data": ["type": "subscriptionOfferCodes", "id": offerID]
                    ]
                ]
            ]
        ]
    }

    static func customOfferCodeCreateBody(
        offerID: String,
        customCode: String,
        numberOfCodes: Int,
        expirationDate: Date?,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> [String: Any] {
        var attributes: [String: Any] = [
            "customCode": customCode,
            "numberOfCodes": numberOfCodes
        ]
        if let expirationDate {
            attributes["expirationDate"] = dayString(expirationDate, calendar: calendar)
        }
        return [
            "data": [
                "type": "subscriptionOfferCodeCustomCodes",
                "attributes": attributes,
                "relationships": [
                    "offerCode": [
                        "data": ["type": "subscriptionOfferCodes", "id": offerID]
                    ]
                ]
            ]
        ]
    }

    private func updateSubscriptionIfEditable(
        _ definition: AppStoreSubscriptionDefinition,
        subscriptionID: String
    ) async throws {
        var attributes: [String: Any] = [
            "name": definition.referenceName,
            "subscriptionPeriod": definition.period
        ]
        if let familySharable = definition.familySharable {
            attributes["familySharable"] = familySharable
        }
        if let groupLevel = definition.groupLevel {
            attributes["groupLevel"] = groupLevel
        }
        if let reviewNote = definition.reviewNote?.nilIfEmpty {
            attributes["reviewNote"] = reviewNote
        }
        do {
            _ = try await request(
                method: "PATCH",
                path: "/v1/subscriptions/\(subscriptionID)",
                body: [
                    "data": [
                        "type": "subscriptions",
                        "id": subscriptionID,
                        "attributes": attributes
                    ]
                ]
            )
        } catch AppStoreConnectError.requestFailed(let status, _) where status == 409 || status == 422 {
            // Preserve locked product attributes; its versioned metadata can still be reconciled.
        }
    }

    private func findOrCreateSubscriptionGroupVersion(groupID: String) async throws -> String {
        let drafts = try await pagedData(
            path: "/v1/subscriptionGroups/\(groupID)/versions",
            query: ["filter[state]": "PREPARE_FOR_SUBMISSION", "limit": "200"]
        )
        if let id = drafts.first?["id"] as? String { return id }
        let created = try await request(
            method: "POST",
            path: "/v1/subscriptionGroupVersions",
            body: [
                "data": [
                    "type": "subscriptionGroupVersions",
                    "relationships": [
                        "subscriptionGroup": [
                            "data": ["type": "subscriptionGroups", "id": groupID]
                        ]
                    ]
                ]
            ]
        )
        return try Self.identifier(in: created, named: "subscription group version")
    }

    private func editableSubscriptionVersion(subscriptionID: String) async throws -> String? {
        try await pagedData(
            path: "/v1/subscriptions/\(subscriptionID)/versions",
            query: ["filter[state]": "PREPARE_FOR_SUBMISSION", "limit": "200"]
        ).first?["id"] as? String
    }

    private func findOrCreateSubscriptionVersion(subscriptionID: String) async throws -> String {
        if let existing = try await editableSubscriptionVersion(subscriptionID: subscriptionID) {
            return existing
        }
        let created = try await request(
            method: "POST",
            path: "/v1/subscriptionVersions",
            body: [
                "data": [
                    "type": "subscriptionVersions",
                    "relationships": [
                        "subscription": [
                            "data": ["type": "subscriptions", "id": subscriptionID]
                        ]
                    ]
                ]
            ]
        )
        return try Self.identifier(in: created, named: "subscription version")
    }

    private func upsertGroupLocalizations(
        _ localizations: [AppStoreSubscriptionLocalization],
        versionID: String
    ) async throws {
        let existing = try await pagedData(
            path: "/v1/subscriptionGroupVersions/\(versionID)/localizations",
            query: ["limit": "50"]
        )
        for localization in localizations {
            let match = existing.first(where: {
                let attributes = $0["attributes"] as? [String: Any]
                return attributes?["locale"] as? String == localization.locale
            })
            var attributes: [String: Any] = [
                "locale": localization.locale,
                "name": localization.name
            ]
            if let customName = localization.description?.nilIfEmpty {
                attributes["customAppName"] = customName
            }
            if let localizationID = match?["id"] as? String {
                _ = try await request(
                    method: "PATCH",
                    path: "/v2/subscriptionGroupLocalizations/\(localizationID)",
                    body: [
                        "data": [
                            "type": "subscriptionGroupLocalizations",
                            "id": localizationID,
                            "attributes": attributes
                        ]
                    ]
                )
            } else {
                _ = try await request(
                    method: "POST",
                    path: "/v2/subscriptionGroupLocalizations",
                    body: [
                        "data": [
                            "type": "subscriptionGroupLocalizations",
                            "attributes": attributes,
                            "relationships": [
                                "version": [
                                    "data": [
                                        "type": "subscriptionGroupVersions",
                                        "id": versionID
                                    ]
                                ]
                            ]
                        ]
                    ]
                )
            }
        }
    }

    private func upsertSubscriptionLocalizations(
        _ localizations: [AppStoreSubscriptionLocalization],
        versionID: String
    ) async throws {
        let existing = try await pagedData(
            path: "/v1/subscriptionVersions/\(versionID)/localizations",
            query: ["limit": "50"]
        )
        for localization in localizations {
            let match = existing.first(where: {
                let attributes = $0["attributes"] as? [String: Any]
                return attributes?["locale"] as? String == localization.locale
            })
            var attributes: [String: Any] = [
                "locale": localization.locale,
                "name": localization.name
            ]
            if let description = localization.description?.nilIfEmpty {
                attributes["description"] = description
            }
            if let localizationID = match?["id"] as? String {
                _ = try await request(
                    method: "PATCH",
                    path: "/v2/subscriptionLocalizations/\(localizationID)",
                    body: [
                        "data": [
                            "type": "subscriptionLocalizations",
                            "id": localizationID,
                            "attributes": attributes
                        ]
                    ]
                )
            } else {
                _ = try await request(
                    method: "POST",
                    path: "/v2/subscriptionLocalizations",
                    body: [
                        "data": [
                            "type": "subscriptionLocalizations",
                            "attributes": attributes,
                            "relationships": [
                                "version": [
                                    "data": ["type": "subscriptionVersions", "id": versionID]
                                ]
                            ]
                        ]
                    ]
                )
            }
        }
    }

    private func ensureSubscriptionAvailability(
        subscriptionID: String,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws {
        do {
            _ = try await request(
                method: "GET",
                path: "/v1/subscriptions/\(subscriptionID)/subscriptionAvailability"
            )
            return
        } catch AppStoreConnectError.requestFailed(let status, _) where status == 404 {
            // Create the initial availability below.
        }
        let territories = try await pagedData(path: "/v1/territories", query: ["limit": "200"])
        let territoryIDs = territories.compactMap { $0["id"] as? String }
        _ = try await request(
            method: "POST",
            path: "/v1/subscriptionAvailabilities",
            body: [
                "data": [
                    "type": "subscriptionAvailabilities",
                    "attributes": ["availableInNewTerritories": true],
                    "relationships": [
                        "subscription": [
                            "data": ["type": "subscriptions", "id": subscriptionID]
                        ],
                        "availableTerritories": [
                            "data": territoryIDs.map {
                                ["type": "territories", "id": $0]
                            }
                        ]
                    ]
                ]
            ]
        )
        onOutput(L10n.format("Enabled subscription availability in %d territories.\n", territoryIDs.count))
    }

    private func reconcileSubscriptionPrices(
        subscriptionID: String,
        productID: String,
        basePrice: String,
        baseTerritory: String,
        allTerritories: Bool,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws {
        var pricePoints: [[String: Any]] = []
        for attempt in 0..<5 {
            pricePoints = try await pagedData(
                path: "/v1/subscriptions/\(subscriptionID)/pricePoints",
                query: ["filter[territory]": baseTerritory, "limit": "200"]
            )
            if !pricePoints.isEmpty { break }
            if attempt < 4 { try await Task.sleep(for: .seconds(2)) }
        }
        guard let basePoint = pricePoints.first(where: {
            let attributes = $0["attributes"] as? [String: Any]
            return Self.pricesEqual(attributes?["customerPrice"], basePrice)
        }), let basePointID = basePoint["id"] as? String else {
            throw AppStoreConnectError.requestFailed(
                422,
                L10n.format("Price %@ is not an available subscription price point in %@ for %@.", basePrice, baseTerritory, productID)
            )
        }

        var desiredPointIDs = [basePointID]
        if allTerritories {
            desiredPointIDs.append(contentsOf: try await pagedData(
                path: "/v1/subscriptionPricePoints/\(basePointID)/equalizations",
                query: ["limit": "8000"]
            ).compactMap { $0["id"] as? String })
        }
        let existingPrices = try await pagedData(
            path: "/v1/subscriptions/\(subscriptionID)/prices",
            query: [
                "fields[subscriptionPrices]": "subscriptionPricePoint",
                "limit": "200"
            ]
        )
        let existingPointIDs = Set(existingPrices.compactMap { price -> String? in
            let relationships = price["relationships"] as? [String: Any]
            let relationship = relationships?["subscriptionPricePoint"] as? [String: Any]
            let data = relationship?["data"] as? [String: Any]
            return data?["id"] as? String
        })

        var createdCount = 0
        for pointID in Set(desiredPointIDs).subtracting(existingPointIDs).sorted() {
            try Task.checkCancellation()
            do {
                _ = try await request(
                    method: "POST",
                    path: "/v1/subscriptionPrices",
                    body: [
                        "data": [
                            "type": "subscriptionPrices",
                            "attributes": [
                                "preserveCurrentPrice": false
                            ],
                            "relationships": [
                                "subscription": [
                                    "data": ["type": "subscriptions", "id": subscriptionID]
                                ],
                                "subscriptionPricePoint": [
                                    "data": ["type": "subscriptionPricePoints", "id": pointID]
                                ]
                            ]
                        ]
                    ]
                )
                createdCount += 1
            } catch AppStoreConnectError.requestFailed(let status, _) where status == 409 {
                // The same price point is already scheduled.
            }
        }
        onOutput(L10n.format(
            "Subscription %@ uses %@ in %@; configured %d missing territory price(s).\n",
            productID,
            basePrice,
            baseTerritory,
            createdCount
        ))
    }

    private func ensureSubscriptionReviewScreenshot(
        subscriptionID: String,
        definition: AppStoreSubscriptionDefinition,
        projectDirectory: URL,
        required: Bool,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws {
        do {
            _ = try await request(
                method: "GET",
                path: "/v1/subscriptions/\(subscriptionID)/appStoreReviewScreenshot"
            )
            return
        } catch AppStoreConnectError.requestFailed(let status, _) where status == 404 {
            // Upload the project asset below when available.
        }
        guard let rawPath = definition.reviewScreenshot?.nilIfEmpty else {
            if required {
                throw AppStoreConnectError.missingSubscriptionReviewScreenshot(definition.productID)
            }
            return
        }
        let screenshotURL = rawPath.hasPrefix("/")
            ? URL(fileURLWithPath: rawPath)
            : projectDirectory.appendingPathComponent(rawPath)
        guard FileManager.default.fileExists(atPath: screenshotURL.path) else {
            if required {
                throw AppStoreConnectError.missingSubscriptionReviewScreenshot(definition.productID)
            }
            return
        }
        let fileData = try Data(contentsOf: screenshotURL)
        let reserved = try await request(
            method: "POST",
            path: "/v1/subscriptionAppStoreReviewScreenshots",
            body: [
                "data": [
                    "type": "subscriptionAppStoreReviewScreenshots",
                    "attributes": [
                        "fileName": screenshotURL.lastPathComponent,
                        "fileSize": fileData.count
                    ],
                    "relationships": [
                        "subscription": [
                            "data": ["type": "subscriptions", "id": subscriptionID]
                        ]
                    ]
                ]
            ]
        )
        let screenshotID = try Self.identifier(in: reserved, named: "subscription review screenshot")
        try await uploadReservedAsset(data: fileData, response: reserved)
        _ = try await request(
            method: "PATCH",
            path: "/v1/subscriptionAppStoreReviewScreenshots/\(screenshotID)",
            body: [
                "data": [
                    "type": "subscriptionAppStoreReviewScreenshots",
                    "id": screenshotID,
                    "attributes": ["uploaded": true]
                ]
            ]
        )
        onOutput(L10n.format("Uploaded the App Review paywall screenshot for %@.\n", definition.productID))
    }

    private func updateLocalization(
        _ localizationID: String,
        metadata: AppStoreMetadata,
        supportURL: String,
        includesReleaseNotes: Bool
    ) async throws {
        var attributes: [String: Any] = [
            "description": metadata.description,
            "keywords": metadata.keywords,
            "promotionalText": metadata.promotionalText,
            "supportUrl": supportURL
        ]
        if includesReleaseNotes {
            attributes["whatsNew"] = metadata.whatsNew
        }
        _ = try await request(
            method: "PATCH",
            path: "/v1/appStoreVersionLocalizations/\(localizationID)",
            body: [
                "data": [
                    "type": "appStoreVersionLocalizations",
                    "id": localizationID,
                    "attributes": attributes
                ]
            ]
        )
    }

    private func findOrCreateVersion(
        appID: String,
        version: String,
        copyright: String,
        releaseAutomatically: Bool
    ) async throws -> String {
        let response = try await request(
            method: "GET",
            path: "/v1/apps/\(appID)/appStoreVersions",
            query: ["filter[platform]": "IOS", "filter[versionString]": version, "limit": "10"]
        )
        if let existing = (response["data"] as? [[String: Any]])?.first,
           let id = existing["id"] as? String {
            _ = try await request(
                method: "PATCH",
                path: "/v1/appStoreVersions/\(id)",
                body: [
                    "data": [
                        "type": "appStoreVersions",
                        "id": id,
                        "attributes": [
                            "releaseType": releaseAutomatically ? "AFTER_APPROVAL" : "MANUAL",
                            "copyright": copyright
                        ]
                    ]
                ]
            )
            return id
        }
        let created = try await request(
            method: "POST",
            path: "/v1/appStoreVersions",
            body: [
                "data": [
                    "type": "appStoreVersions",
                    "attributes": [
                        "platform": "IOS",
                        "versionString": version,
                        "copyright": copyright,
                        "releaseType": releaseAutomatically ? "AFTER_APPROVAL" : "MANUAL"
                    ],
                    "relationships": ["app": ["data": ["type": "apps", "id": appID]]]
                ]
            ]
        )
        return try Self.identifier(in: created, named: "App Store version")
    }

    private func findOrCreateLocalization(versionID: String, locale: String) async throws -> String {
        let response = try await request(
            method: "GET",
            path: "/v1/appStoreVersions/\(versionID)/appStoreVersionLocalizations",
            query: ["filter[locale]": locale, "limit": "10"]
        )
        if let existing = (response["data"] as? [[String: Any]])?.first,
           let id = existing["id"] as? String {
            return id
        }
        let created = try await request(
            method: "POST",
            path: "/v1/appStoreVersionLocalizations",
            body: [
                "data": [
                    "type": "appStoreVersionLocalizations",
                    "attributes": ["locale": locale],
                    "relationships": [
                        "appStoreVersion": [
                            "data": ["type": "appStoreVersions", "id": versionID]
                        ]
                    ]
                ]
            ]
        )
        return try Self.identifier(in: created, named: "localization")
    }

    private func uploadScreenshot(
        _ screenshot: AppStoreScreenshotAsset,
        screenshotSetID: String,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws {
        let fileData = try Data(contentsOf: screenshot.url)
        let reserved = try await request(
            method: "POST",
            path: "/v1/appScreenshots",
            body: [
                "data": [
                    "type": "appScreenshots",
                    "attributes": [
                        "fileName": screenshot.url.lastPathComponent,
                        "fileSize": fileData.count
                    ],
                    "relationships": [
                        "appScreenshotSet": [
                            "data": ["type": "appScreenshotSets", "id": screenshotSetID]
                        ]
                    ]
                ]
            ]
        )
        let screenshotID = try Self.identifier(in: reserved, named: "screenshot")
        try await uploadReservedAsset(data: fileData, response: reserved)
        _ = try await request(
            method: "PATCH",
            path: "/v1/appScreenshots/\(screenshotID)",
            body: [
                "data": [
                    "type": "appScreenshots",
                    "id": screenshotID,
                    "attributes": ["uploaded": true]
                ]
            ]
        )
        onOutput(L10n.format("Uploaded screenshot %@.\n", screenshot.url.lastPathComponent))
    }

    private func uploadReservedAsset(data fileData: Data, response: [String: Any]) async throws {
        guard let data = response["data"] as? [String: Any],
              let attributes = data["attributes"] as? [String: Any],
              let operations = attributes["uploadOperations"] as? [[String: Any]] else {
            throw AppStoreConnectError.invalidResponse
        }
        for operation in operations {
            guard let rawURL = operation["url"] as? String,
                  let url = URL(string: rawURL),
                  let method = operation["method"] as? String,
                  let offset = operation["offset"] as? Int,
                  let length = operation["length"] as? Int,
                  offset >= 0, length >= 0, offset + length <= fileData.count else {
                throw AppStoreConnectError.invalidResponse
            }
            var uploadRequest = URLRequest(url: url)
            uploadRequest.httpMethod = method
            for header in operation["requestHeaders"] as? [[String: Any]] ?? [] {
                if let name = header["name"] as? String, let value = header["value"] as? String {
                    uploadRequest.setValue(value, forHTTPHeaderField: name)
                }
            }
            uploadRequest.httpBody = fileData.subdata(in: offset..<(offset + length))
            let (_, response) = try await session.data(for: uploadRequest)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw AppStoreConnectError.requestFailed(
                    (response as? HTTPURLResponse)?.statusCode ?? 0,
                    L10n.text("Screenshot asset upload failed.")
                )
            }
        }
    }

    private func pagedData(
        path: String,
        query: [String: String] = [:]
    ) async throws -> [[String: Any]] {
        var results: [[String: Any]] = []
        var nextPath: String? = path
        var nextQuery = query
        while let currentPath = nextPath {
            let response = try await request(
                method: "GET",
                path: currentPath,
                query: nextQuery
            )
            results.append(contentsOf: response["data"] as? [[String: Any]] ?? [])
            let links = response["links"] as? [String: Any]
            nextPath = links?["next"] as? String
            nextQuery = [:]
        }
        return results
    }

    private func request(
        method: String,
        path: String,
        query: [String: String] = [:],
        body: [String: Any]? = nil,
        retryCount: Int = 0
    ) async throws -> [String: Any] {
        let requestURL: URL
        if path.hasPrefix("https://"), let absoluteURL = URL(string: path) {
            requestURL = absoluteURL
        } else {
            requestURL = baseURL.appendingPathComponent(path)
        }
        var components = URLComponents(url: requestURL, resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.sorted(by: { $0.key < $1.key }).map(URLQueryItem.init)
        }
        guard let url = components.url else { throw AppStoreConnectError.invalidResponse }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method
        urlRequest.setValue("Bearer \(try token())", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 120
        if let body {
            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw AppStoreConnectError.invalidResponse
        }
        if http.statusCode == 429, retryCount < 5 {
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                .flatMap(Double.init) ?? pow(2, Double(retryCount + 1))
            try await Task.sleep(for: .seconds(min(retryAfter, 30)))
            return try await request(
                method: method,
                path: path,
                query: query,
                body: body,
                retryCount: retryCount + 1
            )
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AppStoreConnectError.requestFailed(http.statusCode, Self.errorMessage(from: data))
        }
        if data.isEmpty { return [:] }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppStoreConnectError.invalidResponse
        }
        return root
    }

    private func requestCSV(
        path: String,
        retryCount: Int = 0
    ) async throws -> Data? {
        let requestURL = baseURL.appendingPathComponent(path)
        var urlRequest = URLRequest(url: requestURL)
        urlRequest.httpMethod = "GET"
        urlRequest.setValue("Bearer \(try token())", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("text/csv", forHTTPHeaderField: "Accept")
        urlRequest.timeoutInterval = 120
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw AppStoreConnectError.invalidResponse
        }
        if http.statusCode == 429, retryCount < 5 {
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                .flatMap(Double.init) ?? pow(2, Double(retryCount + 1))
            try await Task.sleep(for: .seconds(min(retryAfter, 30)))
            return try await requestCSV(path: path, retryCount: retryCount + 1)
        }
        if http.statusCode == 404 || http.statusCode == 409 {
            return nil
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AppStoreConnectError.requestFailed(http.statusCode, Self.errorMessage(from: data))
        }
        return data
    }

    private func token() throws -> String {
        try Self.jwt(issuerID: issuerID, keyID: keyID, privateKey: privateKey)
    }

    private static func identifier(in response: [String: Any], named name: String) throws -> String {
        guard let data = response["data"] as? [String: Any], let id = data["id"] as? String else {
            throw AppStoreConnectError.missingIdentifier(name)
        }
        return id
    }

    private static func errorMessage(from data: Data) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8) ?? L10n.text("Unknown error")
        }
        if let errors = root["errors"] as? [[String: Any]], !errors.isEmpty {
            return errors.compactMap {
                ($0["detail"] as? String) ?? ($0["title"] as? String)
            }.joined(separator: "\n")
        }
        return L10n.text("Unknown error")
    }

    private static func offerMatches(
        _ resource: [String: Any],
        configuration: SubscriptionOfferConfiguration
    ) -> Bool {
        guard let attributes = resource["attributes"] as? [String: Any],
              attributes["active"] as? Bool != false,
              attributes["duration"] as? String == configuration.duration.rawValue,
              attributes["offerMode"] as? String == "FREE_TRIAL",
              attributes["numberOfPeriods"] as? Int == 1,
              attributes["offerEligibility"] as? String == (configuration.stackWithIntroductoryOffer
                ? "STACK_WITH_INTRO_OFFERS"
                : "REPLACE_INTRO_OFFERS") else { return false }
        let existingEligibility = Set(attributes["customerEligibilities"] as? [String] ?? [])
        let expectedEligibility = Set(configuration.customerEligibilities.map(\.rawValue))
        guard existingEligibility == expectedEligibility else { return false }
        if let autoRenewEnabled = attributes["autoRenewEnabled"] as? Bool,
           autoRenewEnabled != configuration.autoRenewEnabled {
            return false
        }
        return true
    }

    private static func dayString(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private static func pricesEqual(_ rawValue: Any?, _ expected: String) -> Bool {
        let rawString: String?
        if let value = rawValue as? String {
            rawString = value
        } else if let value = rawValue as? NSNumber {
            rawString = value.stringValue
        } else {
            rawString = nil
        }
        guard let rawString,
              let lhs = Decimal(string: rawString, locale: Locale(identifier: "en_US_POSIX")),
              let rhs = Decimal(string: expected, locale: Locale(identifier: "en_US_POSIX")) else {
            return false
        }
        return lhs == rhs
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
