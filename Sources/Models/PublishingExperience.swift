import Foundation

enum PublishingJourneyStage: Int, CaseIterable, Equatable, Identifiable {
    case prepare
    case build
    case configure
    case testFlight
    case review

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .prepare: L10n.text("Prepare")
        case .build: L10n.text("Build")
        case .configure: L10n.text("App Store setup")
        case .testFlight: L10n.text("TestFlight")
        case .review: L10n.text("Review")
        }
    }

    var detail: String {
        switch self {
        case .prepare: L10n.text("Check products, store text, links, and screenshots.")
        case .build: L10n.text("Create and export the signed App Store archive.")
        case .configure: L10n.text("Update listing details, subscriptions, and screenshots.")
        case .testFlight: L10n.text("Upload the build and make it available to internal testers.")
        case .review: L10n.text("Attach review material and send the release to Apple.")
        }
    }

    var symbolName: String {
        switch self {
        case .prepare: "checklist"
        case .build: "hammer.fill"
        case .configure: "app.badge.checkmark"
        case .testFlight: "paperplane.fill"
        case .review: "checkmark.seal.fill"
        }
    }
}

extension PublishingProgress.Phase {
    var journeyStage: PublishingJourneyStage {
        switch self {
        case .preparing, .discoveringSubscriptions, .generatingMetadata, .collectingScreenshots:
            .prepare
        case .archiving:
            .build
        case .publishingPrivacy, .uploadingMetadata, .configuringSubscriptions, .uploadingScreenshots:
            .configure
        case .uploadingBuild, .waitingForBuild, .configuringTestFlight:
            .testFlight
        case .uploadingReviewAssets, .submitting:
            .review
        }
    }

    var friendlyDetail: String {
        switch self {
        case .preparing: L10n.text("Checking the project and public App Store links.")
        case .discoveringSubscriptions: L10n.text("Reading the subscription products included with the app.")
        case .publishingPrivacy: L10n.text("Sending the reviewed privacy declaration to App Store Connect.")
        case .generatingMetadata: L10n.text("Preparing an editable store listing for every app language.")
        case .collectingScreenshots: L10n.text("Finding supplied screenshots and capturing any missing device sizes.")
        case .archiving: L10n.text("Xcode is building, signing, and exporting the production app.")
        case .uploadingMetadata: L10n.text("Applying the app name, description, categories, availability, and review details.")
        case .configuringSubscriptions: L10n.text("Reconciling subscription products, prices, availability, and localizations.")
        case .uploadingScreenshots: L10n.text("Sending the prepared screenshots to each App Store locale.")
        case .uploadingBuild: L10n.text("Uploading the signed app package to App Store Connect.")
        case .waitingForBuild: L10n.text("Apple is processing the uploaded build. This is often the longest step.")
        case .configuringTestFlight: L10n.text("Adding the processed build to the internal TestFlight group.")
        case .uploadingReviewAssets: L10n.text("Uploading screen recordings and documents for the reviewer.")
        case .submitting: L10n.text("Running final checks and submitting the complete release to App Review.")
        }
    }

    var completionFraction: Double {
        guard let index = Self.allCases.firstIndex(of: self) else { return 0 }
        return Double(index + 1) / Double(Self.allCases.count)
    }
}

struct PublishingReadinessItem: Equatable, Identifiable {
    enum State: Equatable {
        case ready
        case checking
        case attention
        case blocked
    }

    let id: String
    let title: String
    let detail: String
    let state: State
}

struct PublishingReadinessReport: Equatable {
    let items: [PublishingReadinessItem]

    var isChecking: Bool {
        items.contains { $0.state == .checking }
    }

    var blockers: [PublishingReadinessItem] {
        items.filter { $0.state == .blocked }
    }

    var allowsPublication: Bool {
        !isChecking && blockers.isEmpty
    }
}

enum TestFlightReadinessPolicy {
    static func accountItem(credentialIsComplete: Bool) -> PublishingReadinessItem {
        PublishingReadinessItem(
            id: "account",
            title: credentialIsComplete
                ? L10n.text("App Store Connect is ready")
                : L10n.text("App Store Connect needs attention"),
            detail: credentialIsComplete
                ? L10n.text("The API key is configured and will be verified when the TestFlight upload starts.")
                : L10n.text("Complete the API key configuration before publishing."),
            state: credentialIsComplete ? .ready : .blocked
        )
    }
}

enum AppStoreReleaseActionPolicy {
    static func showsAppStoreAction(
        hasReleasedVersion: Bool,
        hasMatchingTestFlightBuild: Bool
    ) -> Bool {
        hasReleasedVersion || hasMatchingTestFlightBuild
    }
}

struct AppStoreConnectPublicationFallback: Equatable {
    let copyright: String?
    let supportURL: String?
    let review: AppStoreConnectReviewSnapshot?
}

extension AppStoreConnectConfigurationSnapshot {
    func publicationFallback(preferredLocale: String?) -> AppStoreConnectPublicationFallback {
        let localizations = version?.localizations ?? []
        let preferred = preferredLocale?.replacingOccurrences(of: "_", with: "-").lowercased()
        let language = preferred?.split(separator: "-").first.map(String.init)
        let localizedSupportURL = localizations.first {
            $0.locale.replacingOccurrences(of: "_", with: "-").lowercased() == preferred
        }?.supportURL?.nilIfEmpty
        let languageSupportURL = localizations.first {
            $0.locale.replacingOccurrences(of: "_", with: "-")
                .lowercased().split(separator: "-").first.map(String.init) == language
                && $0.supportURL?.nilIfEmpty != nil
        }?.supportURL?.nilIfEmpty
        let anySupportURL = localizations.compactMap { $0.supportURL?.nilIfEmpty }.first

        return AppStoreConnectPublicationFallback(
            copyright: version?.copyright?.nilIfEmpty,
            supportURL: localizedSupportURL ?? languageSupportURL ?? anySupportURL,
            review: version?.review
        )
    }
}

enum AppStoreVersionComparison {
    static func localArtifactIsOlder(
        localVersion: String,
        localBuild: String?,
        remoteVersion: String,
        remoteBuild: String?
    ) -> Bool {
        let versionResult = compare(localVersion, remoteVersion)
        if versionResult == .orderedAscending { return true }
        guard versionResult == .orderedSame,
              let localBuild,
              let remoteBuild else { return false }
        return compare(localBuild, remoteBuild) == .orderedAscending
    }

    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = numericComponents(lhs)
        let right = numericComponents(rhs)
        let count = max(left.count, right.count)
        for index in 0..<count {
            let leftValue = index < left.count ? left[index] : 0
            let rightValue = index < right.count ? right[index] : 0
            if leftValue < rightValue { return .orderedAscending }
            if leftValue > rightValue { return .orderedDescending }
        }
        if !left.isEmpty || !right.isEmpty { return .orderedSame }
        return lhs.localizedStandardCompare(rhs)
    }

    private static func numericComponents(_ value: String) -> [Int] {
        value.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    }
}

enum SubscriptionOfferCodeCSV {
    static func values(from data: Data) -> [String] {
        guard var text = String(data: data, encoding: .utf8) else { return [] }
        if text.first == "\u{feff}" { text.removeFirst() }
        let rows = text
            .split(whereSeparator: \.isNewline)
            .map { fields(in: String($0)) }
            .filter { !$0.isEmpty }
        guard let first = rows.first else { return [] }
        let headerIndex = first.firstIndex { field in
            let normalized = field.lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized == "code"
                || normalized == "offer code"
                || normalized == "redemption code"
        }
        let hasHeader = headerIndex != nil || first.contains {
            $0.lowercased().contains("redemption url")
        }
        let candidateRows = hasHeader ? Array(rows.dropFirst()) : rows
        var seen = Set<String>()
        return candidateRows.compactMap { row in
            let preferred = headerIndex.flatMap { $0 < row.count ? row[$0] : nil }
            let value = preferred?.nilIfEmpty
                ?? row.first(where: { !$0.lowercased().hasPrefix("http") })?.nilIfEmpty
                ?? row.compactMap(codeFromRedemptionURL).first
            guard let value,
                  seen.insert(value).inserted else { return nil }
            return value
        }
    }

    private static func fields(in row: String) -> [String] {
        var fields: [String] = []
        var field = ""
        var quoted = false
        var index = row.startIndex
        while index < row.endIndex {
            let character = row[index]
            if character == "\"" {
                let next = row.index(after: index)
                if quoted, next < row.endIndex, row[next] == "\"" {
                    field.append("\"")
                    index = row.index(after: next)
                    continue
                }
                quoted.toggle()
            } else if character == ",", !quoted {
                fields.append(field.trimmingCharacters(in: .whitespacesAndNewlines))
                field = ""
            } else {
                field.append(character)
            }
            index = row.index(after: index)
        }
        fields.append(field.trimmingCharacters(in: .whitespacesAndNewlines))
        return fields
    }

    private static func codeFromRedemptionURL(_ value: String) -> String? {
        guard let components = URLComponents(string: value),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
            return nil
        }
        return code.nilIfEmpty
    }
}

enum SubscriptionOfferCodeRedemption {
    static func url(appID: String, code: String) -> URL? {
        guard appID.nilIfEmpty != nil, code.nilIfEmpty != nil else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "apps.apple.com"
        components.path = "/redeem"
        components.queryItems = [
            URLQueryItem(name: "ctx", value: "offercodes"),
            URLQueryItem(name: "id", value: appID),
            URLQueryItem(name: "code", value: code)
        ]
        return components.url
    }
}

enum SubscriptionOfferCodeAvailabilityOrdering {
    static func oneTime(
        _ batches: [AppStoreConnectOneTimeCodeBatchSnapshot]
    ) -> [AppStoreConnectOneTimeCodeBatchSnapshot] {
        batches.sorted {
            if $0.active != $1.active { return $0.active && !$1.active }
            return ($0.createdDate ?? "") > ($1.createdDate ?? "")
        }
    }

    static func custom(
        _ batches: [AppStoreConnectCustomCodeBatchSnapshot]
    ) -> [AppStoreConnectCustomCodeBatchSnapshot] {
        batches.sorted {
            if $0.active != $1.active { return $0.active && !$1.active }
            return ($0.createdDate ?? "") > ($1.createdDate ?? "")
        }
    }
}
