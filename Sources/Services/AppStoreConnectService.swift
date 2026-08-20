import CryptoKit
import Foundation

enum AppStoreScreenshotPlatform: String, CaseIterable, Equatable, Hashable, Sendable, Identifiable {
    case iPhone
    case iPad
    case appleWatch
    case appleTV
    case appleVisionPro

    var id: String { rawValue }

    var title: String {
        switch self {
        case .iPhone: L10n.text("iPhone")
        case .iPad: L10n.text("iPad")
        case .appleWatch: L10n.text("Apple Watch")
        case .appleTV: L10n.text("Apple TV")
        case .appleVisionPro: L10n.text("Apple Vision Pro")
        }
    }

    var symbolName: String {
        switch self {
        case .iPhone: "iphone"
        case .iPad: "ipad"
        case .appleWatch: "applewatch"
        case .appleTV: "appletv"
        case .appleVisionPro: "visionpro"
        }
    }

    init?(displayType: String) {
        if displayType.hasPrefix("APP_IPHONE") {
            self = .iPhone
        } else if displayType.hasPrefix("APP_IPAD") {
            self = .iPad
        } else if displayType.hasPrefix("APP_WATCH") {
            self = .appleWatch
        } else if displayType == "APP_APPLE_TV" {
            self = .appleTV
        } else if displayType == "APP_APPLE_VISION_PRO" {
            self = .appleVisionPro
        } else {
            return nil
        }
    }
}

struct AppStoreScreenshotAsset: Equatable, Sendable {
    let url: URL
    let displayType: String
    let platform: AppStoreScreenshotPlatform
    let locale: String?
    let deviceName: String?
    let automaticallyCaptured: Bool

    init(
        url: URL,
        displayType: String,
        platform: AppStoreScreenshotPlatform? = nil,
        locale: String? = nil,
        deviceName: String? = nil,
        automaticallyCaptured: Bool = false
    ) {
        self.url = url
        self.displayType = displayType
        self.platform = platform ?? AppStoreScreenshotPlatform(displayType: displayType) ?? .iPhone
        self.locale = locale
        self.deviceName = deviceName
        self.automaticallyCaptured = automaticallyCaptured
    }
}

struct AppStoreScreenshotCaptureDevice: Equatable, Sendable, Identifiable {
    enum State: Equatable, Sendable {
        case provided
        case ready
        case capturing
        case captured
        case unavailable
        case failed(String)
    }

    var id: String { platform.rawValue }

    let platform: AppStoreScreenshotPlatform
    let name: String?
    let runtime: String?
    let state: State
}

struct AppStoreScreenshotPreview: Equatable, Sendable {
    let devices: [AppStoreScreenshotCaptureDevice]
    let screenshots: [AppStoreScreenshotAsset]
}

struct AppStoreConnectPublication: Sendable {
    let appID: String
    let versionID: String?
    let localizationID: String?
    let localizationIDsByLocale: [String: String]
    let isVersionOnlyUpdate: Bool
    let preservedLockedAppInformation: Bool
    let deferredStorefrontSetup: Bool
}

struct AppStoreLocalizedNamePreservation: Equatable, Sendable {
    let locale: String
    let requestedName: String
    let existingName: String
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
    case offerCodeTerritoriesUnavailable(String)
    case offerCodesRequireReadyApp
    case offerCodesRequireApprovedSubscription(String, String?)
    case activeReviewSubmissionNotFound(String)
    case activeReviewCancellationTimedOut(String)
    case reviewSubmissionNotAllowed
    case internalTesterIsNotTeamMember(String)

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
        case .offerCodeTerritoriesUnavailable(let productID):
            return L10n.format("Subscription %@ has no available territories for a redeem-code offer.", productID)
        case .offerCodesRequireReadyApp:
            return L10n.text("Redeem codes become available after Apple approves and releases the app.")
        case .offerCodesRequireApprovedSubscription(let productID, let state):
            return L10n.format(
                "Subscription %@ must be Approved before redeem codes can be created. Current status: %@.",
                productID,
                state ?? L10n.text("Unknown")
            )
        case .activeReviewSubmissionNotFound(let version):
            return L10n.format("Version %@ is in review, but its active review submission could not be found.", version)
        case .activeReviewCancellationTimedOut(let version):
            return L10n.format("Apple accepted the cancellation for version %@, but it is still processing. Try Update again shortly.", version)
        case .reviewSubmissionNotAllowed:
            return L10n.text("The TestFlight action is not permitted to submit anything for App Review.")
        case .internalTesterIsNotTeamMember(let email):
            return L10n.format("%@ must be added to the App Store Connect team before Development Management can add that person as an internal tester.", email)
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

    func fetchConfigurationSnapshot(
        bundleIdentifier: String,
        preferredVersion: String?,
        preferredBuildNumber: String? = nil
    ) async throws -> AppStoreConnectConfigurationSnapshot {
        let apps = try await pagedData(
            path: "/v1/apps",
            query: ["filter[bundleId]": bundleIdentifier, "limit": "1"]
        )
        guard let app = apps.first,
              let appID = app["id"] as? String else {
            throw AppStoreConnectError.applicationNotFound(bundleIdentifier)
        }
        let appAttributes = Self.attributes(app)

        var primaryCategory: String?
        var secondaryCategory: String?
        var ageRating: [String: AppStoreManifestValue]?
        var appLocalizations: [AppStoreConnectAppLocalizationSnapshot] = []
        let infos = try await pagedData(
            path: "/v1/apps/\(appID)/appInfos",
            query: ["limit": "200"]
        )
        if let info = Self.currentAppInfo(infos), let infoID = info["id"] as? String {
            primaryCategory = try await optionalResourceID(
                path: "/v1/appInfos/\(infoID)/primaryCategory"
            )
            secondaryCategory = try await optionalResourceID(
                path: "/v1/appInfos/\(infoID)/secondaryCategory"
            )
            do {
                let response = try await request(
                    method: "GET",
                    path: "/v1/appInfos/\(infoID)/ageRatingDeclaration"
                )
                if let resource = response["data"] as? [String: Any] {
                    ageRating = Self.attributes(resource).compactMapValues(Self.manifestValue)
                }
            } catch AppStoreConnectError.requestFailed(let status, _) where status == 404 {
                ageRating = nil
            }
            appLocalizations = try await pagedData(
                path: "/v1/appInfos/\(infoID)/appInfoLocalizations",
                query: ["limit": "200"]
            ).compactMap(Self.appLocalizationSnapshot)
                .sorted { $0.locale < $1.locale }
        }

        var licenseAgreementText: String?
        var licenseTerritoryIDs: [String] = []
        do {
            let agreement = try await request(
                method: "GET",
                path: "/v1/apps/\(appID)/endUserLicenseAgreement"
            )
            if let resource = agreement["data"] as? [String: Any],
               let agreementID = resource["id"] as? String {
                licenseAgreementText = Self.attributes(resource)["agreementText"] as? String
                licenseTerritoryIDs = try await pagedData(
                    path: "/v1/endUserLicenseAgreements/\(agreementID)/territories",
                    query: ["limit": "200"]
                ).compactMap { $0["id"] as? String }.sorted()
            }
        } catch AppStoreConnectError.requestFailed(let status, _) where status == 404 {
            licenseAgreementText = nil
        }

        let versions = try await pagedData(
            path: "/v1/apps/\(appID)/appStoreVersions",
            query: ["filter[platform]": "IOS", "limit": "200"]
        )
        let selectedVersion = Self.selectedAppStoreVersion(
            versions,
            preferredVersion: preferredVersion
        )
        let testFlightBuild: AppStoreConnectBuildReference?
        if let preferredVersion = preferredVersion?.nilIfEmpty,
           let preferredBuildNumber = preferredBuildNumber?.nilIfEmpty {
            testFlightBuild = try await build(
                appID: appID,
                marketingVersion: preferredVersion,
                buildNumber: preferredBuildNumber
            )
        } else if let preferredVersion = preferredVersion?.nilIfEmpty {
            testFlightBuild = try await latestBuild(appID: appID, marketingVersion: preferredVersion)
        } else {
            testFlightBuild = nil
        }
        let activeReviewVersion = Self.activeReviewVersion(in: versions)
        let latestApprovedVersion = Self.latestApprovedVersion(
            in: versions,
            excluding: preferredVersion?.nilIfEmpty ?? ""
        )
        let hasReadyForDistributionVersion = Self.hasReadyForDistributionVersion(in: versions)
        let version: AppStoreConnectVersionSnapshot? = if let selectedVersion {
            try await versionSnapshot(selectedVersion)
        } else {
            nil
        }

        var groups: [AppStoreConnectSubscriptionGroupSnapshot] = []
        for group in try await pagedData(
            path: "/v1/apps/\(appID)/subscriptionGroups",
            query: ["limit": "200"]
        ) {
            try Task.checkCancellation()
            if let snapshot = try await subscriptionGroupSnapshot(group) {
                groups.append(snapshot)
            }
        }
        let territoryIDs = try await pagedData(
            path: "/v1/territories",
            query: ["limit": "200"]
        ).compactMap { $0["id"] as? String }
            .sorted()

        return AppStoreConnectConfigurationSnapshot(
            appName: appAttributes["name"] as? String ?? bundleIdentifier,
            bundleIdentifier: appAttributes["bundleId"] as? String ?? bundleIdentifier,
            sku: appAttributes["sku"] as? String,
            primaryLocale: appAttributes["primaryLocale"] as? String,
            contentRightsDeclaration: appAttributes["contentRightsDeclaration"] as? String,
            primaryCategory: primaryCategory,
            secondaryCategory: secondaryCategory,
            ageRating: ageRating,
            licenseAgreementText: licenseAgreementText,
            licenseTerritoryIDs: licenseTerritoryIDs,
            territoryIDs: territoryIDs,
            appLocalizations: appLocalizations,
            version: version,
            testFlightBuild: testFlightBuild,
            activeReviewVersion: activeReviewVersion,
            latestApprovedVersion: latestApprovedVersion,
            hasReadyForDistributionVersion: hasReadyForDistributionVersion,
            subscriptionGroups: groups.sorted {
                $0.referenceName.localizedCaseInsensitiveCompare($1.referenceName) == .orderedAscending
            },
            loadedAt: Date()
        )
    }

    static func selectedAppStoreVersion(
        _ versions: [[String: Any]],
        preferredVersion: String?
    ) -> [String: Any]? {
        let newest: ([[String: Any]]) -> [String: Any]? = { candidates in
            candidates.max {
                let left = Self.attributes($0)["createdDate"] as? String ?? ""
                let right = Self.attributes($1)["createdDate"] as? String ?? ""
                return left < right
            }
        }
        if let preferredVersion = preferredVersion?.nilIfEmpty,
           let exact = newest(versions.filter {
               Self.attributes($0)["versionString"] as? String == preferredVersion
           }) {
            return exact
        }
        let activeStates: Set<String> = [
            "PREPARE_FOR_SUBMISSION",
            "WAITING_FOR_REVIEW",
            "IN_REVIEW",
            "PENDING_APPLE_RELEASE",
            "PENDING_DEVELOPER_RELEASE",
            "PROCESSING_FOR_APP_STORE"
        ]
        let active = versions.filter {
            guard let state = Self.attributes($0)["appStoreState"] as? String else { return false }
            return activeStates.contains(state)
        }
        return newest(active) ?? newest(versions)
    }

    static func activeReviewVersion(
        in versions: [[String: Any]]
    ) -> AppStoreConnectVersionReferenceSnapshot? {
        versions.compactMap { resource -> AppStoreConnectVersionReferenceSnapshot? in
            guard let id = resource["id"] as? String else { return nil }
            let attributes = Self.attributes(resource)
            guard let state = attributes["appStoreState"] as? String,
                  AppStoreVersionLifecycle.isCancellableReviewState(state) else { return nil }
            return AppStoreConnectVersionReferenceSnapshot(
                id: id,
                versionString: attributes["versionString"] as? String ?? L10n.text("Unknown"),
                state: state
            )
        }
        .max { lhs, rhs in
            AppStoreVersionComparison.compare(lhs.versionString, rhs.versionString) == .orderedAscending
        }
    }

    static func hasReadyForDistributionVersion(in versions: [[String: Any]]) -> Bool {
        versions.contains { resource in
            guard let state = Self.attributes(resource)["appStoreState"] as? String else {
                return false
            }
            return AppStoreVersionLifecycle.isReadyForDistributionState(state)
        }
    }

    static func latestApprovedVersion(
        in versions: [[String: Any]],
        excluding version: String
    ) -> AppStoreConnectVersionReferenceSnapshot? {
        let approvedStates: Set<String> = [
            "READY_FOR_DISTRIBUTION",
            "READY_FOR_SALE",
            "PREORDER_READY_FOR_SALE",
            "REPLACED_WITH_NEW_VERSION",
            "DEVELOPER_REMOVED_FROM_SALE",
            "REMOVED_FROM_SALE"
        ]
        return versions.compactMap { resource -> AppStoreConnectVersionReferenceSnapshot? in
            guard let id = resource["id"] as? String else { return nil }
            let attributes = Self.attributes(resource)
            guard let state = attributes["appStoreState"] as? String,
                  approvedStates.contains(state),
                  let versionString = attributes["versionString"] as? String,
                  versionString != version else { return nil }
            return AppStoreConnectVersionReferenceSnapshot(
                id: id,
                versionString: versionString,
                state: state
            )
        }
        .max { lhs, rhs in
            AppStoreVersionComparison.compare(lhs.versionString, rhs.versionString) == .orderedAscending
        }
    }

    static func reusableDraftVersion(
        in versions: [[String: Any]]
    ) -> AppStoreConnectVersionReferenceSnapshot? {
        versions.compactMap { resource -> AppStoreConnectVersionReferenceSnapshot? in
            guard let id = resource["id"] as? String else { return nil }
            let attributes = Self.attributes(resource)
            guard let state = attributes["appStoreState"] as? String,
                  AppStoreVersionLifecycle.isReusableDraftState(state) else { return nil }
            return AppStoreConnectVersionReferenceSnapshot(
                id: id,
                versionString: attributes["versionString"] as? String ?? L10n.text("Unknown"),
                state: state
            )
        }
        .max { lhs, rhs in
            AppStoreVersionComparison.compare(lhs.versionString, rhs.versionString) == .orderedAscending
        }
    }

    private func versionSnapshot(
        _ resource: [String: Any]
    ) async throws -> AppStoreConnectVersionSnapshot? {
        guard let versionID = resource["id"] as? String else { return nil }
        let attributes = Self.attributes(resource)
        let localizations = try await pagedData(
            path: "/v1/appStoreVersions/\(versionID)/appStoreVersionLocalizations",
            query: ["limit": "200"]
        )
        var localizationSnapshots: [AppStoreConnectVersionLocalizationSnapshot] = []
        for localization in localizations {
            guard let localizationID = localization["id"] as? String else { continue }
            let values = Self.attributes(localization)
            let sets = try await pagedData(
                path: "/v1/appStoreVersionLocalizations/\(localizationID)/appScreenshotSets",
                query: [
                    "fields[appScreenshotSets]": "screenshotDisplayType,appScreenshots",
                    "include": "appScreenshots",
                    "limit": "50"
                ]
            )
            var screenshotCounts: [String: Int] = [:]
            for set in sets {
                let displayType = Self.attributes(set)["screenshotDisplayType"] as? String ?? L10n.text("Unknown")
                let relationships = set["relationships"] as? [String: Any]
                let screenshots = relationships?["appScreenshots"] as? [String: Any]
                let data = screenshots?["data"] as? [[String: Any]] ?? []
                screenshotCounts[displayType, default: 0] += data.count
            }
            localizationSnapshots.append(
                AppStoreConnectVersionLocalizationSnapshot(
                    locale: values["locale"] as? String ?? L10n.text("Unknown"),
                    description: values["description"] as? String,
                    keywords: values["keywords"] as? String,
                    promotionalText: values["promotionalText"] as? String,
                    whatsNew: values["whatsNew"] as? String,
                    supportURL: values["supportUrl"] as? String,
                    marketingURL: values["marketingUrl"] as? String,
                    screenshotCounts: screenshotCounts
                )
            )
        }

        var review: AppStoreConnectReviewSnapshot?
        do {
            let response = try await request(
                method: "GET",
                path: "/v1/appStoreVersions/\(versionID)/appStoreReviewDetail"
            )
            if let resource = response["data"] as? [String: Any] {
                let values = Self.attributes(resource)
                review = AppStoreConnectReviewSnapshot(
                    contactFirstName: values["contactFirstName"] as? String,
                    contactLastName: values["contactLastName"] as? String,
                    contactPhone: values["contactPhone"] as? String,
                    contactEmail: values["contactEmail"] as? String,
                    notes: values["notes"] as? String,
                    demoAccountRequired: values["demoAccountRequired"] as? Bool ?? false
                )
            }
        } catch AppStoreConnectError.requestFailed(let status, _) where status == 404 {
            review = nil
        }

        var buildNumber: String?
        do {
            let response = try await request(
                method: "GET",
                path: "/v1/appStoreVersions/\(versionID)/build"
            )
            if let build = response["data"] as? [String: Any] {
                buildNumber = Self.attributes(build)["version"] as? String
            }
        } catch AppStoreConnectError.requestFailed(let status, _) where status == 404 {
            buildNumber = nil
        }

        return AppStoreConnectVersionSnapshot(
            versionString: attributes["versionString"] as? String ?? L10n.text("Unknown"),
            state: attributes["appStoreState"] as? String ?? L10n.text("Unknown"),
            buildNumber: buildNumber,
            releaseType: attributes["releaseType"] as? String,
            copyright: attributes["copyright"] as? String,
            earliestReleaseDate: attributes["earliestReleaseDate"] as? String,
            localizations: localizationSnapshots.sorted { $0.locale < $1.locale },
            review: review
        )
    }

    private func subscriptionGroupSnapshot(
        _ resource: [String: Any]
    ) async throws -> AppStoreConnectSubscriptionGroupSnapshot? {
        guard let groupID = resource["id"] as? String else { return nil }
        let attributes = Self.attributes(resource)
        let versions = try await pagedData(
            path: "/v1/subscriptionGroups/\(groupID)/versions",
            query: ["limit": "200"]
        )
        let selectedVersion = Self.latestVersionedResource(versions)
        var localizations: [AppStoreSubscriptionLocalization] = []
        if let versionID = selectedVersion?["id"] as? String {
            localizations = try await pagedData(
                path: "/v1/subscriptionGroupVersions/\(versionID)/localizations",
                query: ["limit": "200"]
            ).compactMap(Self.subscriptionLocalization)
                .sorted { $0.locale < $1.locale }
        }

        var subscriptions: [AppStoreConnectSubscriptionSnapshot] = []
        for subscription in try await pagedData(
            path: "/v1/subscriptionGroups/\(groupID)/subscriptions",
            query: ["limit": "200"]
        ) {
            if let snapshot = try await subscriptionSnapshot(subscription) {
                subscriptions.append(snapshot)
            }
        }
        return AppStoreConnectSubscriptionGroupSnapshot(
            id: groupID,
            referenceName: attributes["referenceName"] as? String ?? L10n.text("Unknown"),
            state: selectedVersion.flatMap { Self.attributes($0)["state"] as? String },
            localizations: localizations,
            subscriptions: subscriptions.sorted { $0.productID < $1.productID }
        )
    }

    private func subscriptionSnapshot(
        _ resource: [String: Any]
    ) async throws -> AppStoreConnectSubscriptionSnapshot? {
        guard let subscriptionID = resource["id"] as? String else { return nil }
        let attributes = Self.attributes(resource)
        let versions = try await pagedData(
            path: "/v1/subscriptions/\(subscriptionID)/versions",
            query: ["limit": "200"]
        )
        let selectedVersion = Self.latestVersionedResource(versions)
        var localizations: [AppStoreSubscriptionLocalization] = []
        if let versionID = selectedVersion?["id"] as? String {
            localizations = try await pagedData(
                path: "/v1/subscriptionVersions/\(versionID)/localizations",
                query: ["limit": "200"]
            ).compactMap(Self.subscriptionLocalization)
                .sorted { $0.locale < $1.locale }
        }

        var availableInNewTerritories: Bool?
        var territoryIDs: [String] = []
        do {
            let availability = try await request(
                method: "GET",
                path: "/v1/subscriptions/\(subscriptionID)/subscriptionAvailability"
            )
            if let availabilityResource = availability["data"] as? [String: Any],
               let availabilityID = availabilityResource["id"] as? String {
                availableInNewTerritories = Self.attributes(availabilityResource)["availableInNewTerritories"] as? Bool
                territoryIDs = try await pagedData(
                    path: "/v1/subscriptionAvailabilities/\(availabilityID)/availableTerritories",
                    query: ["limit": "200"]
                ).compactMap { $0["id"] as? String }.sorted()
            }
        } catch AppStoreConnectError.requestFailed(let status, _) where status == 404 {
            territoryIDs = []
        }

        let prices = try await subscriptionPrices(subscriptionID: subscriptionID)
        let offers = try await pagedData(
            path: "/v1/subscriptions/\(subscriptionID)/offerCodes",
            query: ["limit": "200"]
        ).compactMap(Self.offerSnapshot)
            .sorted {
                if $0.active != $1.active { return $0.active && !$1.active }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }

        return AppStoreConnectSubscriptionSnapshot(
            id: subscriptionID,
            referenceName: attributes["name"] as? String ?? L10n.text("Unknown"),
            productID: attributes["productId"] as? String ?? L10n.text("Unknown"),
            state: (attributes["state"] as? String)
                ?? selectedVersion.flatMap { Self.attributes($0)["state"] as? String },
            period: attributes["subscriptionPeriod"] as? String,
            familySharable: attributes["familySharable"] as? Bool ?? false,
            groupLevel: attributes["groupLevel"] as? Int,
            reviewNote: attributes["reviewNote"] as? String,
            localizations: localizations,
            availableTerritoryIDs: territoryIDs,
            availableInNewTerritories: availableInNewTerritories,
            prices: prices,
            offers: offers
        )
    }

    private func subscriptionPrices(
        subscriptionID: String
    ) async throws -> [AppStoreConnectSubscriptionPriceSnapshot] {
        let resources = try await pagedResources(
            path: "/v1/subscriptions/\(subscriptionID)/prices",
            query: [
                "include": "subscriptionPricePoint,territory",
                "limit": "200"
            ]
        )
        let included = Dictionary(
            resources.included.compactMap { item -> (String, [String: Any])? in
                guard let type = item["type"] as? String, let id = item["id"] as? String else { return nil }
                return ("\(type):\(id)", item)
            },
            uniquingKeysWith: { first, _ in first }
        )
        return resources.data.compactMap { price in
            let attributes = Self.attributes(price)
            let relationships = price["relationships"] as? [String: Any]
            let pointID = Self.relationshipID(relationships?["subscriptionPricePoint"])
            let point = pointID.flatMap { included["subscriptionPricePoints:\($0)"] }
            let pointRelationships = point?["relationships"] as? [String: Any]
            let territoryID = Self.relationshipID(relationships?["territory"])
                ?? Self.relationshipID(pointRelationships?["territory"])
                ?? L10n.text("Unknown")
            let territory = included["territories:\(territoryID)"]
            guard let customerPrice = Self.stringValue(Self.attributes(point ?? [:])["customerPrice"]) else {
                return nil
            }
            return AppStoreConnectSubscriptionPriceSnapshot(
                territory: territoryID,
                price: customerPrice,
                currency: Self.attributes(territory ?? [:])["currency"] as? String,
                startDate: attributes["startDate"] as? String,
                endDate: attributes["endDate"] as? String,
                preserved: (attributes["preserved"] as? Bool)
                    ?? (attributes["preserveCurrentPrice"] as? Bool)
                    ?? false
            )
        }.sorted { $0.territory < $1.territory }
    }

    private func optionalResourceID(path: String) async throws -> String? {
        do {
            let response = try await request(method: "GET", path: path)
            return (response["data"] as? [String: Any])?["id"] as? String
        } catch AppStoreConnectError.requestFailed(let status, _) where status == 404 {
            return nil
        }
    }

    static func currentAppInfo(_ infos: [[String: Any]]) -> [String: Any]? {
        let currentInfos = infos.filter {
            appInfoState($0) != "REPLACED_WITH_NEW_INFO"
        }
        return currentInfos.first {
            appInfoState($0) == "PREPARE_FOR_SUBMISSION"
        } ?? currentInfos.first {
            guard let state = appInfoState($0) else { return false }
            return AppStoreVersionLifecycle.isReusableDraftState(state)
        } ?? currentInfos.first
            ?? infos.first
    }

    private static func appInfoState(_ info: [String: Any]) -> String? {
        attributes(info)["state"] as? String
            ?? attributes(info)["appStoreState"] as? String
    }

    private static func latestVersionedResource(_ resources: [[String: Any]]) -> [String: Any]? {
        resources.max {
            let left = attributes($0)["version"] as? Int ?? 0
            let right = attributes($1)["version"] as? Int ?? 0
            return left < right
        }
    }

    private static func appLocalizationSnapshot(
        _ resource: [String: Any]
    ) -> AppStoreConnectAppLocalizationSnapshot? {
        let attributes = attributes(resource)
        guard let locale = attributes["locale"] as? String else { return nil }
        return AppStoreConnectAppLocalizationSnapshot(
            locale: locale,
            name: attributes["name"] as? String,
            subtitle: attributes["subtitle"] as? String,
            privacyPolicyURL: attributes["privacyPolicyUrl"] as? String,
            privacyChoicesURL: attributes["privacyChoicesUrl"] as? String
        )
    }

    private static func subscriptionLocalization(
        _ resource: [String: Any]
    ) -> AppStoreSubscriptionLocalization? {
        let attributes = attributes(resource)
        guard let locale = attributes["locale"] as? String,
              let name = attributes["name"] as? String else { return nil }
        return AppStoreSubscriptionLocalization(
            locale: locale,
            name: name,
            description: attributes["description"] as? String
        ).normalizingLocale()
    }

    private static func offerSnapshot(
        _ resource: [String: Any]
    ) -> AppStoreConnectOfferSnapshot? {
        guard let id = resource["id"] as? String else { return nil }
        let attributes = attributes(resource)
        return AppStoreConnectOfferSnapshot(
            id: id,
            name: attributes["name"] as? String ?? L10n.text("Unknown"),
            active: attributes["active"] as? Bool ?? false,
            duration: attributes["duration"] as? String,
            customerEligibilities: attributes["customerEligibilities"] as? [String] ?? [],
            productionCodeCount: attributes["productionCodeCount"] as? Int ?? 0,
            totalNumberOfCodes: attributes["totalNumberOfCodes"] as? Int ?? 0
        )
    }

    private static func attributes(_ resource: [String: Any]) -> [String: Any] {
        resource["attributes"] as? [String: Any] ?? [:]
    }

    private static func relationshipID(_ rawRelationship: Any?) -> String? {
        let relationship = rawRelationship as? [String: Any]
        let data = relationship?["data"] as? [String: Any]
        return data?["id"] as? String
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func manifestValue(_ value: Any) -> AppStoreManifestValue? {
        if let value = value as? Bool { return .bool(value) }
        if let value = value as? Int { return .integer(value) }
        if let value = value as? Double { return .decimal(value) }
        if let value = value as? String { return .string(value) }
        return nil
    }

    func preparePublication(
        bundleIdentifier: String,
        version: String,
        intent: PublishingIntent,
        locale: String,
        metadata: AppStoreMetadata,
        localizedMetadata: [AppStoreLocalizedMetadata],
        copyright: String,
        supportURL: String,
        marketingURL: String?,
        termsURL: String?,
        appName: String?,
        subtitle: String?,
        privacyPolicyURL: String?,
        privacyChoicesURL: String?,
        licenseAgreementText: String?,
        review: AppStoreReviewConfiguration,
        releaseAutomatically: Bool,
        reusableVersionID: String? = nil,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> AppStoreConnectPublication {
        let appID = try await findApplication(bundleIdentifier: bundleIdentifier)
        let isVersionOnlyUpdate = try await hasPublishedVersion(appID: appID, otherThan: version)
        let versionID: String
        do {
            versionID = try await findOrCreateVersion(
                appID: appID,
                version: version,
                copyright: copyright,
                releaseAutomatically: releaseAutomatically,
                reusableVersionID: reusableVersionID
            )
        } catch AppStoreConnectError.requestFailed(let status, let message)
            where intent == .testFlight && status == 409 {
            let versions = try await pagedData(
                path: "/v1/apps/\(appID)/appStoreVersions",
                query: ["filter[platform]": "IOS", "limit": "200"]
            )
            guard Self.hasVersionBlockingNewStorefront(in: versions) else {
                throw AppStoreConnectError.requestFailed(status, message)
            }
            onOutput(L10n.text("App Store Connect cannot create or edit the target App Store version while another version is in review. Storefront listing, screenshots, review details, and build attachment are deferred; continuing with TestFlight setup.\n"))
            return AppStoreConnectPublication(
                appID: appID,
                versionID: nil,
                localizationID: nil,
                localizationIDsByLocale: [:],
                isVersionOnlyUpdate: isVersionOnlyUpdate,
                preservedLockedAppInformation: true,
                deferredStorefrontSetup: true
            )
        }
        let fallbackListing = AppStoreLocalizedMetadata(
            locale: locale,
            appName: appName ?? "",
            subtitle: subtitle ?? metadata.subtitle ?? "",
            description: metadata.description,
            keywords: metadata.keywords,
            promotionalText: metadata.promotionalText,
            whatsNew: metadata.whatsNew
        )
        let listings = localizedMetadata.isEmpty ? [fallbackListing] : localizedMetadata
        let orderedListings = listings.sorted { lhs, rhs in
            let lhsIsPrimary = lhs.locale.caseInsensitiveCompare(locale) == .orderedSame
            let rhsIsPrimary = rhs.locale.caseInsensitiveCompare(locale) == .orderedSame
            return lhsIsPrimary && !rhsIsPrimary
        }
        var primaryLocalizationID: String?
        var localizationIDsByLocale: [String: String] = [:]
        var preservedLockedAppInformation = false
        for listing in orderedListings {
            let localizationID = try await findOrCreateLocalization(
                versionID: versionID,
                locale: listing.locale
            )
            if primaryLocalizationID == nil
                || listing.locale.caseInsensitiveCompare(locale) == .orderedSame {
                primaryLocalizationID = localizationID
            }
            localizationIDsByLocale[listing.locale.lowercased()] = localizationID
            let localizedStoreMetadata = listing.metadata(
                primaryCategory: metadata.primaryCategory,
                secondaryCategory: metadata.secondaryCategory
            )
            do {
                try await updateLocalization(
                    localizationID,
                    metadata: localizedStoreMetadata,
                    supportURL: supportURL,
                    marketingURL: marketingURL,
                    privacyPolicyURL: privacyPolicyURL,
                    termsURL: termsURL,
                    locale: listing.locale,
                    includesReleaseNotes: true
                )
            } catch AppStoreConnectError.requestFailed(let status, _) where status == 409 || status == 422 {
                // App Store Connect rejects release notes for an application's first version.
                try await updateLocalization(
                    localizationID,
                    metadata: localizedStoreMetadata,
                    supportURL: supportURL,
                    marketingURL: marketingURL,
                    privacyPolicyURL: privacyPolicyURL,
                    termsURL: termsURL,
                    locale: listing.locale,
                    includesReleaseNotes: false
                )
            }
            if !preservedLockedAppInformation {
                do {
                    if let preservation = try await configureLocalizedAppInformation(
                        appID: appID,
                        locale: listing.locale,
                        appName: listing.appName.nilIfEmpty ?? appName,
                        subtitle: listing.subtitle.nilIfEmpty ?? subtitle ?? metadata.subtitle,
                        privacyPolicyURL: privacyPolicyURL,
                        privacyChoicesURL: privacyChoicesURL
                    ) {
                        onOutput(L10n.format(
                            "The requested App Store name %@ is unavailable for %@. Keeping the existing name %@ and continuing.\n",
                            preservation.requestedName,
                            preservation.locale,
                            preservation.existingName
                        ))
                    }
                } catch AppStoreConnectError.requestFailed(let status, _)
                    where intent.preservesLockedAppInformation(forHTTPStatus: status) {
                    preservedLockedAppInformation = true
                    onOutput(L10n.text("App Store Connect has locked app-level information in its current state; keeping the existing name, subtitle, privacy URLs, and license agreement for this TestFlight upload.\n"))
                }
            }
        }
        guard let localizationID = primaryLocalizationID else {
            throw AppStoreConnectError.missingIdentifier("App Store version localization")
        }
        if let licenseAgreementText = licenseAgreementText?.nilIfEmpty,
           !preservedLockedAppInformation {
            do {
                try await configureLicenseAgreement(appID: appID, agreementText: licenseAgreementText)
            } catch AppStoreConnectError.requestFailed(let status, _)
                where intent.preservesLockedAppInformation(forHTTPStatus: status) {
                preservedLockedAppInformation = true
                onOutput(L10n.text("App Store Connect has locked app-level information in its current state; keeping the existing name, subtitle, privacy URLs, and license agreement for this TestFlight upload.\n"))
            }
        }
        try await configureReviewDetails(versionID: versionID, review: review)
        return AppStoreConnectPublication(
            appID: appID,
            versionID: versionID,
            localizationID: localizationID,
            localizationIDsByLocale: localizationIDsByLocale,
            isVersionOnlyUpdate: isVersionOnlyUpdate,
            preservedLockedAppInformation: preservedLockedAppInformation,
            deferredStorefrontSetup: false
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
            let info = Self.currentAppInfo(infos)
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
                        territoryPrices: definition.territoryPrices ?? [:],
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
        let versions = try await pagedData(
            path: "/v1/apps/\(appID)/appStoreVersions",
            query: ["filter[platform]": "IOS", "limit": "200"]
        )
        guard Self.hasReadyForDistributionVersion(in: versions) else {
            throw AppStoreConnectError.offerCodesRequireReadyApp
        }
        let subscriptionID = try await findSubscription(
            appID: appID,
            productID: generation.productID
        )
        let subscriptionResponse = try await request(
            method: "GET",
            path: "/v1/subscriptions/\(subscriptionID)"
        )
        let subscriptionResource = subscriptionResponse["data"] as? [String: Any]
        let subscriptionState = subscriptionResource.map(Self.attributes)?["state"] as? String
        guard subscriptionState == "APPROVED" else {
            throw AppStoreConnectError.offerCodesRequireApprovedSubscription(
                generation.productID,
                subscriptionState
            )
        }
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
            let territoryIDs = try await subscriptionAvailableTerritoryIDs(
                subscriptionID: subscriptionID
            )
            guard !territoryIDs.isEmpty else {
                throw AppStoreConnectError.offerCodeTerritoriesUnavailable(generation.productID)
            }
            let created = try await request(
                method: "POST",
                path: "/v1/subscriptionOfferCodes",
                body: Self.subscriptionOfferCreateBody(
                    generation.offer,
                    subscriptionID: subscriptionID,
                    territoryIDs: territoryIDs
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
                oneTimeCodeCSV: csv,
                redemptionURL: nil
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
                oneTimeCodeCSV: nil,
                redemptionURL: SubscriptionOfferCodeRedemption.url(
                    appID: appID,
                    code: customCode
                )
            )
        }
    }

    func fetchSubscriptionOfferCodeDetails(
        bundleIdentifier: String,
        offerID: String
    ) async throws -> AppStoreConnectOfferCodeDetailSnapshot {
        let appID = try await findApplication(bundleIdentifier: bundleIdentifier)
        let oneTimeResources = try await pagedData(
            path: "/v1/subscriptionOfferCodes/\(offerID)/oneTimeUseCodes",
            query: ["limit": "200"]
        )
        var oneTimeBatches: [AppStoreConnectOneTimeCodeBatchSnapshot] = []
        for resource in oneTimeResources {
            try Task.checkCancellation()
            guard let batchID = resource["id"] as? String else { continue }
            let attributes = Self.attributes(resource)
            let csv = try await requestCSV(
                path: "/v1/subscriptionOfferCodeOneTimeUseCodes/\(batchID)/values"
            )
            oneTimeBatches.append(AppStoreConnectOneTimeCodeBatchSnapshot(
                id: batchID,
                numberOfCodes: attributes["numberOfCodes"] as? Int ?? 0,
                createdDate: attributes["createdDate"] as? String,
                expirationDate: attributes["expirationDate"] as? String,
                active: attributes["active"] as? Bool ?? false,
                environment: attributes["environment"] as? String,
                codes: csv.map { SubscriptionOfferCodeCSV.values(from: $0) } ?? []
            ))
        }

        let customBatches = try await pagedData(
            path: "/v1/subscriptionOfferCodes/\(offerID)/customCodes",
            query: ["limit": "200"]
        ).compactMap { resource -> AppStoreConnectCustomCodeBatchSnapshot? in
            guard let batchID = resource["id"] as? String else { return nil }
            let attributes = Self.attributes(resource)
            let code = attributes["customCode"] as? String ?? ""
            return AppStoreConnectCustomCodeBatchSnapshot(
                id: batchID,
                customCode: code,
                numberOfCodes: attributes["numberOfCodes"] as? Int ?? 0,
                createdDate: attributes["createdDate"] as? String,
                expirationDate: attributes["expirationDate"] as? String,
                active: attributes["active"] as? Bool ?? false,
                redemptionURL: SubscriptionOfferCodeRedemption.url(appID: appID, code: code)
            )
        }

        return AppStoreConnectOfferCodeDetailSnapshot(
            offerID: offerID,
            appID: appID,
            oneTimeBatches: SubscriptionOfferCodeAvailabilityOrdering.oneTime(oneTimeBatches),
            customBatches: SubscriptionOfferCodeAvailabilityOrdering.custom(customBatches)
        )
    }

    func uploadScreenshots(
        _ screenshots: [AppStoreScreenshotAsset],
        localizationIDsByLocale: [String: String],
        primaryLocale: String,
        replaceExisting: Bool,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws {
        let primaryLocalizationID = localizationIDsByLocale[primaryLocale.lowercased()]
            ?? localizationIDsByLocale.values.first
        guard let primaryLocalizationID else {
            throw AppStoreConnectError.missingIdentifier("primary App Store localization")
        }
        let grouped = Dictionary(grouping: screenshots) { screenshot in
            "\(screenshot.locale?.lowercased() ?? primaryLocale.lowercased())|\(screenshot.displayType)"
        }
        for group in grouped.sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation()
            let sample = group.value[0]
            let displayType = sample.displayType
            let requestedLocale = sample.locale?.lowercased() ?? primaryLocale.lowercased()
            guard let localizationID = localizationIDsByLocale[requestedLocale] ?? (sample.locale == nil ? primaryLocalizationID : nil) else {
                throw AppStoreConnectError.requestFailed(
                    422,
                    L10n.format("Screenshot locale %@ has no matching App Store localization.", sample.locale ?? requestedLocale)
                )
            }
            let setResponse = try await request(
                method: "GET",
                path: "/v1/appStoreVersionLocalizations/\(localizationID)/appScreenshotSets",
                query: ["filter[screenshotDisplayType]": displayType, "include": "appScreenshots", "limit": "50"]
            )
            let existingScreenshots = (setResponse["included"] as? [[String: Any]])?.filter {
                $0["type"] as? String == "appScreenshots"
            } ?? []
            if !existingScreenshots.isEmpty, !replaceExisting {
                onOutput(L10n.format("Keeping %d existing screenshot(s) for %@.\n", existingScreenshots.count, displayType))
                continue
            }
            if replaceExisting {
                for screenshot in existingScreenshots {
                    guard let screenshotID = screenshot["id"] as? String else { continue }
                    _ = try await request(
                        method: "DELETE",
                        path: "/v1/appScreenshots/\(screenshotID)"
                    )
                }
                if !existingScreenshots.isEmpty {
                    onOutput(L10n.format(
                        "Removed %d existing screenshot(s) for %@ before replacement.\n",
                        existingScreenshots.count,
                        displayType
                    ))
                }
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
        marketingVersion: String,
        buildNumber: String,
        timeout: TimeInterval = 30 * 60,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if let build = try await build(
                appID: appID,
                marketingVersion: marketingVersion,
                buildNumber: buildNumber
            ) {
                if build.processingState == "VALID" { return build.id }
                if build.processingState == "FAILED" || build.processingState == "INVALID" {
                    throw AppStoreConnectError.requestFailed(422, L10n.format("Build processing finished with state %@.", build.processingState))
                }
                onOutput(L10n.format("App Store build processing: %@.\n", build.processingState))
            } else {
                onOutput(L10n.text("Waiting for the uploaded build to appear in App Store Connect…\n"))
            }
            try await Task.sleep(for: .seconds(30))
        }
        throw AppStoreConnectError.buildProcessingTimedOut
    }

    func applicationID(bundleIdentifier: String) async throws -> String {
        try await findApplication(bundleIdentifier: bundleIdentifier)
    }

    func latestApprovedVersion(
        appID: String,
        excluding version: String
    ) async throws -> AppStoreConnectVersionReferenceSnapshot? {
        let versions = try await pagedData(
            path: "/v1/apps/\(appID)/appStoreVersions",
            query: ["filter[platform]": "IOS", "limit": "200"]
        )
        return Self.latestApprovedVersion(in: versions, excluding: version)
    }

    func build(
        appID: String,
        marketingVersion: String,
        buildNumber: String
    ) async throws -> AppStoreConnectBuildReference? {
        let response = try await request(
            method: "GET",
            path: "/v1/builds",
            query: [
                "filter[app]": appID,
                "filter[version]": buildNumber,
                "filter[preReleaseVersion.version]": marketingVersion,
                "filter[preReleaseVersion.platform]": "IOS",
                "fields[builds]": "version,processingState,preReleaseVersion",
                "fields[preReleaseVersions]": "version,platform",
                "include": "preReleaseVersion",
                "sort": "-uploadedDate",
                "limit": "10"
            ]
        )
        return Self.matchingBuild(
            builds: response["data"] as? [[String: Any]] ?? [],
            included: response["included"] as? [[String: Any]] ?? [],
            marketingVersion: marketingVersion,
            buildNumber: buildNumber
        )
    }

    private func latestBuild(
        appID: String,
        marketingVersion: String
    ) async throws -> AppStoreConnectBuildReference? {
        let response = try await request(
            method: "GET",
            path: "/v1/builds",
            query: [
                "filter[app]": appID,
                "filter[preReleaseVersion.version]": marketingVersion,
                "filter[preReleaseVersion.platform]": "IOS",
                "fields[builds]": "version,processingState,preReleaseVersion",
                "fields[preReleaseVersions]": "version,platform",
                "include": "preReleaseVersion",
                "sort": "-uploadedDate",
                "limit": "200"
            ]
        )
        return Self.matchingBuild(
            builds: response["data"] as? [[String: Any]] ?? [],
            included: response["included"] as? [[String: Any]] ?? [],
            marketingVersion: marketingVersion,
            buildNumber: nil
        )
    }

    static func matchingBuild(
        builds: [[String: Any]],
        included: [[String: Any]],
        marketingVersion: String,
        buildNumber: String?
    ) -> AppStoreConnectBuildReference? {
        let preReleaseVersions = Dictionary(
            included.compactMap { resource -> (String, [String: Any])? in
                guard resource["type"] as? String == "preReleaseVersions",
                      let id = resource["id"] as? String else { return nil }
                return (id, resource)
            },
            uniquingKeysWith: { first, _ in first }
        )
        return builds.compactMap { resource -> AppStoreConnectBuildReference? in
            guard let id = resource["id"] as? String else { return nil }
            let attributes = Self.attributes(resource)
            guard let candidateBuildNumber = attributes["version"] as? String,
                  buildNumber == nil || candidateBuildNumber == buildNumber else { return nil }
            let relationships = resource["relationships"] as? [String: Any]
            guard let preReleaseVersionID = Self.relationshipID(relationships?["preReleaseVersion"]),
                  let preReleaseVersion = preReleaseVersions[preReleaseVersionID] else { return nil }
            let versionAttributes = Self.attributes(preReleaseVersion)
            guard versionAttributes["version"] as? String == marketingVersion,
                  versionAttributes["platform"] as? String == "IOS" else { return nil }
            return AppStoreConnectBuildReference(
                id: id,
                version: marketingVersion,
                buildNumber: candidateBuildNumber,
                processingState: attributes["processingState"] as? String ?? "PROCESSING"
            )
        }.first
    }

    static func betaGroupUsesAutomaticBuildAccess(_ group: [String: Any]) -> Bool {
        attributes(group)["hasAccessToAllBuilds"] as? Bool == true
    }

    func attachBuild(_ buildID: String, toVersion versionID: String) async throws {
        _ = try await request(
            method: "PATCH",
            path: "/v1/appStoreVersions/\(versionID)/relationships/build",
            body: ["data": ["type": "builds", "id": buildID]]
        )
    }

    func assignBuildToInternalTestFlight(
        appID: String,
        buildID: String,
        configuration: AppStoreTestFlightConfiguration? = nil,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws {
        let response = try await request(
            method: "GET",
            path: "/v1/apps/\(appID)/betaGroups",
            query: ["limit": "200"]
        )
        var groups = (response["data"] as? [[String: Any]] ?? []).filter {
            Self.attributes($0)["isInternalGroup"] as? Bool == true
        }
        let requestedGroupName = configuration?.groupName?.nilIfEmpty ?? "Internal Testing"
        if !groups.contains(where: {
            (Self.attributes($0)["name"] as? String)?.caseInsensitiveCompare(requestedGroupName) == .orderedSame
        }) {
            let created = try await request(
                method: "POST",
                path: "/v1/betaGroups",
                body: [
                    "data": [
                        "type": "betaGroups",
                        "attributes": [
                            "name": requestedGroupName,
                            "isInternalGroup": true,
                            "hasAccessToAllBuilds": true,
                            "feedbackEnabled": true
                        ],
                        "relationships": [
                            "app": ["data": ["type": "apps", "id": appID]]
                        ]
                    ]
                ]
            )
            guard let group = created["data"] as? [String: Any] else {
                throw AppStoreConnectError.missingIdentifier("internal TestFlight group")
            }
            groups.append(group)
            onOutput(L10n.format("Created the internal TestFlight group %@ with automatic build access.\n", requestedGroupName))
        }

        for group in groups {
            guard let groupID = group["id"] as? String else { continue }
            let name = Self.attributes(group)["name"] as? String ?? "Internal Testing"
            if Self.betaGroupUsesAutomaticBuildAccess(group) {
                onOutput(L10n.format(
                    "Internal TestFlight group %@ receives every build automatically.\n",
                    name
                ))
                continue
            }
            if try await betaGroup(groupID, containsBuild: buildID) {
                onOutput(L10n.format("Build available to the internal TestFlight group %@.\n", name))
                continue
            }
            do {
                _ = try await request(
                    method: "POST",
                    path: "/v1/betaGroups/\(groupID)/relationships/builds",
                    body: ["data": [["type": "builds", "id": buildID]]]
                )
            } catch let error as AppStoreConnectError {
                switch error {
                case .requestFailed(let status, _) where status == 409 || status == 422:
                    // Apple can report either status when an assignment races with
                    // automatic distribution. Only suppress it after confirming access.
                    guard try await betaGroup(groupID, containsBuild: buildID) else {
                        throw error
                    }
                default:
                    throw error
                }
            }
            onOutput(L10n.format("Build available to the internal TestFlight group %@.\n", name))
        }
        if let targetGroup = groups.first(where: {
            (Self.attributes($0)["name"] as? String)?.caseInsensitiveCompare(requestedGroupName) == .orderedSame
        }), let targetGroupID = targetGroup["id"] as? String {
            try await ensureInternalTesters(
                configuration?.internalTesterEmails ?? [],
                groupID: targetGroupID,
                onOutput: onOutput
            )
        }
    }

    func configureTestFlightInformation(
        appID: String,
        listings: [AppStoreLocalizedMetadata],
        configuration: AppStoreTestFlightConfiguration?,
        marketingURL: String?,
        privacyPolicyURL: String?,
        review: AppStoreReviewConfiguration,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws {
        let existing = try await pagedData(
            path: "/v1/apps/\(appID)/betaAppLocalizations",
            query: ["limit": "200"]
        )
        for listing in listings {
            var attributes: [String: Any] = [
                "locale": listing.locale,
                "description": listing.description
            ]
            if let feedbackEmail = configuration?.feedbackEmail?.nilIfEmpty ?? review.contactEmail.nilIfEmpty {
                attributes["feedbackEmail"] = feedbackEmail
            }
            if let marketingURL = marketingURL?.nilIfEmpty {
                attributes["marketingUrl"] = marketingURL
            }
            if let privacyPolicyURL = privacyPolicyURL?.nilIfEmpty {
                attributes["privacyPolicyUrl"] = privacyPolicyURL
            }
            if let resource = existing.first(where: {
                (Self.attributes($0)["locale"] as? String)?.caseInsensitiveCompare(listing.locale) == .orderedSame
            }), let localizationID = resource["id"] as? String {
                attributes.removeValue(forKey: "locale")
                _ = try await request(
                    method: "PATCH",
                    path: "/v1/betaAppLocalizations/\(localizationID)",
                    body: [
                        "data": [
                            "type": "betaAppLocalizations",
                            "id": localizationID,
                            "attributes": attributes
                        ]
                    ]
                )
            } else {
                _ = try await request(
                    method: "POST",
                    path: "/v1/betaAppLocalizations",
                    body: [
                        "data": [
                            "type": "betaAppLocalizations",
                            "attributes": attributes,
                            "relationships": [
                                "app": ["data": ["type": "apps", "id": appID]]
                            ]
                        ]
                    ]
                )
            }
        }

        let betaReviewAttributes: [String: Any] = [
            "contactFirstName": review.contactFirstName,
            "contactLastName": review.contactLastName,
            "contactPhone": review.contactPhone,
            "contactEmail": review.contactEmail,
            "demoAccountRequired": review.demoAccountRequired,
            "demoAccountName": review.demoAccountRequired ? (review.demoAccountName ?? "") : "",
            "demoAccountPassword": review.demoAccountRequired ? (review.demoAccountPassword ?? "") : "",
            "notes": configuration?.reviewNotes?.nilIfEmpty ?? review.notes
        ]
        do {
            let response = try await request(method: "GET", path: "/v1/apps/\(appID)/betaAppReviewDetail")
            let detailID = try Self.identifier(in: response, named: "TestFlight review details")
            _ = try await request(
                method: "PATCH",
                path: "/v1/betaAppReviewDetails/\(detailID)",
                body: [
                    "data": [
                        "type": "betaAppReviewDetails",
                        "id": detailID,
                        "attributes": betaReviewAttributes
                    ]
                ]
            )
        } catch AppStoreConnectError.requestFailed(let status, _) where status == 404 {
            _ = try await request(
                method: "POST",
                path: "/v1/betaAppReviewDetails",
                body: [
                    "data": [
                        "type": "betaAppReviewDetails",
                        "attributes": betaReviewAttributes,
                        "relationships": [
                            "app": ["data": ["type": "apps", "id": appID]]
                        ]
                    ]
                ]
            )
        }
        onOutput(L10n.format("Updated TestFlight information for %d language(s).\n", listings.count))
    }

    private func ensureInternalTesters(
        _ emails: [String],
        groupID: String,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws {
        let normalizedEmails = Array(Set(emails.compactMap { $0.nilIfEmpty?.lowercased() })).sorted()
        guard !normalizedEmails.isEmpty else { return }
        let users = try await pagedData(path: "/v1/users", query: ["limit": "200"])
        for email in normalizedEmails {
            guard let member = users.first(where: {
                let attributes = Self.attributes($0)
                return [attributes["username"] as? String, attributes["email"] as? String]
                    .compactMap { $0?.lowercased() }
                    .contains(email)
            }) else {
                throw AppStoreConnectError.internalTesterIsNotTeamMember(email)
            }
            let memberAttributes = Self.attributes(member)
            let testers = try await pagedData(
                path: "/v1/betaTesters",
                query: ["filter[email]": email, "limit": "20"]
            )
            let testerID: String
            if let tester = testers.first, let existingID = tester["id"] as? String {
                testerID = existingID
            } else {
                let created = try await request(
                    method: "POST",
                    path: "/v1/betaTesters",
                    body: [
                        "data": [
                            "type": "betaTesters",
                            "attributes": [
                                "email": email,
                                "firstName": memberAttributes["firstName"] as? String ?? "",
                                "lastName": memberAttributes["lastName"] as? String ?? ""
                            ],
                            "relationships": [
                                "betaGroups": [
                                    "data": [["type": "betaGroups", "id": groupID]]
                                ]
                            ]
                        ]
                    ]
                )
                testerID = try Self.identifier(in: created, named: "internal TestFlight tester")
            }
            do {
                _ = try await request(
                    method: "POST",
                    path: "/v1/betaGroups/\(groupID)/relationships/betaTesters",
                    body: ["data": [["type": "betaTesters", "id": testerID]]]
                )
            } catch AppStoreConnectError.requestFailed(let status, _) where status == 409 || status == 422 {
                // The tester is already assigned to the group.
            }
            onOutput(L10n.format("Internal tester %@ is assigned to the configured TestFlight group.\n", email))
        }
    }

    private func betaGroup(_ groupID: String, containsBuild buildID: String) async throws -> Bool {
        try await pagedData(
            path: "/v1/betaGroups/\(groupID)/relationships/builds",
            query: ["limit": "200"]
        ).contains { $0["id"] as? String == buildID }
    }

    func uploadReviewAttachments(
        _ attachments: [URL],
        versionID: String,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws {
        guard !attachments.isEmpty else { return }
        let details = try await request(
            method: "GET",
            path: "/v1/appStoreVersions/\(versionID)/appStoreReviewDetail"
        )
        let reviewDetailID = try Self.identifier(in: details, named: "App Review details")
        var existing = try await pagedData(
            path: "/v1/appStoreReviewDetails/\(reviewDetailID)/appStoreReviewAttachments",
            query: ["limit": "200"]
        )

        for attachmentURL in attachments {
            try Task.checkCancellation()
            let fileData = try Data(contentsOf: attachmentURL, options: [.mappedIfSafe])
            let filename = attachmentURL.lastPathComponent
            if let match = existing.first(where: {
                let attributes = Self.attributes($0)
                return attributes["fileName"] as? String == filename
            }) {
                let attributes = Self.attributes(match)
                let state = Self.assetState(attributes)
                let sizeMatches = (attributes["fileSize"] as? Int) == fileData.count
                if state == "COMPLETE", sizeMatches {
                    onOutput(L10n.format("Preserving existing App Review attachment %@.\n", filename))
                    continue
                }
                if let attachmentID = match["id"] as? String {
                    _ = try await request(
                        method: "DELETE",
                        path: "/v1/appStoreReviewAttachments/\(attachmentID)"
                    )
                    existing.removeAll { $0["id"] as? String == attachmentID }
                }
            }

            let reserved = try await request(
                method: "POST",
                path: "/v1/appStoreReviewAttachments",
                body: [
                    "data": [
                        "type": "appStoreReviewAttachments",
                        "attributes": ["fileName": filename, "fileSize": fileData.count],
                        "relationships": [
                            "appStoreReviewDetail": [
                                "data": ["type": "appStoreReviewDetails", "id": reviewDetailID]
                            ]
                        ]
                    ]
                ]
            )
            let attachmentID = try Self.identifier(in: reserved, named: "App Review attachment")
            try await uploadReservedAsset(data: fileData, response: reserved)
            _ = try await request(
                method: "PATCH",
                path: "/v1/appStoreReviewAttachments/\(attachmentID)",
                body: [
                    "data": [
                        "type": "appStoreReviewAttachments",
                        "id": attachmentID,
                        "attributes": [
                            "uploaded": true,
                            "sourceFileChecksum": Self.md5Hex(fileData)
                        ]
                    ]
                ]
            )
            try await waitForReviewAttachment(
                attachmentID,
                filename: filename,
                onOutput: onOutput
            )
        }
    }

    private func waitForReviewAttachment(
        _ attachmentID: String,
        filename: String,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws {
        for _ in 0..<120 {
            try Task.checkCancellation()
            let response = try await request(
                method: "GET",
                path: "/v1/appStoreReviewAttachments/\(attachmentID)"
            )
            let resource = response["data"] as? [String: Any] ?? [:]
            let attributes = Self.attributes(resource)
            switch Self.assetState(attributes) {
            case "COMPLETE":
                onOutput(L10n.format("Uploaded App Review attachment %@.\n", filename))
                return
            case "FAILED":
                let state = attributes["assetDeliveryState"] as? [String: Any]
                let messages = (state?["errors"] as? [[String: Any]] ?? []).compactMap {
                    ($0["description"] as? String) ?? ($0["code"] as? String)
                }
                throw AppStoreConnectError.requestFailed(
                    422,
                    messages.joined(separator: "\n").nilIfEmpty
                        ?? L10n.format("App Review attachment %@ failed processing.", filename)
                )
            default:
                try await Task.sleep(for: .seconds(5))
            }
        }
        throw AppStoreConnectError.requestFailed(
            408,
            L10n.format("App Review attachment %@ did not finish processing in time.", filename)
        )
    }

    func cancelActiveAppVersionReview(
        bundleIdentifier: String,
        replacingWith version: String,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> String? {
        let appID = try await findApplication(bundleIdentifier: bundleIdentifier)
        let versions = try await pagedData(
            path: "/v1/apps/\(appID)/appStoreVersions",
            query: ["filter[platform]": "IOS", "limit": "200"]
        )
        guard let activeVersion = Self.activeReviewVersion(in: versions),
              activeVersion.versionString != version else {
            return nil
        }

        let submissions = try await pagedData(
            path: "/v1/apps/\(appID)/reviewSubmissions",
            query: ["limit": "200"]
        )
        let cancellableSubmissionStates: Set<String> = ["WAITING_FOR_REVIEW", "IN_REVIEW"]
        var submissionID: String?
        for submission in submissions {
            guard let id = submission["id"] as? String,
                  let state = Self.attributes(submission)["state"] as? String,
                  cancellableSubmissionStates.contains(state) else { continue }
            let response = try await request(
                method: "GET",
                path: "/v1/reviewSubmissions/\(id)/items",
                query: ["include": "appStoreVersion", "limit": "200"]
            )
            let items = response["data"] as? [[String: Any]] ?? []
            let included = response["included"] as? [[String: Any]] ?? []
            let containsVersion = items.contains {
                let relationships = $0["relationships"] as? [String: Any]
                return Self.relationshipID(relationships?["appStoreVersion"]) == activeVersion.id
            } || included.contains {
                $0["type"] as? String == "appStoreVersions"
                    && $0["id"] as? String == activeVersion.id
            }
            if containsVersion {
                submissionID = id
                break
            }
        }
        guard let submissionID else {
            throw AppStoreConnectError.activeReviewSubmissionNotFound(activeVersion.versionString)
        }

        onOutput(L10n.format(
            "Canceling the App Review submission for version %@ before replacing it…\n",
            activeVersion.versionString
        ))
        _ = try await request(
            method: "PATCH",
            path: "/v1/reviewSubmissions/\(submissionID)",
            body: [
                "data": [
                    "type": "reviewSubmissions",
                    "id": submissionID,
                    "attributes": ["canceled": true]
                ]
            ]
        )
        for attempt in 0..<30 {
            try Task.checkCancellation()
            let response = try await request(
                method: "GET",
                path: "/v1/appStoreVersions/\(activeVersion.id)"
            )
            let resource = response["data"] as? [String: Any] ?? [:]
            let state = Self.attributes(resource)["appStoreState"] as? String ?? ""
            if !AppStoreVersionLifecycle.isCancellableReviewState(state)
                && state != "PROCESSING_FOR_APP_STORE" {
                onOutput(L10n.format(
                    "Version %@ was removed from review and can now be replaced.\n",
                    activeVersion.versionString
                ))
                return activeVersion.id
            }
            if attempt < 29 {
                try await Task.sleep(for: .seconds(2))
            }
        }
        throw AppStoreConnectError.activeReviewCancellationTimedOut(activeVersion.versionString)
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

    private func subscriptionAvailableTerritoryIDs(
        subscriptionID: String
    ) async throws -> [String] {
        let availability = try await request(
            method: "GET",
            path: "/v1/subscriptions/\(subscriptionID)/subscriptionAvailability"
        )
        guard let resource = availability["data"] as? [String: Any],
              let availabilityID = resource["id"] as? String else {
            throw AppStoreConnectError.invalidResponse
        }
        return try await pagedData(
            path: "/v1/subscriptionAvailabilities/\(availabilityID)/availableTerritories",
            query: ["limit": "200"]
        ).compactMap { $0["id"] as? String }
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

    static func hasVersionBlockingNewStorefront(in versions: [[String: Any]]) -> Bool {
        versions.contains { resource in
            guard let state = Self.attributes(resource)["appStoreState"] as? String else {
                return false
            }
            return AppStoreVersionLifecycle.blocksNewStorefront(state)
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

    func configureLocalizedAppInformation(
        appID: String,
        locale: String,
        appName: String?,
        subtitle: String?,
        privacyPolicyURL: String?,
        privacyChoicesURL: String?
    ) async throws -> AppStoreLocalizedNamePreservation? {
        var attributes: [String: Any] = [:]
        if let appName = appName?.nilIfEmpty { attributes["name"] = String(appName.prefix(30)) }
        if let subtitle = subtitle?.nilIfEmpty { attributes["subtitle"] = String(subtitle.prefix(30)) }
        if let privacyPolicyURL = privacyPolicyURL?.nilIfEmpty {
            attributes["privacyPolicyUrl"] = privacyPolicyURL
        }
        if let privacyChoicesURL = privacyChoicesURL?.nilIfEmpty {
            attributes["privacyChoicesUrl"] = privacyChoicesURL
        }
        guard !attributes.isEmpty else { return nil }

        let infos = try await pagedData(
            path: "/v1/apps/\(appID)/appInfos",
            query: ["limit": "200"]
        )
        guard let info = Self.currentAppInfo(infos), let infoID = info["id"] as? String else {
            throw AppStoreConnectError.missingIdentifier("app information")
        }
        let localizations = try await pagedData(
            path: "/v1/appInfos/\(infoID)/appInfoLocalizations",
            query: ["limit": "200"]
        )
        if let existing = localizations.first(where: {
            Self.attributes($0)["locale"] as? String == locale
        }), let localizationID = existing["id"] as? String {
            let existingAttributes = Self.attributes(existing)
            var changedAttributes = attributes.filter { key, value in
                existingAttributes[key] as? String != value as? String
            }
            guard !changedAttributes.isEmpty else { return nil }
            do {
                try await updateAppInfoLocalization(
                    localizationID,
                    attributes: changedAttributes
                )
            } catch AppStoreConnectError.requestFailed(let status, let message) {
                guard let requestedName = changedAttributes["name"] as? String,
                      let existingName = existingAttributes["name"] as? String,
                      existingName.nilIfEmpty != nil,
                      Self.isAppNameAvailabilityConflict(status: status, message: message) else {
                    throw AppStoreConnectError.requestFailed(status, message)
                }
                changedAttributes.removeValue(forKey: "name")
                if !changedAttributes.isEmpty {
                    try await updateAppInfoLocalization(
                        localizationID,
                        attributes: changedAttributes
                    )
                }
                return AppStoreLocalizedNamePreservation(
                    locale: locale,
                    requestedName: requestedName,
                    existingName: existingName
                )
            }
        } else {
            attributes["locale"] = locale
            _ = try await request(
                method: "POST",
                path: "/v1/appInfoLocalizations",
                body: [
                    "data": [
                        "type": "appInfoLocalizations",
                        "attributes": attributes,
                        "relationships": [
                            "appInfo": [
                                "data": ["type": "appInfos", "id": infoID]
                            ]
                        ]
                    ]
                ]
            )
        }
        return nil
    }

    private func updateAppInfoLocalization(
        _ localizationID: String,
        attributes: [String: Any]
    ) async throws {
        _ = try await request(
            method: "PATCH",
            path: "/v1/appInfoLocalizations/\(localizationID)",
            body: [
                "data": [
                    "type": "appInfoLocalizations",
                    "id": localizationID,
                    "attributes": attributes
                ]
            ]
        )
    }

    static func isAppNameAvailabilityConflict(status: Int, message: String) -> Bool {
        guard status == 409 else { return false }
        let normalized = message.lowercased()
        return normalized.contains("app name")
            && (normalized.contains("already being used")
                || normalized.contains("not available"))
    }

    private func configureLicenseAgreement(
        appID: String,
        agreementText: String
    ) async throws {
        do {
            let existing = try await request(
                method: "GET",
                path: "/v1/apps/\(appID)/endUserLicenseAgreement"
            )
            let agreementID = try Self.identifier(in: existing, named: "end-user license agreement")
            _ = try await request(
                method: "PATCH",
                path: "/v1/endUserLicenseAgreements/\(agreementID)",
                body: [
                    "data": [
                        "type": "endUserLicenseAgreements",
                        "id": agreementID,
                        "attributes": ["agreementText": agreementText]
                    ]
                ]
            )
        } catch AppStoreConnectError.requestFailed(let status, _) where status == 404 {
            let territories = try await pagedData(
                path: "/v1/territories",
                query: ["limit": "200"]
            ).compactMap { $0["id"] as? String }
            _ = try await request(
                method: "POST",
                path: "/v1/endUserLicenseAgreements",
                body: [
                    "data": [
                        "type": "endUserLicenseAgreements",
                        "attributes": ["agreementText": agreementText],
                        "relationships": [
                            "app": ["data": ["type": "apps", "id": appID]],
                            "territories": [
                                "data": territories.map { ["type": "territories", "id": $0] }
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
        subscriptionID: String,
        territoryIDs: [String]
    ) -> [String: Any] {
        let uniqueTerritoryIDs = Array(Set(territoryIDs)).sorted()
        let prices: [[String: String]] = uniqueTerritoryIDs.map {
            ["type": "subscriptionOfferCodePrices", "id": "${offer-price-\($0)}"]
        }
        let included: [[String: Any]] = uniqueTerritoryIDs.map {
            [
                "type": "subscriptionOfferCodePrices",
                "id": "${offer-price-\($0)}",
                "relationships": [
                    "territory": [
                        "data": ["type": "territories", "id": $0]
                    ]
                ]
            ]
        }
        return [
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
                    "prices": ["data": prices]
                ]
            ],
            "included": included
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
        let versions = try await pagedData(
            path: "/v1/subscriptionGroups/\(groupID)/versions",
            query: ["limit": "200"]
        )
        if let id = Self.reusableSubscriptionVersionID(in: versions) { return id }
        do {
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
        } catch let error as AppStoreConnectError {
            guard case .requestFailed(let status, _) = error, status == 409 else { throw error }
            let refreshed = try await pagedData(
                path: "/v1/subscriptionGroups/\(groupID)/versions",
                query: ["limit": "200"]
            )
            guard let id = Self.reusableSubscriptionVersionID(in: refreshed) else { throw error }
            return id
        }
    }

    private func editableSubscriptionVersion(subscriptionID: String) async throws -> String? {
        let versions = try await pagedData(
            path: "/v1/subscriptions/\(subscriptionID)/versions",
            query: ["limit": "200"]
        )
        return Self.reusableSubscriptionVersionID(in: versions)
    }

    private func findOrCreateSubscriptionVersion(subscriptionID: String) async throws -> String {
        if let existing = try await editableSubscriptionVersion(subscriptionID: subscriptionID) {
            return existing
        }
        do {
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
        } catch let error as AppStoreConnectError {
            guard case .requestFailed(let status, _) = error, status == 409 else { throw error }
            guard let existing = try await editableSubscriptionVersion(subscriptionID: subscriptionID) else {
                throw error
            }
            return existing
        }
    }

    static func reusableSubscriptionVersionID(in versions: [[String: Any]]) -> String? {
        let reusableStates: Set<String> = [
            "PREPARE_FOR_SUBMISSION",
            "READY_FOR_REVIEW",
            "WAITING_FOR_REVIEW",
            "IN_REVIEW",
            "REJECTED"
        ]
        return versions.filter {
            guard let state = Self.attributes($0)["state"] as? String else { return false }
            return reusableStates.contains(state)
        }.max {
            let left = Self.attributes($0)["version"] as? Int ?? 0
            let right = Self.attributes($1)["version"] as? Int ?? 0
            return left < right
        }?["id"] as? String
    }

    private func upsertGroupLocalizations(
        _ localizations: [AppStoreSubscriptionLocalization],
        versionID: String
    ) async throws {
        let existing = try await pagedData(
            path: "/v1/subscriptionGroupVersions/\(versionID)/localizations",
            query: ["limit": "50"]
        )
        for localization in Self.normalizedSubscriptionLocalizations(localizations) {
            let match = existing.first(where: {
                let attributes = $0["attributes"] as? [String: Any]
                guard let locale = attributes?["locale"] as? String else { return false }
                return AppStoreLocale.canonicalIdentifier(locale) == localization.locale
            })
            let localizationID = match?["id"] as? String
            let attributes = Self.subscriptionGroupLocalizationAttributes(
                localization,
                includesLocale: localizationID == nil
            )
            if let localizationID {
                if Self.hasMatchingStringAttributes(
                    Self.attributes(match ?? [:]),
                    expected: attributes
                ) {
                    continue
                }
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
        for localization in Self.normalizedSubscriptionLocalizations(localizations) {
            let match = existing.first(where: {
                let attributes = $0["attributes"] as? [String: Any]
                guard let locale = attributes?["locale"] as? String else { return false }
                return AppStoreLocale.canonicalIdentifier(locale) == localization.locale
            })
            let localizationID = match?["id"] as? String
            let attributes = Self.subscriptionLocalizationAttributes(
                localization,
                includesLocale: localizationID == nil
            )
            if let localizationID {
                if Self.hasMatchingStringAttributes(
                    Self.attributes(match ?? [:]),
                    expected: attributes
                ) {
                    continue
                }
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

    static func subscriptionGroupLocalizationAttributes(
        _ localization: AppStoreSubscriptionLocalization,
        includesLocale: Bool
    ) -> [String: Any] {
        var attributes: [String: Any] = ["name": localization.name]
        if includesLocale {
            attributes["locale"] = localization.locale
        }
        if let customName = localization.description?.nilIfEmpty {
            attributes["customAppName"] = customName
        }
        return attributes
    }

    static func subscriptionLocalizationAttributes(
        _ localization: AppStoreSubscriptionLocalization,
        includesLocale: Bool
    ) -> [String: Any] {
        var attributes: [String: Any] = ["name": localization.name]
        if includesLocale {
            attributes["locale"] = localization.locale
        }
        if let description = localization.description?.nilIfEmpty {
            attributes["description"] = description
        }
        return attributes
    }

    static func normalizedSubscriptionLocalizations(
        _ localizations: [AppStoreSubscriptionLocalization]
    ) -> [AppStoreSubscriptionLocalization] {
        var seenLocales: Set<String> = []
        return localizations.compactMap { localization in
            guard let locale = AppStoreLocale.canonicalIdentifier(localization.locale),
                  seenLocales.insert(locale.lowercased()).inserted else {
                return nil
            }
            var normalized = localization
            normalized.locale = locale
            return normalized
        }
    }

    private static func hasMatchingStringAttributes(
        _ existing: [String: Any],
        expected: [String: Any]
    ) -> Bool {
        expected.allSatisfy { key, value in
            guard let value = value as? String else { return false }
            return existing[key] as? String == value
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
        territoryPrices: [String: String],
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
        guard let baseSelection = Self.closestSubscriptionPricePoint(
            in: pricePoints,
            requestedPrice: basePrice
        ) else {
            throw AppStoreConnectError.requestFailed(
                422,
                L10n.format("Price %@ is not an available subscription price point in %@ for %@.", basePrice, baseTerritory, productID)
            )
        }
        let basePointID = baseSelection.id
        let effectiveBasePrice = baseSelection.price
        if !Self.pricesEqual(effectiveBasePrice, basePrice) {
            onOutput(L10n.format(
                "Apple does not offer subscription price %@ in %@ for %@; using nearest available price %@.\n",
                basePrice,
                baseTerritory,
                productID,
                effectiveBasePrice
            ))
        }

        var desiredPointsByTerritory = [baseTerritory.uppercased(): basePointID]
        var unscopedDesiredPointIDs: Set<String> = []
        if allTerritories {
            let equalizations = try await pagedData(
                path: "/v1/subscriptionPricePoints/\(basePointID)/equalizations",
                query: [
                    "fields[subscriptionPricePoints]": "customerPrice,territory",
                    "include": "territory",
                    "limit": "8000"
                ]
            )
            for point in equalizations {
                guard let pointID = point["id"] as? String else { continue }
                let relationships = point["relationships"] as? [String: Any]
                if let territoryID = Self.relationshipID(relationships?["territory"])?.uppercased() {
                    desiredPointsByTerritory[territoryID] = pointID
                } else {
                    unscopedDesiredPointIDs.insert(pointID)
                }
            }
        }

        var pointIDsByOverrideTerritory: [String: Set<String>] = [:]
        for (rawTerritory, overridePrice) in territoryPrices.sorted(by: { $0.key < $1.key }) {
            let territory = rawTerritory.uppercased()
            let points = try await pagedData(
                path: "/v1/subscriptions/\(subscriptionID)/pricePoints",
                query: ["filter[territory]": territory, "limit": "200"]
            )
            pointIDsByOverrideTerritory[territory] = Set(points.compactMap { $0["id"] as? String })
            guard let selection = Self.closestSubscriptionPricePoint(
                in: points,
                requestedPrice: overridePrice
            ) else {
                throw AppStoreConnectError.requestFailed(
                    422,
                    L10n.format("Price %@ is not an available subscription price point in %@ for %@.", overridePrice, territory, productID)
                )
            }
            if !Self.pricesEqual(selection.price, overridePrice) {
                onOutput(L10n.format(
                    "Apple does not offer subscription price %@ in %@ for %@; using nearest available price %@.\n",
                    overridePrice,
                    territory,
                    productID,
                    selection.price
                ))
            }
            desiredPointsByTerritory[territory] = selection.id
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

        let desiredPointIDs = Set(desiredPointsByTerritory.values).union(unscopedDesiredPointIDs)
        var createdCount = 0
        for pointID in desiredPointIDs.subtracting(existingPointIDs).sorted() {
            try Task.checkCancellation()
            let territory = desiredPointsByTerritory.first(where: { $0.value == pointID })?.key
            let hasCurrentTerritoryPrice = territory.flatMap { pointIDsByOverrideTerritory[$0] }
                .map { !$0.isDisjoint(with: existingPointIDs) }
                ?? false
            var attributes: [String: Any] = ["preserveCurrentPrice": false]
            if hasCurrentTerritoryPrice {
                attributes["startDate"] = Self.tomorrowDateString()
            }
            do {
                _ = try await request(
                    method: "POST",
                    path: "/v1/subscriptionPrices",
                    body: [
                        "data": [
                            "type": "subscriptionPrices",
                            "attributes": attributes,
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
            effectiveBasePrice,
            baseTerritory,
            createdCount
        ))
    }

    private static func tomorrowDateString(referenceDate: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: referenceDate) ?? referenceDate
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: tomorrow)
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
                    "attributes": [
                        "uploaded": true,
                        "sourceFileChecksum": Self.md5Hex(fileData)
                    ]
                ]
            ]
        )
        onOutput(L10n.format("Uploaded the App Review paywall screenshot for %@.\n", definition.productID))
    }

    private func updateLocalization(
        _ localizationID: String,
        metadata: AppStoreMetadata,
        supportURL: String,
        marketingURL: String?,
        privacyPolicyURL: String?,
        termsURL: String?,
        locale: String,
        includesReleaseNotes: Bool
    ) async throws {
        let description = Self.listingDescription(
            metadata.description,
            locale: locale,
            privacyPolicyURL: privacyPolicyURL,
            termsURL: termsURL
        )
        var attributes: [String: Any] = [
            "description": description,
            "keywords": metadata.keywords,
            "promotionalText": metadata.promotionalText,
            "supportUrl": supportURL
        ]
        if let marketingURL = marketingURL?.nilIfEmpty {
            attributes["marketingUrl"] = marketingURL
        }
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

    static func listingDescription(
        _ rawDescription: String,
        locale: String,
        privacyPolicyURL: String?,
        termsURL: String?
    ) -> String {
        let description = rawDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let links: [(String, String)] = [
            (L10n.text("Privacy Policy", localeIdentifier: locale), privacyPolicyURL?.nilIfEmpty),
            (L10n.text("Terms of Use", localeIdentifier: locale), termsURL?.nilIfEmpty)
        ].compactMap { label, value in
            guard let value, !description.localizedCaseInsensitiveContains(value) else { return nil }
            return (label, value)
        }
        guard !links.isEmpty else { return String(description.prefix(4_000)) }

        let legalText = links.map { "\($0): \($1)" }.joined(separator: "\n")
        guard legalText.count < 4_000 else { return String(legalText.prefix(4_000)) }
        let separator = description.isEmpty ? "" : "\n\n"
        let availableDescriptionLength = max(0, 4_000 - separator.count - legalText.count)
        let shortenedDescription = String(description.prefix(availableDescriptionLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return shortenedDescription
            + (shortenedDescription.isEmpty ? "" : "\n\n")
            + legalText
    }

    private func findOrCreateVersion(
        appID: String,
        version: String,
        copyright: String,
        releaseAutomatically: Bool,
        reusableVersionID: String?
    ) async throws -> String {
        let response = try await request(
            method: "GET",
            path: "/v1/apps/\(appID)/appStoreVersions",
            query: ["filter[platform]": "IOS", "limit": "200"]
        )
        let versions = response["data"] as? [[String: Any]] ?? []
        if let existing = versions.first(where: {
            Self.attributes($0)["versionString"] as? String == version
        }),
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
        let versionIDToReuse = reusableVersionID
            ?? Self.reusableDraftVersion(in: versions)?.id
        if let versionIDToReuse {
            _ = try await request(
                method: "PATCH",
                path: "/v1/appStoreVersions/\(versionIDToReuse)",
                body: [
                    "data": [
                        "type": "appStoreVersions",
                        "id": versionIDToReuse,
                        "attributes": [
                            "versionString": version,
                            "releaseType": releaseAutomatically ? "AFTER_APPROVAL" : "MANUAL",
                            "copyright": copyright
                        ]
                    ]
                ]
            )
            return versionIDToReuse
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
                    "attributes": [
                        "uploaded": true,
                        "sourceFileChecksum": Self.md5Hex(fileData)
                    ]
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

    private func pagedResources(
        path: String,
        query: [String: String] = [:]
    ) async throws -> (data: [[String: Any]], included: [[String: Any]]) {
        var data: [[String: Any]] = []
        var included: [[String: Any]] = []
        var nextPath: String? = path
        var nextQuery = query
        while let currentPath = nextPath {
            let response = try await request(
                method: "GET",
                path: currentPath,
                query: nextQuery
            )
            data.append(contentsOf: response["data"] as? [[String: Any]] ?? [])
            included.append(contentsOf: response["included"] as? [[String: Any]] ?? [])
            let links = response["links"] as? [String: Any]
            nextPath = links?["next"] as? String
            nextQuery = [:]
        }
        return (data, included)
    }

    func pagedData(
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

    func request(
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
        if Self.shouldRetryRequest(
            method: method,
            statusCode: http.statusCode,
            retryCount: retryCount
        ) {
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
            let message = Self.errorMessage(from: data)
            if Self.transientServerStatusCodes.contains(http.statusCode) {
                throw AppStoreConnectError.requestFailed(
                    http.statusCode,
                    "\(message) (\(method.uppercased()) \(path))"
                )
            }
            throw AppStoreConnectError.requestFailed(http.statusCode, message)
        }
        if data.isEmpty { return [:] }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppStoreConnectError.invalidResponse
        }
        return root
    }

    private static let transientServerStatusCodes: Set<Int> = [500, 502, 503, 504]

    static func shouldRetryRequest(
        method: String,
        statusCode: Int,
        retryCount: Int
    ) -> Bool {
        guard retryCount < 5 else { return false }
        if statusCode == 429 { return true }
        guard transientServerStatusCodes.contains(statusCode) else { return false }
        return ["GET", "HEAD", "PUT", "PATCH", "DELETE"].contains(method.uppercased())
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

    static func identifier(in response: [String: Any], named name: String) throws -> String {
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

    static func closestSubscriptionPricePoint(
        in pricePoints: [[String: Any]],
        requestedPrice: String
    ) -> (id: String, price: String)? {
        guard let requested = Decimal(
            string: requestedPrice,
            locale: Locale(identifier: "en_US_POSIX")
        ) else { return nil }
        return pricePoints.compactMap { point -> (id: String, price: String, value: Decimal)? in
            guard let id = point["id"] as? String,
                  let parsed = decimalPrice(Self.attributes(point)["customerPrice"]) else {
                return nil
            }
            return (id, parsed.text, parsed.value)
        }
        .min { lhs, rhs in
            let lhsDifference = lhs.value >= requested
                ? lhs.value - requested
                : requested - lhs.value
            let rhsDifference = rhs.value >= requested
                ? rhs.value - requested
                : requested - rhs.value
            if lhsDifference != rhsDifference { return lhsDifference < rhsDifference }
            return lhs.value < rhs.value
        }
        .map { ($0.id, $0.price) }
    }

    private static func decimalPrice(_ rawValue: Any?) -> (value: Decimal, text: String)? {
        let text: String
        if let value = rawValue as? String {
            text = value
        } else if let value = rawValue as? NSNumber {
            text = value.stringValue
        } else {
            return nil
        }
        guard let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) else {
            return nil
        }
        return (value, text)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func md5Hex(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func assetState(_ attributes: [String: Any]) -> String? {
        (attributes["assetDeliveryState"] as? [String: Any])?["state"] as? String
    }
}
