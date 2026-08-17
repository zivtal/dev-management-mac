import Foundation

enum AppStoreLocale {
    static let supportedIdentifiers: Set<String> = [
        "ar-SA", "bn-BD", "ca", "cs", "da", "de-DE", "el", "en-AU", "en-CA", "en-GB",
        "en-US", "es-ES", "es-MX", "fi", "fr-CA", "fr-FR", "gu-IN", "he", "hi", "hr",
        "hu", "id", "it", "ja", "kn-IN", "ko", "ml-IN", "mr-IN", "ms", "nl-NL", "no",
        "or-IN", "pa-IN", "pl", "pt-BR", "pt-PT", "ro", "ru", "sk", "sl-SI", "sv",
        "ta-IN", "te-IN", "th", "tr", "uk", "ur-PK", "vi", "zh-Hans", "zh-Hant"
    ]

    private static let aliases: [String: String] = [
        "ar": "ar-SA", "arabic": "ar-SA",
        "bn": "bn-BD", "bangla": "bn-BD", "bengali": "bn-BD",
        "ca": "ca", "catalan": "ca",
        "cs": "cs", "czech": "cs",
        "da": "da", "danish": "da",
        "de": "de-DE", "german": "de-DE",
        "el": "el", "greek": "el",
        "en": "en-US", "english": "en-US", "english (australia)": "en-AU",
        "english (canada)": "en-CA", "english (u.k.)": "en-GB", "english (uk)": "en-GB",
        "english (u.s.)": "en-US", "english (us)": "en-US",
        "es": "es-ES", "spanish": "es-ES", "spanish (mexico)": "es-MX",
        "spanish (spain)": "es-ES",
        "fi": "fi", "finnish": "fi",
        "fr": "fr-FR", "french": "fr-FR", "french (canada)": "fr-CA",
        "gu": "gu-IN", "gujarati": "gu-IN",
        "he": "he", "hebrew": "he", "iw": "he",
        "hi": "hi", "hindi": "hi",
        "hr": "hr", "croatian": "hr",
        "hu": "hu", "hungarian": "hu",
        "id": "id", "indonesian": "id",
        "it": "it", "italian": "it",
        "ja": "ja", "japanese": "ja",
        "kn": "kn-IN", "kannada": "kn-IN",
        "ko": "ko", "korean": "ko",
        "ml": "ml-IN", "malayalam": "ml-IN",
        "mr": "mr-IN", "marathi": "mr-IN",
        "ms": "ms", "malay": "ms",
        "nl": "nl-NL", "dutch": "nl-NL",
        "no": "no", "nb": "no", "norwegian": "no",
        "or": "or-IN", "odia": "or-IN", "oriya": "or-IN",
        "pa": "pa-IN", "punjabi": "pa-IN",
        "pl": "pl", "polish": "pl",
        "pt": "pt-PT", "portuguese": "pt-PT", "portuguese (brazil)": "pt-BR",
        "portuguese (portugal)": "pt-PT",
        "ro": "ro", "romanian": "ro",
        "ru": "ru", "russian": "ru",
        "sk": "sk", "slovak": "sk",
        "sl": "sl-SI", "slovenian": "sl-SI",
        "sv": "sv", "swedish": "sv",
        "ta": "ta-IN", "tamil": "ta-IN",
        "te": "te-IN", "telugu": "te-IN",
        "th": "th", "thai": "th",
        "tr": "tr", "turkish": "tr",
        "uk": "uk", "ukrainian": "uk",
        "ur": "ur-PK", "urdu": "ur-PK",
        "vi": "vi", "vietnamese": "vi",
        "zh": "zh-Hans", "zh-cn": "zh-Hans", "chinese": "zh-Hans",
        "chinese (simplified)": "zh-Hans", "zh-tw": "zh-Hant",
        "chinese (traditional)": "zh-Hant"
    ]

    static func canonicalIdentifier(_ rawValue: String) -> String? {
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
        guard !normalized.isEmpty else { return nil }

        if let supported = supportedIdentifiers.first(where: {
            $0.caseInsensitiveCompare(normalized) == .orderedSame
        }) {
            return supported
        }
        let lowercased = normalized.lowercased()
        if let alias = aliases[lowercased] {
            return alias
        }
        guard let baseLanguage = lowercased.split(separator: "-").first else { return nil }
        return aliases[String(baseLanguage)]
    }
}

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

struct AppStoreLocalizedMetadata: Codable, Equatable, Sendable, Identifiable {
    var id: String { locale }

    var locale: String
    var appName: String
    var subtitle: String
    var description: String
    var keywords: String
    var promotionalText: String
    var whatsNew: String

    func normalized() -> AppStoreLocalizedMetadata {
        let metadata = AppStoreMetadata(
            description: description,
            keywords: keywords,
            promotionalText: promotionalText,
            whatsNew: whatsNew,
            subtitle: subtitle
        ).normalized()
        return AppStoreLocalizedMetadata(
            locale: locale.replacingOccurrences(of: "_", with: "-"),
            appName: String(appName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30)),
            subtitle: metadata.subtitle ?? "",
            description: metadata.description,
            keywords: metadata.keywords,
            promotionalText: metadata.promotionalText,
            whatsNew: metadata.whatsNew
        )
    }

    func metadata(primaryCategory: String?, secondaryCategory: String?) -> AppStoreMetadata {
        AppStoreMetadata(
            description: description,
            keywords: keywords,
            promotionalText: promotionalText,
            whatsNew: whatsNew,
            subtitle: subtitle.nilIfEmpty,
            primaryCategory: primaryCategory,
            secondaryCategory: secondaryCategory
        ).normalized()
    }
}

struct AppStoreGeneratedMetadata: Codable, Equatable, Sendable {
    var primaryCategory: String
    var secondaryCategory: String
    var localizations: [AppStoreLocalizedMetadata]
    var compliance: AppStoreComplianceDraft

    func normalized() -> AppStoreGeneratedMetadata {
        var seen = Set<String>()
        return AppStoreGeneratedMetadata(
            primaryCategory: primaryCategory,
            secondaryCategory: secondaryCategory,
            localizations: localizations
                .compactMap { localization -> AppStoreLocalizedMetadata? in
                    guard let locale = AppStoreLocale.canonicalIdentifier(localization.locale),
                          seen.insert(locale.lowercased()).inserted else {
                        return nil
                    }
                    var normalized = localization.normalized()
                    normalized.locale = locale
                    return normalized
                },
            compliance: compliance
        )
    }
}

struct AppStorePrivacyDraft: Codable, Equatable, Sendable {
    var collectsData: Bool
    var dataTypes: [String]
    var notes: [String]
}

struct AppStoreComplianceDraft: Codable, Equatable, Sendable {
    var contentRightsDeclaration: String
    var appIsFree: Bool
    var demoAccountRequired: Bool
    var copyright: String
    var ageRating: [String: AppStoreManifestValue]
    var ageRatingEvidenceSufficient: Bool
    var privacy: AppStorePrivacyDraft
    var privacyEvidenceSufficient: Bool
    var evidence: [String]
    var confidence: Double

    var ageRatingDefaultingUnknownToNo: [String: AppStoreManifestValue] {
        AppStoreAgeRatingAnswerPolicy.answersDefaultingUnknownToNo(ageRating)
    }

    var evidenceBackedPrivacy: AppStorePrivacyDraft? {
        privacyEvidenceSufficient ? privacy : nil
    }
}

struct AppStorePrivacyAttestation: Codable, Equatable, Sendable {
    var confirmedBy: String?
    var confirmedAt: String?
    var projectFingerprint: String?
    var automaticPublishingAuthorizedAt: String? = nil
    var publishedAt: String? = nil
}

struct AppStoreComplianceConfiguration: Codable, Equatable, Sendable {
    var privacyDraft: AppStorePrivacyDraft?
    var privacyAttestation: AppStorePrivacyAttestation?
    var evidence: [String]?
    var confidence: Double?
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

enum AppStoreAgeRatingAnswerPolicy {
    private static let booleanKeys = [
        "advertising", "gambling", "healthOrWellnessTopics", "lootBox",
        "messagingAndChat", "parentalControls", "ageAssurance", "socialMedia",
        "socialMediaAgeRestricted", "unrestrictedWebAccess", "userGeneratedContent"
    ]
    private static let frequencyKeys = [
        "alcoholTobaccoOrDrugUseOrReferences", "contests", "gamblingSimulated",
        "gunsOrOtherWeapons", "medicalOrTreatmentInformation", "profanityOrCrudeHumor",
        "sexualContentGraphicAndNudity", "sexualContentOrNudity", "horrorOrFearThemes",
        "matureOrSuggestiveThemes", "violenceCartoonOrFantasy",
        "violenceRealisticProlongedGraphicOrSadistic", "violenceRealistic"
    ]

    static func hasCompleteAnswers(_ answers: [String: AppStoreManifestValue]) -> Bool {
        booleanKeys.allSatisfy { key in
            if case .bool = answers[key] { return true }
            return false
        } && frequencyKeys.allSatisfy { key in
            if case .string(let answer) = answers[key] {
                return ["NONE", "INFREQUENT", "FREQUENT"].contains(answer)
            }
            return false
        }
    }

    static func answersDefaultingUnknownToNo(
        _ answers: [String: AppStoreManifestValue]
    ) -> [String: AppStoreManifestValue] {
        var completed: [String: AppStoreManifestValue] = [:]
        for key in booleanKeys {
            if case .bool(let value) = answers[key] {
                completed[key] = .bool(value)
            } else {
                completed[key] = .bool(false)
            }
        }
        for key in frequencyKeys {
            if case .string(let value) = answers[key],
               ["NONE", "INFREQUENT", "FREQUENT"].contains(value) {
                completed[key] = .string(value)
            } else {
                completed[key] = .string("NONE")
            }
        }
        return completed
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

    func normalizingLocale() -> AppStoreSubscriptionLocalization {
        var normalized = self
        normalized.locale = AppStoreLocale.canonicalIdentifier(locale)
            ?? locale.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "_", with: "-")
        return normalized
    }
}

struct AppStoreSubscriptionDefinition: Codable, Equatable, Sendable {
    var referenceName: String
    var productID: String
    var period: String
    var basePrice: String?
    var baseTerritory: String?
    var territoryPrices: [String: String]? = nil
    var availableInAllTerritories: Bool?
    var familySharable: Bool?
    var groupLevel: Int?
    var reviewNote: String?
    var reviewScreenshot: String?
    var localizations: [AppStoreSubscriptionLocalization]?
}

struct AppStoreTestFlightConfiguration: Codable, Equatable, Sendable {
    var groupName: String?
    var feedbackEmail: String?
    var reviewNotes: String?
    var internalTesterEmails: [String]?
}

struct AppStoreSubscriptionGroupDefinition: Codable, Equatable, Sendable {
    var referenceName: String
    var localizations: [AppStoreSubscriptionLocalization]?
    var subscriptions: [AppStoreSubscriptionDefinition]
}

struct AppStoreSubscriptionsConfiguration: Codable, Equatable, Sendable {
    var baseTerritory: String?
    var availableInAllTerritories: Bool?
    var familySharable: Bool? = nil
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
    var releaseAutomatically: Bool?
    var metadata: AppStoreMetadata?
    var localizations: [AppStoreLocalizedMetadata]? = nil
    var screenshotPaths: [String]?
    var reviewAttachmentPaths: [String]? = nil
    var replaceScreenshots: Bool? = nil
    var review: AppStoreReviewManifestConfiguration?
    var testFlight: AppStoreTestFlightConfiguration? = nil
}

struct AppStorePublishingManifest: Codable, Equatable, Sendable {
    var schemaVersion: Int?
    var publication: AppStorePublicationConfiguration?
    var application: AppStoreApplicationConfiguration?
    var subscriptions: AppStoreSubscriptionsConfiguration?
    var compliance: AppStoreComplianceConfiguration? = nil
}

struct AppStoreSubscriptionCatalog: Equatable, Sendable {
    var publication: AppStorePublicationConfiguration?
    var application: AppStoreApplicationConfiguration?
    var compliance: AppStoreComplianceConfiguration?
    var groups: [AppStoreSubscriptionGroupDefinition]
    var detectedProductIDs: Set<String>
    var sourceFiles: [String]
    var projectDirectory: URL

    var subscriptionCount: Int {
        max(
            groups.reduce(0) { $0 + $1.subscriptions.count },
            detectedProductIDs.count
        )
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
    let territoryIDs: [String]
    let appLocalizations: [AppStoreConnectAppLocalizationSnapshot]
    let version: AppStoreConnectVersionSnapshot?
    let testFlightBuild: AppStoreConnectBuildReference?
    let activeReviewVersion: AppStoreConnectVersionReferenceSnapshot?
    let hasReadyForDistributionVersion: Bool
    let subscriptionGroups: [AppStoreConnectSubscriptionGroupSnapshot]
    let loadedAt: Date
}

struct AppStoreConnectVersionReferenceSnapshot: Equatable, Sendable {
    let id: String
    let versionString: String
    let state: String
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

    var isActivelyInReview: Bool {
        AppStoreVersionLifecycle.isCancellableReviewState(state)
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

struct AppStoreConnectBuildReference: Equatable, Sendable {
    let id: String
    let version: String
    let buildNumber: String
    let processingState: String

    var isProcessed: Bool {
        processingState == "VALID"
    }
}

enum AppStoreVersionLifecycle {
    static let cancellableReviewStates: Set<String> = [
        "WAITING_FOR_REVIEW",
        "IN_REVIEW"
    ]

    static let reusableDraftStates: Set<String> = [
        "PREPARE_FOR_SUBMISSION",
        "READY_FOR_REVIEW",
        "INVALID_BINARY",
        "REJECTED",
        "METADATA_REJECTED",
        "DEVELOPER_REJECTED"
    ]

    static let readyForDistributionStates: Set<String> = [
        "READY_FOR_DISTRIBUTION",
        "READY_FOR_SALE",
        "PREORDER_READY_FOR_SALE"
    ]

    static let statesBlockingNewStorefront: Set<String> = [
        "ACCEPTED",
        "WAITING_FOR_EXPORT_COMPLIANCE",
        "WAITING_FOR_REVIEW",
        "IN_REVIEW",
        "PENDING_APPLE_RELEASE",
        "PENDING_DEVELOPER_RELEASE",
        "PROCESSING_FOR_DISTRIBUTION",
        "PROCESSING_FOR_APP_STORE"
    ]

    static func isCancellableReviewState(_ state: String) -> Bool {
        cancellableReviewStates.contains(state)
    }

    static func isReadyForDistributionState(_ state: String) -> Bool {
        readyForDistributionStates.contains(state)
    }

    static func isReusableDraftState(_ state: String) -> Bool {
        reusableDraftStates.contains(state)
    }

    static func blocksNewStorefront(_ state: String) -> Bool {
        statesBlockingNewStorefront.contains(state)
    }
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

struct AppStoreConnectOfferCodeDetailSnapshot: Equatable, Sendable {
    let offerID: String
    let appID: String
    let oneTimeBatches: [AppStoreConnectOneTimeCodeBatchSnapshot]
    let customBatches: [AppStoreConnectCustomCodeBatchSnapshot]
}

struct AppStoreConnectOneTimeCodeBatchSnapshot: Equatable, Sendable, Identifiable {
    let id: String
    let numberOfCodes: Int
    let createdDate: String?
    let expirationDate: String?
    let active: Bool
    let environment: String?
    let codes: [String]
}

struct AppStoreConnectCustomCodeBatchSnapshot: Equatable, Sendable, Identifiable {
    let id: String
    let customCode: String
    let numberOfCodes: Int
    let createdDate: String?
    let expirationDate: String?
    let active: Bool
    let redemptionURL: URL?
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

enum SubscriptionOfferCodeBatchSize {
    static let productionRange = 500...25_000

    static func isValid(_ numberOfCodes: Int) -> Bool {
        productionRange.contains(numberOfCodes)
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
    let redemptionURL: URL?
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
            L10n.text("Production batches require 500–25,000 codes or redemptions.")
        case .invalidCustomCode:
            L10n.text("Custom codes must contain 1–64 letters or numbers without spaces or symbols.")
        case .invalidExpirationDate:
            L10n.text("The expiration date must be after today and no more than six months away.")
        }
    }
}

enum SubscriptionOfferCodeExpiration {
    private static var appStoreCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")
            ?? TimeZone(secondsFromGMT: -8)!
        return calendar
    }

    static func earliestDate(
        from referenceDate: Date = Date(),
        calendar: Calendar = .current
    ) -> Date {
        boundaryDate(
            byAdding: .day,
            value: 1,
            to: referenceDate,
            displayCalendar: calendar
        )
    }

    static func latestDate(
        from referenceDate: Date = Date(),
        calendar: Calendar = .current
    ) -> Date {
        boundaryDate(
            byAdding: .month,
            value: 6,
            to: referenceDate,
            displayCalendar: calendar
        )
    }

    static func isValid(
        _ expirationDate: Date?,
        relativeTo referenceDate: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        guard let expirationDate else { return false }
        let expirationDay = calendar.startOfDay(for: expirationDate)
        return earliestDate(from: referenceDate, calendar: calendar)...latestDate(
            from: referenceDate,
            calendar: calendar
        ) ~= expirationDay
    }

    private static func boundaryDate(
        byAdding component: Calendar.Component,
        value: Int,
        to referenceDate: Date,
        displayCalendar: Calendar
    ) -> Date {
        let appStoreToday = appStoreCalendar.startOfDay(for: referenceDate)
        let appStoreBoundary = appStoreCalendar.date(
            byAdding: component,
            value: value,
            to: appStoreToday
        ) ?? appStoreToday
        let components = appStoreCalendar.dateComponents(
            [.year, .month, .day],
            from: appStoreBoundary
        )
        return displayCalendar.date(from: components)
            ?? displayCalendar.startOfDay(for: appStoreBoundary)
    }
}

enum PublishingIntent: Equatable, Sendable {
    case publish
    case testFlight

    var submitsForReview: Bool {
        self == .publish
    }

    func preservesLockedAppInformation(forHTTPStatus status: Int) -> Bool {
        self == .testFlight && status == 409
    }
}

struct PublishingConfiguration: Sendable {
    let intent: PublishingIntent
    let appStoreConnectIssuerID: String
    let appStoreConnectKeyID: String
    let appStoreConnectPrivateKey: String
    let appStorePrivacyAppleID: String?
    let appStorePrivacyTeamID: String?
    let appStorePrivacyFastlaneSession: String?
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
    let manualLocalizations: [AppStoreLocalizedMetadata]
    let screenshotPaths: [String]
    let reviewAttachmentPaths: [String]
    let replaceScreenshots: Bool
    let releaseAutomatically: Bool
    let replaceActiveReviewVersion: Bool
    let testFlight: AppStoreTestFlightConfiguration?
}

struct PublishingResult: Equatable, Sendable {
    let version: String
    let buildNumber: String
    let intent: PublishingIntent
    let reusedExistingBuild: Bool
    let deferredStorefrontSetup: Bool

    var submittedForReview: Bool {
        intent.submitsForReview
    }
}

struct AppStoreBuildArtifact: Equatable, Sendable {
    let ipaURL: URL
    let archiveURL: URL
    let bundleIdentifier: String
    let version: String
    let buildNumber: String
}

struct PublishingProgress: Equatable {
    enum Phase: String, CaseIterable, Equatable, Sendable {
        case preparing
        case discoveringSubscriptions
        case publishingPrivacy
        case generatingMetadata
        case collectingScreenshots
        case archiving
        case uploadingMetadata
        case configuringSubscriptions
        case uploadingScreenshots
        case uploadingBuild
        case waitingForBuild
        case configuringTestFlight
        case uploadingReviewAssets
        case submitting

        var title: String {
            switch self {
            case .preparing: L10n.text("Preparing App Store publication…")
            case .discoveringSubscriptions: L10n.text("Inspecting StoreKit subscriptions…")
            case .publishingPrivacy: L10n.text("Publishing App Privacy answers…")
            case .generatingMetadata: L10n.text("Generating App Store description…")
            case .collectingScreenshots: L10n.text("Collecting App Store screenshots…")
            case .archiving: L10n.text("Archiving and exporting the application…")
            case .uploadingMetadata: L10n.text("Updating App Store metadata…")
            case .configuringSubscriptions: L10n.text("Configuring App Store subscriptions…")
            case .uploadingScreenshots: L10n.text("Uploading App Store screenshots…")
            case .uploadingBuild: L10n.text("Uploading the build…")
            case .waitingForBuild: L10n.text("Waiting for App Store processing…")
            case .configuringTestFlight: L10n.text("Making the build available in TestFlight…")
            case .uploadingReviewAssets: L10n.text("Uploading App Review attachments…")
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
    let projectID: UUID
    let projectName: String
    let startedAt: Date
    var phase: PublishingProgress.Phase
    var state: State
    var finishedAt: Date?
    var result: PublishingResult?
    var failureMessage: String?
    private(set) var output: String

    init(projectID: UUID, projectName: String) {
        id = UUID()
        self.projectID = projectID
        self.projectName = projectName
        startedAt = Date()
        phase = .preparing
        state = .inProgress
        finishedAt = nil
        result = nil
        failureMessage = nil
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
