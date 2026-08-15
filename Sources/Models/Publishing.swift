import Foundation

struct AppStoreMetadata: Codable, Equatable, Sendable {
    let description: String
    let keywords: String
    let promotionalText: String
    let whatsNew: String
    var subtitle: String? = nil
    var primaryCategory: String? = nil
    var secondaryCategory: String? = nil

    func normalized() -> AppStoreMetadata {
        AppStoreMetadata(
            description: Self.limited(description, characters: 4_000),
            keywords: Self.limitedUTF8(keywords, bytes: 100),
            promotionalText: Self.limited(promotionalText, characters: 170),
            whatsNew: Self.limited(whatsNew, characters: 4_000),
            subtitle: subtitle.map { Self.limited($0, characters: 30) },
            primaryCategory: primaryCategory?.nilIfEmpty,
            secondaryCategory: secondaryCategory?.nilIfEmpty
        )
    }

    private static func limited(_ value: String, characters: Int) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(characters))
    }

    private static func limitedUTF8(_ value: String, bytes: Int) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.lengthOfBytes(using: .utf8) > bytes, !result.isEmpty {
            result.removeLast()
        }
        return result
    }
}

struct AppStoreReviewConfiguration: Equatable, Sendable {
    let contactFirstName: String
    let contactLastName: String
    let contactPhone: String
    let contactEmail: String
    let notes: String
    let demoAccountRequired: Bool
    let demoAccountName: String?
    let demoAccountPassword: String?
}

enum AppStoreManifestValue: Codable, Equatable, Sendable {
    case string(String)
    case bool(Bool)
    case integer(Int)
    case decimal(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .decimal(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .decimal(let value): try container.encode(value)
        }
    }

    var jsonObject: Any {
        switch self {
        case .string(let value): value
        case .bool(let value): value
        case .integer(let value): value
        case .decimal(let value): value
        }
    }
}

struct AppStoreApplicationConfiguration: Codable, Equatable, Sendable {
    var primaryCategory: String?
    var secondaryCategory: String?
    var contentRightsDeclaration: String?
    var isFree: Bool?
    var baseTerritory: String?
    var availableInAllTerritories: Bool?
    var ageRating: [String: AppStoreManifestValue]?

    var isEmpty: Bool {
        primaryCategory == nil
            && secondaryCategory == nil
            && contentRightsDeclaration == nil
            && isFree == nil
            && availableInAllTerritories == nil
            && (ageRating?.isEmpty != false)
    }
}

struct AppStoreSubscriptionLocalization: Codable, Equatable, Sendable {
    var locale: String
    var name: String
    var description: String?
}

struct AppStoreSubscriptionDefinition: Codable, Equatable, Sendable {
    var referenceName: String
    var productID: String
    var period: String
    var basePrice: String?
    var baseTerritory: String?
    var availableInAllTerritories: Bool?
    var familySharable: Bool?
    var groupLevel: Int?
    var reviewNote: String?
    var reviewScreenshot: String?
    var localizations: [AppStoreSubscriptionLocalization]?
}

struct AppStoreSubscriptionGroupDefinition: Codable, Equatable, Sendable {
    var referenceName: String
    var localizations: [AppStoreSubscriptionLocalization]?
    var subscriptions: [AppStoreSubscriptionDefinition]
}

struct AppStoreSubscriptionsConfiguration: Codable, Equatable, Sendable {
    var baseTerritory: String?
    var availableInAllTerritories: Bool?
    var reviewScreenshot: String?
    var groups: [AppStoreSubscriptionGroupDefinition]?
}

struct AppStoreReviewManifestConfiguration: Codable, Equatable, Sendable {
    var contactFirstName: String?
    var contactLastName: String?
    var contactPhone: String?
    var contactEmail: String?
    var notes: String?
    var demoAccountRequired: Bool?
}

struct AppStorePublicationConfiguration: Codable, Equatable, Sendable {
    var locale: String?
    var copyright: String?
    var supportURL: String?
    var marketingURL: String? = nil
    var termsURL: String? = nil
    var privacyPolicyURL: String? = nil
    var privacyChoicesURL: String? = nil
    var appName: String? = nil
    var subtitle: String? = nil
    var licenseAgreementText: String? = nil
    var submitForReview: Bool?
    var releaseAutomatically: Bool?
    var metadata: AppStoreMetadata?
    var screenshotPaths: [String]?
    var replaceScreenshots: Bool? = nil
    var review: AppStoreReviewManifestConfiguration?
}

struct AppStorePublishingManifest: Codable, Equatable, Sendable {
    var schemaVersion: Int?
    var publication: AppStorePublicationConfiguration?
    var application: AppStoreApplicationConfiguration?
    var subscriptions: AppStoreSubscriptionsConfiguration?
}

struct AppStoreSubscriptionCatalog: Equatable, Sendable {
    var publication: AppStorePublicationConfiguration?
    var application: AppStoreApplicationConfiguration?
    var groups: [AppStoreSubscriptionGroupDefinition]
    var detectedProductIDs: Set<String>
    var sourceFiles: [String]
    var projectDirectory: URL

    var subscriptionCount: Int {
        groups.reduce(0) { $0 + $1.subscriptions.count }
    }
}

struct AppStoreConnectReviewItem: Equatable, Sendable {
    let relationship: String
    let resourceType: String
    let id: String
    let label: String
}

struct AppStoreConnectConfigurationSnapshot: Equatable, Sendable {
    let appName: String
    let bundleIdentifier: String
    let sku: String?
    let primaryLocale: String?
    let contentRightsDeclaration: String?
    let primaryCategory: String?
    let secondaryCategory: String?
    let ageRating: [String: AppStoreManifestValue]?
    let licenseAgreementText: String?
    let licenseTerritoryIDs: [String]
    let appLocalizations: [AppStoreConnectAppLocalizationSnapshot]
    let version: AppStoreConnectVersionSnapshot?
    let subscriptionGroups: [AppStoreConnectSubscriptionGroupSnapshot]
    let loadedAt: Date
}

struct AppStoreConnectAppLocalizationSnapshot: Equatable, Sendable, Identifiable {
    var id: String { locale }

    let locale: String
    let name: String?
    let subtitle: String?
    let privacyPolicyURL: String?
    let privacyChoicesURL: String?
}

struct AppStoreConnectVersionSnapshot: Equatable, Sendable {
    let versionString: String
    let state: String
    let buildNumber: String?
    let releaseType: String?
    let copyright: String?
    let earliestReleaseDate: String?
    let localizations: [AppStoreConnectVersionLocalizationSnapshot]
    let review: AppStoreConnectReviewSnapshot?

    var isUnderReview: Bool {
        Self.reviewStates.contains(state)
    }

    private static let reviewStates: Set<String> = [
        "WAITING_FOR_REVIEW",
        "IN_REVIEW",
        "PENDING_APPLE_RELEASE",
        "PENDING_DEVELOPER_RELEASE",
        "PROCESSING_FOR_APP_STORE",
        "READY_FOR_SALE",
        "PREORDER_READY_FOR_SALE"
    ]
}

struct AppStoreConnectVersionLocalizationSnapshot: Equatable, Sendable, Identifiable {
    var id: String { locale }

    let locale: String
    let description: String?
    let keywords: String?
    let promotionalText: String?
    let whatsNew: String?
    let supportURL: String?
    let marketingURL: String?
    let screenshotCounts: [String: Int]
}

struct AppStoreConnectReviewSnapshot: Equatable, Sendable {
    let contactFirstName: String?
    let contactLastName: String?
    let contactPhone: String?
    let contactEmail: String?
    let notes: String?
    let demoAccountRequired: Bool
}

struct AppStoreConnectSubscriptionGroupSnapshot: Equatable, Sendable, Identifiable {
    let id: String
    let referenceName: String
    let state: String?
    let localizations: [AppStoreSubscriptionLocalization]
    let subscriptions: [AppStoreConnectSubscriptionSnapshot]
}

struct AppStoreConnectSubscriptionSnapshot: Equatable, Sendable, Identifiable {
    let id: String
    let referenceName: String
    let productID: String
    let state: String?
    let period: String?
    let familySharable: Bool
    let groupLevel: Int?
    let reviewNote: String?
    let localizations: [AppStoreSubscriptionLocalization]
    let availableTerritoryIDs: [String]
    let availableInNewTerritories: Bool?
    let prices: [AppStoreConnectSubscriptionPriceSnapshot]
    let offers: [AppStoreConnectOfferSnapshot]
}

struct AppStoreConnectSubscriptionPriceSnapshot: Equatable, Sendable, Identifiable {
    var id: String { "\(territory)-\(startDate ?? "")-\(price)" }

    let territory: String
    let price: String
    let currency: String?
    let startDate: String?
    let endDate: String?
    let preserved: Bool
}

struct AppStoreConnectOfferSnapshot: Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let active: Bool
    let duration: String?
    let customerEligibilities: [String]
    let productionCodeCount: Int
    let totalNumberOfCodes: Int
}

enum SubscriptionOfferDuration: String, CaseIterable, Codable, Sendable {
    case threeDays = "THREE_DAYS"
    case oneWeek = "ONE_WEEK"
    case twoWeeks = "TWO_WEEKS"
    case oneMonth = "ONE_MONTH"
    case twoMonths = "TWO_MONTHS"
    case threeMonths = "THREE_MONTHS"
    case sixMonths = "SIX_MONTHS"
    case oneYear = "ONE_YEAR"

    var title: String {
        switch self {
        case .threeDays: L10n.text("3 days")
        case .oneWeek: L10n.text("1 week")
        case .twoWeeks: L10n.text("2 weeks")
        case .oneMonth: L10n.text("1 month")
        case .twoMonths: L10n.text("2 months")
        case .threeMonths: L10n.text("3 months")
        case .sixMonths: L10n.text("6 months")
        case .oneYear: L10n.text("1 year")
        }
    }
}

enum SubscriptionOfferCustomerEligibility: String, CaseIterable, Codable, Hashable, Sendable {
    case new = "NEW"
    case existing = "EXISTING"
    case expired = "EXPIRED"

    var title: String {
        switch self {
        case .new: L10n.text("New subscribers")
        case .existing: L10n.text("Existing subscribers")
        case .expired: L10n.text("Expired subscribers")
        }
    }
}

enum SubscriptionOfferCodeKind: String, CaseIterable, Codable, Sendable {
    case oneTime = "ONE_TIME"
    case custom = "CUSTOM"

    var title: String {
        switch self {
        case .oneTime: L10n.text("One-time-use codes")
        case .custom: L10n.text("Custom code")
        }
    }
}

struct SubscriptionOfferConfiguration: Equatable, Sendable {
    let referenceName: String
    let duration: SubscriptionOfferDuration
    let customerEligibilities: Set<SubscriptionOfferCustomerEligibility>
    let stackWithIntroductoryOffer: Bool
    let autoRenewEnabled: Bool
}

struct SubscriptionOfferCodeGenerationRequest: Equatable, Sendable {
    let productID: String
    let offer: SubscriptionOfferConfiguration
    let kind: SubscriptionOfferCodeKind
    let numberOfCodes: Int
    let expirationDate: Date?
    let customCode: String?
}

struct SubscriptionOfferCodeGenerationResult: Sendable {
    let offerID: String
    let batchID: String
    let customCode: String?
    let oneTimeCodeCSV: Data?
}

enum SubscriptionOfferCodeValidationError: LocalizedError {
    case missingReferenceName
    case missingEligibility
    case invalidBatchSize
    case invalidCustomCode
    case invalidExpirationDate

    var errorDescription: String? {
        switch self {
        case .missingReferenceName:
            L10n.text("Enter an internal offer reference name.")
        case .missingEligibility:
            L10n.text("Select at least one eligible subscriber type.")
        case .invalidBatchSize:
            L10n.text("One-time batches require 500–25,000 codes; custom-code batches require 1–25,000 redemptions.")
        case .invalidCustomCode:
            L10n.text("Custom codes must contain 1–64 letters or numbers without spaces or symbols.")
        case .invalidExpirationDate:
            L10n.text("The expiration date must be after today and no more than six months away.")
        }
    }
}

struct PublishingConfiguration: Sendable {
    let openAIAPIKey: String
    let openAIModel: String
    let appStoreConnectIssuerID: String
    let appStoreConnectKeyID: String
    let appStoreConnectPrivateKey: String
    let locale: String
    let copyright: String
    let supportURL: String
    let marketingURL: String?
    let termsURL: String?
    let privacyPolicyURL: String?
    let privacyChoicesURL: String?
    let appName: String?
    let subtitle: String?
    let licenseAgreementText: String?
    let review: AppStoreReviewConfiguration
    let manualMetadata: AppStoreMetadata?
    let screenshotPaths: [String]
    let replaceScreenshots: Bool
    let submitForReview: Bool
    let releaseAutomatically: Bool
}

struct PublishingResult: Sendable {
    let version: String
    let buildNumber: String
    let submittedForReview: Bool
}

struct PublishingProgress: Equatable {
    enum Phase: String, CaseIterable, Equatable, Sendable {
        case preparing
        case discoveringSubscriptions
        case generatingMetadata
        case collectingScreenshots
        case archiving
        case uploadingMetadata
        case configuringSubscriptions
        case uploadingScreenshots
        case uploadingBuild
        case waitingForBuild
        case submitting

        var title: String {
            switch self {
            case .preparing: L10n.text("Preparing App Store publication…")
            case .discoveringSubscriptions: L10n.text("Inspecting StoreKit subscriptions…")
            case .generatingMetadata: L10n.text("Generating App Store description…")
            case .collectingScreenshots: L10n.text("Collecting App Store screenshots…")
            case .archiving: L10n.text("Archiving and exporting the application…")
            case .uploadingMetadata: L10n.text("Updating App Store metadata…")
            case .configuringSubscriptions: L10n.text("Configuring App Store subscriptions…")
            case .uploadingScreenshots: L10n.text("Uploading App Store screenshots…")
            case .uploadingBuild: L10n.text("Uploading the build…")
            case .waitingForBuild: L10n.text("Waiting for App Store processing…")
            case .submitting: L10n.text("Submitting for App Review…")
            }
        }
    }

    let projectID: UUID
    let projectName: String
    var phase: Phase
    var latestOutput: String
}

enum PublishingEvent: Sendable {
    case phase(PublishingProgress.Phase)
    case output(String)
}

struct PublishingLogSession: Equatable, Identifiable {
    enum State: Equatable {
        case inProgress
        case succeeded
        case failed
        case cancelled
    }

    let id: UUID
    let projectName: String
    let startedAt: Date
    var phase: PublishingProgress.Phase
    var state: State
    private(set) var output: String

    init(projectName: String) {
        id = UUID()
        self.projectName = projectName
        startedAt = Date()
        phase = .preparing
        state = .inProgress
        output = ""
    }

    mutating func append(_ text: String) {
        guard !text.isEmpty else { return }
        output.append(text)
        if output.count > 50_000 {
            output = "…\n" + String(output.suffix(50_000))
        }
    }

    var latestOutputLine: String {
        output.split(whereSeparator: \Character.isNewline).last.map(String.init) ?? ""
    }
}
