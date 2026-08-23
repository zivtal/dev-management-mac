import ImageIO
import Foundation
import Security

enum AppStorePublishingError: LocalizedError {
    case busy
    case unsupportedProject
    case missingBundleIdentifier
    case missingVersion
    case missingBuildNumber
    case missingProjectContainer
    case missingArchiveApplication
    case archiveBundleIdentifierMismatch(String, String)
    case archiveVersionMismatch(expected: String, actual: String)
    case archiveBuildNumberMismatch(expected: String, actual: String)
    case noIPA
    case noScreenshots
    case noSimulatorApplication
    case uploaderUnavailable
    case uploadTransferFailed(Int)
    case missingEditablePublishingDraft
    case privacyManifestUnavailable
    case distributionSigningUnavailable

    var errorDescription: String? {
        switch self {
        case .busy:
            return L10n.text("Another build, installation, publication, or offer-code request is already in progress.")
        case .unsupportedProject:
            return L10n.text("App Store publishing requires a managed iOS application.")
        case .missingBundleIdentifier:
            return L10n.text("The selected Xcode scheme does not provide an application bundle identifier.")
        case .missingVersion:
            return L10n.text("The selected Xcode scheme does not provide a marketing version.")
        case .missingBuildNumber:
            return L10n.text("The selected Xcode scheme does not provide a build number.")
        case .missingProjectContainer:
            return L10n.text("The saved Xcode project or workspace no longer exists.")
        case .missingArchiveApplication:
            return L10n.text("Xcode created an archive, but its iOS application metadata could not be read.")
        case .archiveBundleIdentifierMismatch(let expected, let actual):
            return L10n.format("The archived app uses bundle identifier %@ instead of %@.", actual, expected)
        case .archiveVersionMismatch(let expected, let actual):
            return L10n.format(
                "The archive changed the marketing version from %@ to %@. Publication stopped without uploading it.",
                expected,
                actual
            )
        case .archiveBuildNumberMismatch(let expected, let actual):
            return L10n.format(
                "The archive changed the build number from %@ to %@. Publication stopped without uploading it.",
                expected,
                actual
            )
        case .noIPA:
            return L10n.text("Xcode exported the archive, but no .ipa file was found.")
        case .noScreenshots:
            return L10n.text("The Simulator screenshot was captured, but its dimensions are not accepted by App Store Connect.")
        case .noSimulatorApplication:
            return L10n.text("The simulator build completed, but its application product was not found.")
        case .uploaderUnavailable:
            return L10n.text("Apple's App Store upload tool was not found in the selected Xcode installation.")
        case .uploadTransferFailed(let attempts):
            return L10n.format(
                "Apple's upload tool repeatedly lost or corrupted the transfer. The upload was stopped after %d attempts. Check the network connection and try again; the validated IPA is not the cause of this failure.",
                attempts
            )
        case .missingEditablePublishingDraft:
            return L10n.text("Review and save the editable App Store listing and app declarations before releasing.")
        case .privacyManifestUnavailable:
            return L10n.text("App Privacy was published, but app-store-publishing.json could not be updated with the publication time.")
        case .distributionSigningUnavailable:
            return L10n.text("Distribution signing is not available. Development Management signs App Store builds with a local Apple Distribution identity and explicit distribution profiles; it never uses Xcode cloud signing. Use an Account Holder or Admin App Store Connect API key with Certificates, Identifiers & Profiles access, or import an Apple Distribution certificate with its private key. No archive was uploaded.")
        }
    }
}

final class AppStorePublishingService {
    typealias EventHandler = @Sendable (PublishingEvent) -> Void
    typealias ScreenshotPreviewHandler = @Sendable (AppStoreScreenshotPreview) -> Void

    private let processRunner: ProcessRunner
    private let fileManager: FileManager
    private let subscriptionDiscoveryService: StoreKitSubscriptionDiscoveryService
    private let reviewAssetService: AppStoreReviewAssetService
    private let publicationURLValidator: AppStorePublicationURLValidator
    private let xcodeGenPreparationService: XcodeGenProjectPreparationService
    private let xcodeSchemePreparationService: XcodeSchemeBuildPreparationService
    private let privacyPublishingService: AppStorePrivacyPublishingService
    private let distributionCertificateProvisioningService: DistributionCertificateProvisioningService
    private let provisioningProfileService: AppStoreProvisioningProfileService

    init(
        processRunner: ProcessRunner = ProcessRunner(),
        fileManager: FileManager = .default,
        subscriptionDiscoveryService: StoreKitSubscriptionDiscoveryService = StoreKitSubscriptionDiscoveryService(),
        reviewAssetService: AppStoreReviewAssetService = AppStoreReviewAssetService(),
        publicationURLValidator: AppStorePublicationURLValidator = AppStorePublicationURLValidator(),
        distributionCertificateProvisioningService: DistributionCertificateProvisioningService = .shared,
        provisioningProfileService: AppStoreProvisioningProfileService = .shared
    ) {
        self.processRunner = processRunner
        self.fileManager = fileManager
        self.subscriptionDiscoveryService = subscriptionDiscoveryService
        self.reviewAssetService = reviewAssetService
        self.publicationURLValidator = publicationURLValidator
        self.distributionCertificateProvisioningService = distributionCertificateProvisioningService
        self.provisioningProfileService = provisioningProfileService
        self.xcodeGenPreparationService = XcodeGenProjectPreparationService(
            processRunner: processRunner,
            fileManager: fileManager
        )
        self.xcodeSchemePreparationService = XcodeSchemeBuildPreparationService(
            fileManager: fileManager
        )
        self.privacyPublishingService = AppStorePrivacyPublishingService(
            processRunner: processRunner,
            fileManager: fileManager
        )
    }

    func publish(
        project: ManagedProject,
        configuration: PublishingConfiguration,
        eventHandler: @escaping EventHandler
    ) async throws -> PublishingResult {
        let intent = configuration.intent
        guard !project.isMacOSApplication else {
            throw AppStorePublishingError.unsupportedProject
        }
        guard let bundleIdentifier = project.bundleIdentifier, !bundleIdentifier.isEmpty else {
            throw AppStorePublishingError.missingBundleIdentifier
        }
        guard fileManager.fileExists(atPath: project.containerPath) else {
            throw AppStorePublishingError.missingProjectContainer
        }
        guard let localVersion = project.marketingVersion?.nilIfEmpty else {
            throw AppStorePublishingError.missingVersion
        }
        guard let localBuildNumber = project.buildNumber?.nilIfEmpty else {
            throw AppStorePublishingError.missingBuildNumber
        }

        let appStoreConnect = try AppStoreConnectService(
            issuerID: configuration.appStoreConnectIssuerID,
            keyID: configuration.appStoreConnectKeyID,
            privateKeyPEM: configuration.appStoreConnectPrivateKey
        )
        let appID = try await appStoreConnect.applicationID(bundleIdentifier: bundleIdentifier)
        let existingBuild = try await appStoreConnect.build(
            appID: appID,
            marketingVersion: localVersion,
            buildNumber: localBuildNumber
        )
        var reusedExistingBuild = existingBuild != nil
        if let existingBuild {
            eventHandler(.output(L10n.format(
                "Reusing TestFlight build %@ (%@); archive and upload are not needed.\n",
                existingBuild.version,
                existingBuild.buildNumber
            )))
        }

        var temporaryDirectory: URL?
        defer {
            if let temporaryDirectory {
                try? fileManager.removeItem(at: temporaryDirectory)
            }
        }

        eventHandler(.phase(.discoveringSubscriptions))
        let subscriptionCatalog = try subscriptionDiscoveryService.discover(
            project: project,
            defaultLocale: configuration.locale
        )
        guard let privacyAttestation = subscriptionCatalog.compliance?.privacyAttestation,
              privacyAttestation.confirmedBy?.nilIfEmpty != nil,
              privacyAttestation.confirmedAt?.nilIfEmpty != nil else {
            throw AppStorePublishingError.missingEditablePublishingDraft
        }

        if Self.requiresReachablePublicationURLs(for: intent) {
            let publicationURLs = Self.publicationURLs(configuration: configuration)
            eventHandler(.output(L10n.format(
                "Validating %d public App Store URL(s) before publishing…\n",
                publicationURLs.count
            )))
            try await publicationURLValidator.validate(publicationURLs)
            eventHandler(.output(L10n.text("All configured public App Store URLs are reachable.\n")))
        }

        if privacyAttestation.automaticPublishingAuthorizedAt?.nilIfEmpty != nil,
           privacyAttestation.publishedAt?.nilIfEmpty == nil {
            guard let privacyDraft = subscriptionCatalog.compliance?.privacyDraft else {
                throw AppStorePublishingError.missingEditablePublishingDraft
            }
            eventHandler(.phase(.publishingPrivacy))
            try await privacyPublishingService.publish(
                draft: privacyDraft,
                bundleIdentifier: bundleIdentifier,
                appleID: configuration.appStorePrivacyAppleID,
                teamID: configuration.appStorePrivacyTeamID,
                session: configuration.appStorePrivacyFastlaneSession,
                onOutput: { eventHandler(.output($0)) }
            )
            try recordPrivacyPublication(
                catalog: subscriptionCatalog,
                publishedAt: ISO8601DateFormatter().string(from: Date())
            )
        } else if privacyAttestation.publishedAt?.nilIfEmpty != nil {
            eventHandler(.output(L10n.text("The reviewed App Privacy answers are already published.\n")))
        } else {
            eventHandler(.output(L10n.text("The App Privacy answers were previously confirmed manually in App Store Connect.\n")))
        }
        if subscriptionCatalog.detectedProductIDs.isEmpty {
            eventHandler(.output(L10n.text("No subscription products were found in the app project.\n")))
        } else {
            eventHandler(.output(L10n.format(
                "Detected %d subscription product(s) in the app project.\n",
                subscriptionCatalog.detectedProductIDs.count
            )))
            if !subscriptionCatalog.sourceFiles.isEmpty {
                eventHandler(.output(L10n.format(
                    "Subscription configuration: %@.\n",
                    subscriptionCatalog.sourceFiles.joined(separator: ", ")
                )))
            }
        }

        let reviewAttachments = reviewAssetService.discover(
            project: project,
            configuredPaths: configuration.reviewAttachmentPaths
        )
        if !reviewAttachments.isEmpty {
            eventHandler(.output(L10n.format(
                "Prepared %d App Review attachment(s) from the project.\n",
                reviewAttachments.count
            )))
        }

        eventHandler(.phase(.generatingMetadata))
        var metadata: AppStoreMetadata
        var localizedMetadata: [AppStoreLocalizedMetadata]
        if !configuration.manualLocalizations.isEmpty {
            localizedMetadata = Self.normalizedLocalizedMetadata(configuration.manualLocalizations)
            let ignoredLocalizationCount = configuration.manualLocalizations.count - localizedMetadata.count
            if ignoredLocalizationCount > 0 {
                eventHandler(.output(L10n.format(
                    "Ignored %lld duplicate or unsupported localized listing(s) after App Store locale normalization.\n",
                    Int64(ignoredLocalizationCount)
                )))
            }
            guard !localizedMetadata.isEmpty else {
                throw AppStorePublishingError.missingEditablePublishingDraft
            }
            let preferredLocale = AppStoreLocale.canonicalIdentifier(configuration.locale)
                ?? configuration.locale
            let preferred = localizedMetadata.first(where: {
                $0.locale.caseInsensitiveCompare(preferredLocale) == .orderedSame
            }) ?? localizedMetadata[0]
            metadata = preferred.metadata(
                primaryCategory: configuration.manualMetadata?.primaryCategory,
                secondaryCategory: configuration.manualMetadata?.secondaryCategory
            )
            eventHandler(.output(L10n.format(
                "Using manually configured App Store metadata for %d language(s).\n",
                localizedMetadata.count
            )))
        } else if let manualMetadata = configuration.manualMetadata {
            metadata = manualMetadata.normalized()
            localizedMetadata = [
                AppStoreLocalizedMetadata(
                    locale: configuration.locale,
                    appName: configuration.appName ?? project.displayName,
                    subtitle: configuration.subtitle ?? metadata.subtitle ?? "",
                    description: metadata.description,
                    keywords: metadata.keywords,
                    promotionalText: metadata.promotionalText,
                    whatsNew: metadata.whatsNew
                ).normalized()
            ]
            eventHandler(.output(L10n.text("Using manually configured per-app App Store metadata.\n")))
        } else {
            throw AppStorePublishingError.missingEditablePublishingDraft
        }
        eventHandler(.output(L10n.text(
            "Using the saved What’s New text exactly as reviewed; Publish does not generate or replace it.\n"
        )))
        var applicationConfiguration = subscriptionCatalog.application
        if applicationConfiguration == nil,
           metadata.primaryCategory?.nilIfEmpty != nil || metadata.secondaryCategory?.nilIfEmpty != nil {
            applicationConfiguration = AppStoreApplicationConfiguration(
                primaryCategory: metadata.primaryCategory?.nilIfEmpty,
                secondaryCategory: metadata.secondaryCategory?.nilIfEmpty,
                contentRightsDeclaration: nil,
                isFree: nil,
                baseTerritory: nil,
                availableInAllTerritories: nil,
                ageRating: nil
            )
        } else {
            if applicationConfiguration?.primaryCategory?.nilIfEmpty == nil {
                applicationConfiguration?.primaryCategory = metadata.primaryCategory?.nilIfEmpty
            }
            if applicationConfiguration?.secondaryCategory?.nilIfEmpty == nil {
                applicationConfiguration?.secondaryCategory = metadata.secondaryCategory?.nilIfEmpty
            }
        }
        guard applicationConfiguration?.primaryCategory?.nilIfEmpty != nil,
              applicationConfiguration?.contentRightsDeclaration?.nilIfEmpty != nil,
              applicationConfiguration?.isFree != nil,
              AppStoreAgeRatingAnswerPolicy.hasCompleteAnswers(
                  applicationConfiguration?.ageRating ?? [:]
              ) else {
            throw AppStorePublishingError.missingEditablePublishingDraft
        }

        eventHandler(.phase(.collectingScreenshots))
        let screenshots = try await collectScreenshots(
            project: project,
            configuredPaths: configuration.screenshotPaths,
            eventHandler: eventHandler
        )
        if screenshots.isEmpty {
            eventHandler(.output(L10n.text("No new screenshot was available; existing App Store Connect screenshots will be preserved.\n")))
        } else {
            eventHandler(.output(L10n.format("Prepared %d App Store screenshot(s).\n", screenshots.count)))
        }

        let artifact: AppStoreBuildArtifact?
        let targetVersion: String
        let targetBuildNumber: String
        if existingBuild != nil {
            artifact = nil
            targetVersion = localVersion
            targetBuildNumber = localBuildNumber
        } else {
            let signingTeamID = project.signingTeamID ?? project.projectSigningTeamID
            // Check the application's identifier before creating any certificate. A
            // missing identifier should cost only an API request, not consume signing
            // state that cannot yet be used. Embedded bundle IDs are checked after the
            // archive because they cannot be enumerated reliably before then.
            try await provisioningProfileService.preflight(
                bundleIdentifiers: [bundleIdentifier],
                issuerID: configuration.appStoreConnectIssuerID,
                keyID: configuration.appStoreConnectKeyID,
                privateKeyPEM: configuration.appStoreConnectPrivateKey
            )
            // Resolved before archiving: without a usable local distribution identity
            // the export can never succeed, and a Release archive is expensive.
            let signingIdentity = try await distributionCertificateProvisioningService
                .prepareLocalIdentity(
                    teamID: signingTeamID,
                    issuerID: configuration.appStoreConnectIssuerID,
                    keyID: configuration.appStoreConnectKeyID,
                    privateKeyPEM: configuration.appStoreConnectPrivateKey,
                    onOutput: { eventHandler(.output($0)) }
                )
            let directory = fileManager.temporaryDirectory
                .appendingPathComponent("DevManagement-Publish-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            temporaryDirectory = directory

            eventHandler(.phase(.archiving))
            let archived = try await archiveAndExport(
                project: project,
                expectedBundleIdentifier: bundleIdentifier,
                signingIdentity: signingIdentity,
                issuerID: configuration.appStoreConnectIssuerID,
                keyID: configuration.appStoreConnectKeyID,
                privateKey: configuration.appStoreConnectPrivateKey,
                temporaryDirectory: directory,
                eventHandler: eventHandler
            )
            artifact = archived
            targetVersion = archived.version
            targetBuildNumber = archived.buildNumber
            eventHandler(.output(L10n.format(
                "Archive contains %@ %@ (%@).\n",
                archived.bundleIdentifier,
                archived.version,
                archived.buildNumber
            )))
            guard archived.version == localVersion else {
                throw AppStorePublishingError.archiveVersionMismatch(
                    expected: localVersion,
                    actual: archived.version
                )
            }
            guard archived.buildNumber == localBuildNumber else {
                throw AppStorePublishingError.archiveBuildNumberMismatch(
                    expected: localBuildNumber,
                    actual: archived.buildNumber
                )
            }
            if try await appStoreConnect.build(
                appID: appID,
                marketingVersion: archived.version,
                buildNumber: archived.buildNumber
            ) != nil {
                reusedExistingBuild = true
                eventHandler(.output(L10n.format(
                    "TestFlight already contains archived build %@ (%@); skipping the duplicate upload.\n",
                    archived.version,
                    archived.buildNumber
                )))
            }
        }

        let processedExistingBuildID: String?
        if reusedExistingBuild {
            eventHandler(.output(L10n.text("Confirming that the matching TestFlight build finished processing before changing the App Store version…\n")))
            processedExistingBuildID = try await appStoreConnect.waitForBuild(
                appID: appID,
                marketingVersion: targetVersion,
                buildNumber: targetBuildNumber,
                onOutput: { eventHandler(.output($0)) }
            )
        } else {
            processedExistingBuildID = nil
        }

        let reusableVersionID: String?
        if intent == .publish, configuration.replaceActiveReviewVersion {
            eventHandler(.phase(.uploadingMetadata))
            reusableVersionID = try await appStoreConnect.cancelActiveAppVersionReview(
                bundleIdentifier: bundleIdentifier,
                replacingWith: targetVersion,
                onOutput: { eventHandler(.output($0)) }
            )
        } else {
            reusableVersionID = nil
        }

        eventHandler(.phase(.uploadingMetadata))
        eventHandler(.output(L10n.text("Finding the application and editable version in App Store Connect…\n")))
        let publication = try await appStoreConnect.preparePublication(
            bundleIdentifier: bundleIdentifier,
            version: targetVersion,
            intent: intent,
            locale: configuration.locale,
            metadata: metadata,
            localizedMetadata: localizedMetadata,
            copyright: configuration.copyright,
            supportURL: configuration.supportURL,
            marketingURL: configuration.marketingURL,
            termsURL: configuration.termsURL,
            appName: configuration.appName,
            subtitle: configuration.subtitle,
            privacyPolicyURL: configuration.privacyPolicyURL,
            privacyChoicesURL: configuration.privacyChoicesURL,
            licenseAgreementText: configuration.licenseAgreementText,
            review: configuration.review,
            releaseAutomatically: configuration.releaseAutomatically,
            reusableVersionID: reusableVersionID,
            onOutput: { eventHandler(.output($0)) }
        )
        if !publication.deferredStorefrontSetup {
            eventHandler(.output(L10n.text(publication.preservedLockedAppInformation
                ? "Editable App Store version metadata updated; locked app-level information was preserved.\n"
                : "App Store metadata updated.\n")))
        }

        eventHandler(.phase(.configuringTestFlight))
        try await appStoreConnect.configureTestFlightInformation(
            appID: publication.appID,
            listings: localizedMetadata,
            configuration: configuration.testFlight,
            marketingURL: configuration.marketingURL,
            privacyPolicyURL: configuration.privacyPolicyURL,
            review: configuration.review,
            onOutput: { eventHandler(.output($0)) }
        )

        var storefrontConfigurationIsLocked = publication.preservedLockedAppInformation
        if storefrontConfigurationIsLocked {
            eventHandler(.output(L10n.text("App Store Connect has locked app-level declarations in its current state; keeping the existing categories, rights, age rating, price, and availability for this TestFlight upload.\n")))
        } else {
            do {
                try await appStoreConnect.configureFirstPublication(
                    appID: publication.appID,
                    configuration: applicationConfiguration,
                    onOutput: { eventHandler(.output($0)) }
                )
            } catch AppStoreConnectError.requestFailed(let status, _)
                where intent.preservesLockedAppInformation(forHTTPStatus: status) {
                storefrontConfigurationIsLocked = true
                eventHandler(.output(L10n.text("App Store Connect has locked app-level declarations in its current state; keeping the existing categories, rights, age rating, price, and availability for this TestFlight upload.\n")))
            }
        }

        eventHandler(.phase(.configuringSubscriptions))
        let subscriptionReviewItems: [AppStoreConnectReviewItem]
        if Self.preservesExistingSubscriptionConfiguration(
            intent: intent,
            appInformationIsLocked: storefrontConfigurationIsLocked
        ) {
            subscriptionReviewItems = []
            eventHandler(.output(L10n.text("App Store Connect has locked subscription information in its current state; keeping the existing products, prices, availability, and localizations for this TestFlight upload.\n")))
        } else {
            subscriptionReviewItems = try await appStoreConnect.reconcileSubscriptions(
                appID: publication.appID,
                catalog: subscriptionCatalog,
                requiresReviewAssets: true,
                onOutput: { eventHandler(.output($0)) }
            )
        }

        if !publication.deferredStorefrontSetup {
            eventHandler(.phase(.uploadingScreenshots))
            try await appStoreConnect.uploadScreenshots(
                screenshots,
                localizationIDsByLocale: publication.localizationIDsByLocale,
                primaryLocale: configuration.locale,
                replaceExisting: configuration.replaceScreenshots,
                onOutput: { eventHandler(.output($0)) }
            )
        }

        if let artifact, let temporaryDirectory, !reusedExistingBuild {
            eventHandler(.phase(.uploadingBuild))
            try await uploadBuild(
                ipaURL: artifact.ipaURL,
                issuerID: configuration.appStoreConnectIssuerID,
                keyID: configuration.appStoreConnectKeyID,
                privateKey: configuration.appStoreConnectPrivateKey,
                temporaryDirectory: temporaryDirectory,
                eventHandler: eventHandler
            )
        }

        let buildID: String
        if let processedExistingBuildID {
            buildID = processedExistingBuildID
        } else {
            eventHandler(.phase(.waitingForBuild))
            buildID = try await appStoreConnect.waitForBuild(
                appID: publication.appID,
                marketingVersion: targetVersion,
                buildNumber: targetBuildNumber,
                onOutput: { eventHandler(.output($0)) }
            )
        }
        if let versionID = publication.versionID {
            try await appStoreConnect.attachBuild(buildID, toVersion: versionID)
            eventHandler(.output(L10n.text("The processed build is attached to the App Store version.\n")))
        } else {
            eventHandler(.output(L10n.text("The processed build is available in TestFlight. App Store version attachment remains deferred until the version in review is released or removed.\n")))
        }

        eventHandler(.phase(.configuringTestFlight))
        try await appStoreConnect.assignBuildToInternalTestFlight(
            appID: publication.appID,
            buildID: buildID,
            configuration: configuration.testFlight,
            onOutput: { eventHandler(.output($0)) }
        )

        if !reviewAttachments.isEmpty, let versionID = publication.versionID {
            eventHandler(.phase(.uploadingReviewAssets))
            try await appStoreConnect.uploadReviewAttachments(
                reviewAttachments,
                versionID: versionID,
                onOutput: { eventHandler(.output($0)) }
            )
        }

        if intent.submitsForReview {
            guard let versionID = publication.versionID else {
                throw AppStoreConnectError.missingIdentifier("App Store version")
            }
            eventHandler(.phase(.submitting))
            try await appStoreConnect.submitForReview(
                appID: publication.appID,
                versionID: versionID,
                additionalItems: subscriptionReviewItems,
                intent: intent
            )
            eventHandler(.output(L10n.text("The App Store version and configured subscriptions were submitted for review.\n")))
        } else if publication.deferredStorefrontSetup {
            eventHandler(.output(L10n.text("TestFlight setup completed. Locked storefront work remains deferred until the version in review is released or removed.\n")))
        } else {
            eventHandler(.output(L10n.text("Full App Store and TestFlight setup completed. Review submission was intentionally skipped.\n")))
        }

        return PublishingResult(
            version: targetVersion,
            buildNumber: targetBuildNumber,
            intent: intent,
            reusedExistingBuild: reusedExistingBuild,
            deferredStorefrontSetup: publication.deferredStorefrontSetup
        )
    }

    static func preservesExistingSubscriptionConfiguration(
        intent: PublishingIntent,
        appInformationIsLocked: Bool
    ) -> Bool {
        intent == .testFlight && appInformationIsLocked
    }

    static func publicationURLs(configuration: PublishingConfiguration) -> [AppStorePublicationURL] {
        AppStorePublicationURLValidator.publicationURLs(configuration: configuration)
    }

    static func requiresReachablePublicationURLs(for intent: PublishingIntent) -> Bool {
        intent.submitsForReview
    }

    private func recordPrivacyPublication(
        catalog: AppStoreSubscriptionCatalog,
        publishedAt: String
    ) throws {
        guard let relativePath = catalog.sourceFiles.first(where: {
            URL(fileURLWithPath: $0).lastPathComponent == "app-store-publishing.json"
        }) else {
            throw AppStorePublishingError.privacyManifestUnavailable
        }
        let manifestURL = catalog.projectDirectory.appendingPathComponent(relativePath)
        guard var manifest = try? JSONDecoder().decode(
            AppStorePublishingManifest.self,
            from: Data(contentsOf: manifestURL)
        ), var compliance = manifest.compliance,
           var attestation = compliance.privacyAttestation else {
            throw AppStorePublishingError.privacyManifestUnavailable
        }
        attestation.publishedAt = publishedAt
        compliance.privacyAttestation = attestation
        manifest.compliance = compliance
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
        } catch {
            throw AppStorePublishingError.privacyManifestUnavailable
        }
    }

    static func screenshotDisplayType(
        width: Int,
        height: Int,
        platform: AppStoreScreenshotPlatform? = nil
    ) -> String? {
        let size = Set([width, height])
        if platform == .appleTV, size == Set([1_920, 1_080]) || size == Set([3_840, 2_160]) {
            return "APP_APPLE_TV"
        }
        if platform == .appleVisionPro, size == Set([3_840, 2_160]) {
            return "APP_APPLE_VISION_PRO"
        }
        if platform == .appleWatch {
            switch size {
            case Set([422, 514]), Set([410, 502]):
                return "APP_WATCH_ULTRA"
            case Set([416, 496]):
                return "APP_WATCH_SERIES_10"
            case Set([396, 484]):
                return "APP_WATCH_SERIES_7"
            case Set([368, 448]):
                return "APP_WATCH_SERIES_4"
            case Set([312, 390]):
                return "APP_WATCH_SERIES_3"
            default:
                return nil
            }
        }
        switch size {
        case Set([1_320, 2_868]), Set([1_290, 2_796]), Set([1_260, 2_736]):
            return "APP_IPHONE_67"
        case Set([1_284, 2_778]), Set([1_242, 2_688]):
            return "APP_IPHONE_65"
        case Set([1_206, 2_622]), Set([1_179, 2_556]):
            return "APP_IPHONE_61"
        case Set([1_170, 2_532]), Set([1_125, 2_436]), Set([1_080, 2_340]):
            return "APP_IPHONE_58"
        case Set([1_242, 2_208]):
            return "APP_IPHONE_55"
        case Set([750, 1_334]):
            return "APP_IPHONE_47"
        case Set([640, 1_096]), Set([640, 1_136]), Set([600, 1_136]):
            return "APP_IPHONE_40"
        case Set([640, 920]), Set([640, 960]), Set([600, 960]):
            return "APP_IPHONE_35"
        case Set([2_064, 2_752]), Set([2_048, 2_732]):
            return "APP_IPAD_PRO_3GEN_129"
        case Set([1_488, 2_266]), Set([1_668, 2_420]), Set([1_668, 2_388]), Set([1_640, 2_360]):
            return "APP_IPAD_PRO_3GEN_11"
        case Set([1_668, 2_224]):
            return "APP_IPAD_105"
        case Set([1_536, 2_008]), Set([1_536, 2_048]), Set([768, 1_004]), Set([768, 1_024]), Set([1_496, 2_048]), Set([748, 1_024]):
            return "APP_IPAD_97"
        default:
            return nil
        }
    }

    func localScreenshotAssets(
        project: ManagedProject,
        configuredPaths: [String]
    ) -> [AppStoreScreenshotAsset] {
        var screenshots = configuredPaths.flatMap { path -> [AppStoreScreenshotAsset] in
            let url = URL(fileURLWithPath: path, relativeTo: project.folderURL).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }
            if isDirectory.boolValue {
                guard let enumerator = fileManager.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { return [] }
                return enumerator.compactMap { value in
                    guard let url = value as? URL else { return nil }
                    return screenshotAsset(at: url)
                }
            }
            return screenshotAsset(at: url).map { [$0] } ?? []
        }
        screenshots.append(contentsOf: discoverProjectScreenshots(project: project))
        screenshots.append(contentsOf: screenshotAssets(in: screenshotCacheDirectory(for: project)))
        var seenPaths: Set<String> = []
        return screenshots.filter {
            seenPaths.insert($0.url.standardizedFileURL.path).inserted
        }
    }

    private func collectScreenshots(
        project: ManagedProject,
        configuredPaths: [String],
        eventHandler: @escaping EventHandler
    ) async throws -> [AppStoreScreenshotAsset] {
        let preview = try await prepareScreenshotPreview(
            project: project,
            configuredPaths: configuredPaths,
            eventHandler: eventHandler
        )
        if preview.screenshots.isEmpty {
            eventHandler(.output(L10n.text("No valid local or automatically captured screenshot is available; existing App Store Connect screenshots will be preserved.\n")))
        }
        var counts: [String: Int] = [:]
        return preview.screenshots.filter { screenshot in
            let key = "\(screenshot.locale?.lowercased() ?? "primary")|\(screenshot.displayType)"
            let count = counts[key, default: 0]
            guard count < 10 else { return false }
            counts[key] = count + 1
            return true
        }
    }

    private func discoverProjectScreenshots(project: ManagedProject) -> [AppStoreScreenshotAsset] {
        guard let enumerator = fileManager.enumerator(
            at: project.folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }
        var results: [AppStoreScreenshotAsset] = []
        for case let url as URL in enumerator {
            if results.count >= 20 { break }
            let lowerPath = url.path.lowercased()
            if lowerPath.contains("/build/") || lowerPath.contains("/deriveddata/") {
                enumerator.skipDescendants()
                continue
            }
            guard lowerPath.contains("screenshot"), let asset = screenshotAsset(at: url) else {
                continue
            }
            results.append(asset)
        }
        return results
    }

    private func screenshotAsset(
        at url: URL,
        platformHint: AppStoreScreenshotPlatform? = nil,
        deviceName: String? = nil,
        automaticallyCaptured: Bool = false
    ) -> AppStoreScreenshotAsset? {
        guard ["png", "jpg", "jpeg"].contains(url.pathExtension.lowercased()),
              let dimensions = imageDimensions(at: url),
              let displayType = Self.screenshotDisplayType(
                width: dimensions.width,
                height: dimensions.height,
                platform: platformHint ?? Self.platformHint(from: url.path)
              ) else { return nil }
        return AppStoreScreenshotAsset(
            url: url,
            displayType: displayType,
            platform: platformHint,
            locale: automaticallyCaptured ? nil : Self.screenshotLocale(from: url),
            deviceName: deviceName,
            automaticallyCaptured: automaticallyCaptured
        )
    }

    static func screenshotLocale(from url: URL) -> String? {
        for component in url.deletingLastPathComponent().pathComponents.reversed() {
            let candidate = component.replacingOccurrences(of: "_", with: "-")
            let parts = candidate.split(separator: "-")
            let isLanguage = parts.first.map {
                (2...3).contains($0.count)
                    && $0.allSatisfy(\.isLetter)
                    && String($0) == $0.lowercased()
            } == true
            let isRegion = parts.count == 1 || (
                parts.count == 2
                    && (2...3).contains(parts[1].count)
                    && parts[1].allSatisfy { $0.isLetter || $0.isNumber }
            )
            guard isLanguage, isRegion else { continue }
            return ProjectLocalizationDiscoveryService.normalizedAppStoreLocale(candidate)
        }
        return nil
    }

    static func normalizedLocalizedMetadata(
        _ localizations: [AppStoreLocalizedMetadata]
    ) -> [AppStoreLocalizedMetadata] {
        var seenLocales: Set<String> = []
        return localizations.compactMap { localization in
            guard let locale = AppStoreLocale.canonicalIdentifier(localization.locale),
                  seenLocales.insert(locale.lowercased()).inserted else {
                return nil
            }
            var normalized = localization.normalized()
            normalized.locale = locale
            return normalized
        }
    }

    static func applyingReleaseNotes(
        _ releaseNotes: AppStoreGeneratedReleaseNotes,
        to localizations: [AppStoreLocalizedMetadata]
    ) -> [AppStoreLocalizedMetadata] {
        let values = Dictionary(uniqueKeysWithValues: releaseNotes.normalized().localizations.map {
            ($0.locale.lowercased(), $0.whatsNew)
        })
        return localizations.map { localization in
            let locale = AppStoreLocale.canonicalIdentifier(localization.locale)
                ?? localization.locale
            guard let whatsNew = values[locale.lowercased()] else {
                return localization
            }
            var updated = localization
            updated.whatsNew = whatsNew
            return updated.normalized()
        }
    }

    func prepareScreenshotPreview(
        project: ManagedProject,
        configuredPaths: [String],
        onUpdate: ScreenshotPreviewHandler? = nil,
        eventHandler: EventHandler? = nil
    ) async throws -> AppStoreScreenshotPreview {
        var screenshots = localScreenshotAssets(project: project, configuredPaths: configuredPaths)
        if !screenshots.isEmpty {
            eventHandler?(.output(L10n.format(
                "Found %d valid local or cached screenshot(s).\n",
                screenshots.count
            )))
        }

        let plans = screenshotBuildPlans(for: project)
        let platforms = Set(plans.keys).union(screenshots.map(\.platform))
        let orderedPlatforms = AppStoreScreenshotPlatform.allCases.filter(platforms.contains)
        let simulators: [ScreenshotSimulatorDevice]
        do {
            let listResult = try await processRunner.runAndRequireSuccess(
                executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
                arguments: ["simctl", "list", "devices", "available", "-j"]
            )
            simulators = Self.availableSimulators(from: Data(listResult.output.utf8))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            simulators = []
            eventHandler?(.output(L10n.format(
                "Could not inspect installed Simulators: %@.\n",
                error.localizedDescription
            )))
        }

        var selectedSimulators: [AppStoreScreenshotPlatform: ScreenshotSimulatorDevice] = [:]
        var deviceStates: [AppStoreScreenshotPlatform: AppStoreScreenshotCaptureDevice] = [:]
        for platform in orderedPlatforms {
            if let provided = screenshots.first(where: { $0.platform == platform }) {
                deviceStates[platform] = AppStoreScreenshotCaptureDevice(
                    platform: platform,
                    name: provided.deviceName,
                    runtime: nil,
                    state: .provided
                )
            } else if let simulator = Self.preferredSimulator(for: platform, devices: simulators) {
                selectedSimulators[platform] = simulator
                deviceStates[platform] = AppStoreScreenshotCaptureDevice(
                    platform: platform,
                    name: simulator.name,
                    runtime: Self.friendlyRuntime(simulator.runtimeIdentifier),
                    state: .ready
                )
            } else {
                deviceStates[platform] = AppStoreScreenshotCaptureDevice(
                    platform: platform,
                    name: nil,
                    runtime: nil,
                    state: .unavailable
                )
            }
        }

        func preview() -> AppStoreScreenshotPreview {
            AppStoreScreenshotPreview(
                devices: orderedPlatforms.compactMap { deviceStates[$0] },
                screenshots: screenshots
            )
        }
        onUpdate?(preview())

        let cacheRoot = screenshotCacheRoot(for: project)
        try fileManager.createDirectory(
            at: screenshotCacheDirectory(for: project),
            withIntermediateDirectories: true
        )
        var builtApplications: [String: SimulatorApplication] = [:]
        for platform in orderedPlatforms {
            try Task.checkCancellation()
            guard screenshots.contains(where: { $0.platform == platform }) == false,
                  let simulator = selectedSimulators[platform],
                  let plan = plans[platform]
            else {
                continue
            }
            deviceStates[platform] = AppStoreScreenshotCaptureDevice(
                platform: platform,
                name: simulator.name,
                runtime: Self.friendlyRuntime(simulator.runtimeIdentifier),
                state: .capturing
            )
            onUpdate?(preview())

            do {
                let application: SimulatorApplication
                if let existing = builtApplications[plan.buildKey] {
                    application = existing
                } else {
                    application = try await buildSimulatorApplication(
                        project: project,
                        plan: plan,
                        buildRoot: cacheRoot.appendingPathComponent("Build-\(plan.buildKey)", isDirectory: true),
                        eventHandler: eventHandler
                    )
                    builtApplications[plan.buildKey] = application
                }
                let screenshot = try await captureScreenshot(
                    project: project,
                    platform: platform,
                    simulator: simulator,
                    application: application,
                    eventHandler: eventHandler
                )
                screenshots.append(screenshot)
                deviceStates[platform] = AppStoreScreenshotCaptureDevice(
                    platform: platform,
                    name: simulator.name,
                    runtime: Self.friendlyRuntime(simulator.runtimeIdentifier),
                    state: .captured
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                deviceStates[platform] = AppStoreScreenshotCaptureDevice(
                    platform: platform,
                    name: simulator.name,
                    runtime: Self.friendlyRuntime(simulator.runtimeIdentifier),
                    state: .failed(error.localizedDescription)
                )
                eventHandler?(.output(L10n.format(
                    "Could not capture %@ on %@: %@.\n",
                    platform.title,
                    simulator.name,
                    error.localizedDescription
                )))
            }
            onUpdate?(preview())
        }
        return preview()
    }

    private func captureScreenshot(
        project: ManagedProject,
        platform: AppStoreScreenshotPlatform,
        simulator: ScreenshotSimulatorDevice,
        application: SimulatorApplication,
        eventHandler: EventHandler?
    ) async throws -> AppStoreScreenshotAsset {
        var bootedByUs = false
        if simulator.state != "Booted" {
            _ = try await processRunner.runAndRequireSuccess(
                executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
                arguments: ["simctl", "boot", simulator.udid]
            )
            bootedByUs = true
        }
        defer {
            if bootedByUs {
                Task {
                    _ = try? await self.processRunner.run(
                        executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
                        arguments: ["simctl", "shutdown", simulator.udid]
                    )
                }
            }
        }
        _ = try await processRunner.runAndRequireSuccess(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["simctl", "bootstatus", simulator.udid, "-b"]
        )
        _ = try await processRunner.runAndRequireSuccess(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["simctl", "install", simulator.udid, application.url.path]
        )
        _ = try await processRunner.runAndRequireSuccess(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["simctl", "launch", "--terminate-running-process", simulator.udid, application.bundleIdentifier]
        )
        try await Task.sleep(for: .seconds(3))
        let screenshotURL = screenshotCacheDirectory(for: project).appendingPathComponent(
            "\(Self.safeFilename(project.displayName))-\(platform.rawValue)-\(Self.safeFilename(simulator.name)).png"
        )
        try? fileManager.removeItem(at: screenshotURL)
        _ = try await processRunner.runAndRequireSuccess(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["simctl", "io", simulator.udid, "screenshot", screenshotURL.path]
        )
        guard let screenshot = screenshotAsset(
            at: screenshotURL,
            platformHint: platform,
            deviceName: simulator.name,
            automaticallyCaptured: true
        ) else {
            throw AppStorePublishingError.noScreenshots
        }
        eventHandler?(.output(L10n.format(
            "Captured %@ screenshot on %@.\n",
            screenshot.displayType,
            simulator.name
        )))
        return screenshot
    }

    private func archiveAndExport(
        project: ManagedProject,
        expectedBundleIdentifier: String,
        signingIdentity: DistributionSigningIdentity,
        issuerID: String,
        keyID: String,
        privateKey: String,
        temporaryDirectory: URL,
        eventHandler: @escaping EventHandler
    ) async throws -> AppStoreBuildArtifact {
        try await xcodeGenPreparationService.prepare(
            project: project,
            onOutput: { eventHandler(.output($0)) }
        )
        let preparedScheme = try xcodeSchemePreparationService.prepare(project: project)
        defer { preparedScheme.removeTemporaryFile(fileManager: fileManager) }
        if !preparedScheme.removedActionTitles.isEmpty {
            eventHandler(.output(L10n.format(
                "Building without %d Xcode scheme script action(s); Development Management does not run repository workflow scripts.\n",
                preparedScheme.removedActionTitles.count
            )))
        }
        let archiveURL = temporaryDirectory.appendingPathComponent("\(project.scheme).xcarchive")
        let exportURL = temporaryDirectory.appendingPathComponent("Export", isDirectory: true)
        let exportOptionsURL = temporaryDirectory.appendingPathComponent("ExportOptions.plist")
        let authenticationKeyURL = try writeAppStoreConnectAuthenticationKey(
            privateKey,
            keyID: keyID,
            temporaryDirectory: temporaryDirectory
        )
        let authenticationArguments = Self.xcodeAuthenticationArguments(
            keyURL: authenticationKeyURL,
            keyID: keyID,
            issuerID: issuerID
        )
        eventHandler(.output(L10n.text(
            "Authenticating Xcode signing with the configured App Store Connect key.\n"
        )))
        let releaseConfiguration = project.availableConfigurations.first(where: {
            $0.caseInsensitiveCompare("Release") == .orderedSame
        }) ?? project.availableConfigurations.first(where: {
            $0.localizedCaseInsensitiveContains("release")
        }) ?? project.configuration
        let archiveArguments = Self.archiveArguments(
            containerArguments: xcodeContainerArguments(for: project),
            schemeName: preparedScheme.name,
            configuration: releaseConfiguration,
            archiveURL: archiveURL,
            teamID: project.signingTeamID ?? project.projectSigningTeamID,
            authenticationArguments: authenticationArguments
        )
        _ = try await processRunner.runAndRequireSuccess(
            executable: URL(fileURLWithPath: "/usr/bin/xcodebuild"),
            arguments: archiveArguments,
            workingDirectory: project.folderURL,
            onOutput: { eventHandler(.output($0)) }
        )

        let archiveMetadata = try Self.archiveMetadata(
            at: archiveURL,
            expectedBundleIdentifier: expectedBundleIdentifier,
            fileManager: fileManager
        )

        // Every signed bundle in the archive — the app plus each app extension — needs
        // its own distribution profile before a manual export can succeed. The archive
        // was already validated above, so the fallback only guards an unexpected layout.
        let discoveredTargets = Self.archivedProvisioningTargets(
            at: archiveURL,
            fileManager: fileManager
        )
        let archivedTargets = discoveredTargets.isEmpty
            ? [AppStoreProvisioningTarget(
                bundleIdentifier: archiveMetadata.bundleIdentifier,
                requiredEntitlementKeys: []
            )]
            : discoveredTargets
        let provisioningProfiles = try await provisioningProfileService.ensureProfiles(
            targets: archivedTargets,
            identity: signingIdentity,
            issuerID: issuerID,
            keyID: keyID,
            privateKeyPEM: privateKey,
            onOutput: { eventHandler(.output($0)) }
        )

        let exportOptions = Self.exportOptions(
            teamID: project.signingTeamID ?? project.projectSigningTeamID,
            signingIdentity: signingIdentity,
            provisioningProfiles: provisioningProfiles
        )
        let plist = try PropertyListSerialization.data(
            fromPropertyList: exportOptions,
            format: .xml,
            options: 0
        )
        try plist.write(to: exportOptionsURL, options: .atomic)
        eventHandler(.output(L10n.format(
            "Exporting with the local Apple Distribution identity %@ and %d distribution profile(s).\n",
            signingIdentity.commonName,
            provisioningProfiles.count
        )))
        do {
            _ = try await processRunner.runAndRequireSuccess(
                executable: URL(fileURLWithPath: "/usr/bin/xcodebuild"),
                arguments: Self.exportArchiveArguments(
                    archiveURL: archiveURL,
                    exportURL: exportURL,
                    exportOptionsURL: exportOptionsURL
                ),
                workingDirectory: project.folderURL,
                onOutput: { eventHandler(.output($0)) }
            )
        } catch {
            if Self.isDistributionSigningFailure(error.localizedDescription) {
                throw AppStorePublishingError.distributionSigningUnavailable
            }
            throw error
        }
        guard let ipaURL = try fileManager.contentsOfDirectory(
            at: exportURL,
            includingPropertiesForKeys: nil
        ).first(where: { $0.pathExtension.lowercased() == "ipa" }) else {
            throw AppStorePublishingError.noIPA
        }
        return AppStoreBuildArtifact(
            ipaURL: ipaURL,
            archiveURL: archiveURL,
            bundleIdentifier: archiveMetadata.bundleIdentifier,
            version: archiveMetadata.version,
            buildNumber: archiveMetadata.buildNumber
        )
    }

    static func archiveMetadata(
        at archiveURL: URL,
        expectedBundleIdentifier: String,
        fileManager: FileManager = .default
    ) throws -> (bundleIdentifier: String, version: String, buildNumber: String) {
        let applicationsURL = archiveURL
            .appendingPathComponent("Products", isDirectory: true)
            .appendingPathComponent("Applications", isDirectory: true)
        let applications = (try? fileManager.contentsOfDirectory(
            at: applicationsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let metadata = applications.compactMap { application -> (String, String, String)? in
            guard application.pathExtension.lowercased() == "app",
                  let data = try? Data(contentsOf: application.appendingPathComponent("Info.plist")),
                  let values = try? PropertyListSerialization.propertyList(
                    from: data,
                    options: [],
                    format: nil
                  ) as? [String: Any],
                  let bundleIdentifier = values["CFBundleIdentifier"] as? String,
                  let version = values["CFBundleShortVersionString"] as? String,
                  let buildNumber = values["CFBundleVersion"] as? String,
                  !bundleIdentifier.isEmpty,
                  !version.isEmpty,
                  !buildNumber.isEmpty else { return nil }
            return (bundleIdentifier, version, buildNumber)
        }
        if let match = metadata.first(where: { $0.0 == expectedBundleIdentifier }) {
            return match
        }
        if let first = metadata.first {
            throw AppStorePublishingError.archiveBundleIdentifierMismatch(
                expectedBundleIdentifier,
                first.0
            )
        }
        throw AppStorePublishingError.missingArchiveApplication
    }

    /// The archive keeps `-allowProvisioningUpdates` and the App Store Connect key:
    /// they let Xcode refresh the development profile the archive is signed with.
    static func archiveArguments(
        containerArguments: [String],
        schemeName: String,
        configuration: String,
        archiveURL: URL,
        teamID: String?,
        authenticationArguments: [String]
    ) -> [String] {
        var arguments = containerArguments + [
            "-scheme", schemeName,
            "-configuration", configuration,
            "-destination", "generic/platform=iOS",
            "-archivePath", archiveURL.path,
            "-allowProvisioningUpdates"
        ] + authenticationArguments
        if let teamID, !teamID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments.append("DEVELOPMENT_TEAM=\(teamID)")
        }
        arguments.append("archive")
        return arguments
    }

    /// Deliberately carries neither `-allowProvisioningUpdates` nor an App Store
    /// Connect authentication key. Both make `xcodebuild` resolve signing through
    /// Xcode Cloud Managed Distribution, which an API key has no permission to use —
    /// that is what produced "Cloud signing permission error". A manual export needs
    /// neither, because the certificate and profiles are pinned in the options plist.
    static func exportArchiveArguments(
        archiveURL: URL,
        exportURL: URL,
        exportOptionsURL: URL
    ) -> [String] {
        [
            "-exportArchive",
            "-archivePath", archiveURL.path,
            "-exportPath", exportURL.path,
            "-exportOptionsPlist", exportOptionsURL.path
        ]
    }

    /// Manual signing: the certificate and every profile are pinned explicitly so
    /// xcodebuild never consults Xcode's accounts or Cloud Managed Distribution.
    static func exportOptions(
        teamID: String?,
        signingIdentity: DistributionSigningIdentity,
        provisioningProfiles: [String: String]
    ) -> [String: Any] {
        var options: [String: Any] = [
            "method": "app-store-connect",
            "destination": "export",
            "signingStyle": "manual",
            // Publishing must never rewrite the managed app's version or build.
            "manageAppVersionAndBuildNumber": false,
            "uploadSymbols": true,
            "signingCertificate": signingIdentity.sha1Fingerprint
        ]
        let resolvedTeamID = teamID?.trimmingCharacters(in: .whitespacesAndNewlines)
        options["teamID"] = resolvedTeamID?.isEmpty == false
            ? resolvedTeamID
            : signingIdentity.teamID
        if !provisioningProfiles.isEmpty {
            options["provisioningProfiles"] = provisioningProfiles
        }
        return options
    }

    /// Bundle identifiers of every signed bundle in the archive: the application and
    /// its embedded app extensions and companion apps.
    static func archivedBundleIdentifiers(
        at archiveURL: URL,
        fileManager: FileManager = .default
    ) -> [String] {
        archivedProvisioningTargets(at: archiveURL, fileManager: fileManager)
            .map(\.bundleIdentifier)
    }

    /// Every profile-backed bundle plus the capability entitlements present in its
    /// archive signature. Distribution profiles may authorize different values for
    /// environment-specific entitlements, so profile reuse compares keys rather than
    /// development and production values.
    static func archivedProvisioningTargets(
        at archiveURL: URL,
        fileManager: FileManager = .default
    ) -> [AppStoreProvisioningTarget] {
        let applicationsURL = archiveURL
            .appendingPathComponent("Products", isDirectory: true)
            .appendingPathComponent("Applications", isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: applicationsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var targets: [AppStoreProvisioningTarget] = []
        var seen: Set<String> = []
        for case let candidate as URL in enumerator {
            guard ["app", "appex"].contains(candidate.pathExtension.lowercased()) else { continue }
            guard let data = try? Data(contentsOf: candidate.appendingPathComponent("Info.plist")),
                  let values = try? PropertyListSerialization.propertyList(
                    from: data,
                    options: [],
                    format: nil
                  ) as? [String: Any],
                  let identifier = values["CFBundleIdentifier"] as? String,
                  !identifier.isEmpty,
                  seen.insert(identifier).inserted
            else {
                continue
            }
            targets.append(AppStoreProvisioningTarget(
                bundleIdentifier: identifier,
                requiredEntitlementKeys: requiredProfileEntitlementKeys(
                    inCodeSignatureAt: candidate
                )
            ))
        }
        return targets
    }

    /// Entitlements that represent capabilities and therefore must be present in a
    /// reusable provisioning profile. The ignored keys are universal signing
    /// metadata or intentionally differ between development and distribution.
    static func requiredProfileEntitlementKeys(
        from entitlements: [String: Any]
    ) -> Set<String> {
        let signingMetadata: Set<String> = [
            "application-identifier",
            "com.apple.application-identifier",
            "com.apple.developer.team-identifier",
            "get-task-allow",
            "keychain-access-groups",
            "beta-reports-active"
        ]
        return Set(entitlements.keys).subtracting(signingMetadata)
    }

    private static func requiredProfileEntitlementKeys(
        inCodeSignatureAt bundleURL: URL
    ) -> Set<String> {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            bundleURL as CFURL,
            SecCSFlags(),
            &staticCode
        ) == errSecSuccess,
              let staticCode
        else {
            return []
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
              let dictionary = information as NSDictionary?,
              let entitlements = dictionary[kSecCodeInfoEntitlementsDict] as? [String: Any]
        else {
            return []
        }
        return requiredProfileEntitlementKeys(from: entitlements)
    }

    static func isDistributionSigningFailure(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("cloud signing permission error")
            || normalized.contains("no signing certificate \"ios distribution\" found")
            || normalized.contains("no signing certificate \"apple distribution\" found")
    }

    static func xcodeAuthenticationArguments(
        keyURL: URL,
        keyID: String,
        issuerID: String
    ) -> [String] {
        [
            "-authenticationKeyPath", keyURL.path,
            "-authenticationKeyID", keyID,
            "-authenticationKeyIssuerID", issuerID
        ]
    }

    private func writeAppStoreConnectAuthenticationKey(
        _ privateKey: String,
        keyID: String,
        temporaryDirectory: URL
    ) throws -> URL {
        let keyDirectory = temporaryDirectory.appendingPathComponent(
            "private_keys",
            isDirectory: true
        )
        try fileManager.createDirectory(at: keyDirectory, withIntermediateDirectories: true)
        let keyURL = keyDirectory.appendingPathComponent("AuthKey_\(keyID).p8")
        try Data(privateKey.utf8).write(to: keyURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        return keyURL
    }

    private func uploadBuild(
        ipaURL: URL,
        issuerID: String,
        keyID: String,
        privateKey: String,
        temporaryDirectory: URL,
        eventHandler: @escaping EventHandler
    ) async throws {
        let keyURL = try writeAppStoreConnectAuthenticationKey(
            privateKey,
            keyID: keyID,
            temporaryDirectory: temporaryDirectory
        )
        let keyDirectory = keyURL.deletingLastPathComponent()

        let uploaderURL = try appStoreUploaderURL()
        eventHandler(.output(L10n.text("Validating the exported IPA with Apple's App Store upload tool…\n")))
        _ = try await processRunner.runAndRequireSuccess(
            executable: uploaderURL,
            arguments: [
                "--validate-app", ipaURL.path,
                "--api-key", keyID,
                "--api-issuer", issuerID,
                "--output-format", "json"
            ],
            workingDirectory: ipaURL.deletingLastPathComponent(),
            additionalEnvironment: ["API_PRIVATE_KEYS_DIR": keyDirectory.path],
            onOutput: { eventHandler(.output($0)) }
        )
        eventHandler(.output(L10n.text("Uploading the exported IPA to App Store Connect…\n")))
        let maximumAttempts = 3
        for attempt in 1...maximumAttempts {
            let failureDetector = AppStoreUploadFailureDetector()
            do {
                _ = try await processRunner.runAndRequireSuccess(
                    executable: uploaderURL,
                    arguments: [
                        "--upload-package", ipaURL.path,
                        "--api-key", keyID,
                        "--api-issuer", issuerID,
                        "--output-format", "json",
                        "--show-progress"
                    ],
                    workingDirectory: ipaURL.deletingLastPathComponent(),
                    additionalEnvironment: ["API_PRIVATE_KEYS_DIR": keyDirectory.path],
                    onOutput: { eventHandler(.output($0)) },
                    terminateWhenOutput: { failureDetector.observe($0) }
                )
                return
            } catch {
                try Task.checkCancellation()
                guard failureDetector.didDetectRepeatedChecksumFailures
                    || Self.isTransientUploadFailure(error) else {
                    throw error
                }
                guard attempt < maximumAttempts else {
                    throw AppStorePublishingError.uploadTransferFailed(maximumAttempts)
                }
                eventHandler(.output(L10n.format(
                    "Apple's upload transfer became unreliable. Restarting it (attempt %d of %d)…\n",
                    attempt + 1,
                    maximumAttempts
                )))
                try await Task.sleep(for: .seconds(attempt * 2))
            }
        }
    }

    private static func isTransientUploadFailure(_ error: Error) -> Bool {
        guard case ProcessRunnerError.commandFailed(_, _, let output) = error else {
            return false
        }
        return AppStoreUploadFailureDetector.isTransientFailure(output)
    }

    private func appStoreUploaderURL() throws -> URL {
        let candidates = [
            "/Applications/Xcode.app/Contents/SharedFrameworks/ContentDelivery.framework/Versions/A/Resources/altool",
            "/Applications/Xcode.app/Contents/SharedFrameworks/ContentDeliveryServices.framework/Versions/A/Frameworks/AppStoreService.framework/Versions/A/Support/altool"
        ]
        guard let path = candidates.first(where: fileManager.isExecutableFile(atPath:)) else {
            throw AppStorePublishingError.uploaderUnavailable
        }
        return URL(fileURLWithPath: path)
    }

    private func xcodeContainerArguments(for project: ManagedProject) -> [String] {
        [project.containerKind.xcodebuildFlag, project.containerPath]
    }

    func supportedScreenshotPlatforms(for project: ManagedProject) -> Set<AppStoreScreenshotPlatform> {
        Set(screenshotBuildPlans(for: project).keys)
    }

    private func screenshotBuildPlans(
        for project: ManagedProject
    ) -> [AppStoreScreenshotPlatform: ScreenshotBuildPlan] {
        var plans: [AppStoreScreenshotPlatform: ScreenshotBuildPlan] = [:]
        if project.effectiveSupportedDeviceFamilies.contains(.iPhone) {
            plans[.iPhone] = ScreenshotBuildPlan(platform: .iPhone, scheme: project.scheme)
        }
        if project.effectiveSupportedDeviceFamilies.contains(.iPad) {
            plans[.iPad] = ScreenshotBuildPlan(platform: .iPad, scheme: project.scheme)
        }

        if hasCompanionWatchApp(for: project) {
            let scheme = associatedScheme(
                project: project,
                keywords: ["watch", "watchos"]
            ) ?? project.scheme
            plans[.appleWatch] = ScreenshotBuildPlan(platform: .appleWatch, scheme: scheme)
        }
        if let scheme = associatedScheme(project: project, keywords: ["tvos", "appletv"]) {
            plans[.appleTV] = ScreenshotBuildPlan(platform: .appleTV, scheme: scheme)
        }
        if let scheme = associatedScheme(project: project, keywords: ["visionos", "vision", "xros"]) {
            plans[.appleVisionPro] = ScreenshotBuildPlan(platform: .appleVisionPro, scheme: scheme)
        }
        return plans
    }

    private func associatedScheme(project: ManagedProject, keywords: [String]) -> String? {
        let selected = Self.normalizedSchemeBase(project.scheme)
        let displayName = Self.normalizedSchemeBase(project.displayName)
        return project.availableSchemes.first { candidate in
            let lower = candidate.lowercased()
            guard keywords.contains(where: lower.contains) else { return false }
            let candidateBase = Self.normalizedSchemeBase(candidate, removing: keywords)
            return candidate == project.scheme
                || (!selected.isEmpty && (candidateBase.hasPrefix(selected) || selected.hasPrefix(candidateBase)))
                || (!displayName.isEmpty && (candidateBase.hasPrefix(displayName) || displayName.hasPrefix(candidateBase)))
        }
    }

    private func hasCompanionWatchApp(for project: ManagedProject) -> Bool {
        guard let bundleIdentifier = project.bundleIdentifier?.nilIfEmpty,
              let enumerator = fileManager.enumerator(
                at: project.folderURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
              ) else {
            return false
        }
        for case let url as URL in enumerator {
            let lowerPath = url.path.lowercased()
            if lowerPath.contains("/build/") || lowerPath.contains("/deriveddata/") {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard url.pathExtension.lowercased() == "plist" else { continue }
            guard let data = try? Data(contentsOf: url),
                  let values = try? PropertyListSerialization.propertyList(
                    from: data,
                    options: [],
                    format: nil
                  ) as? [String: Any],
                  values["WKCompanionAppBundleIdentifier"] as? String == bundleIdentifier
            else {
                continue
            }
            return true
        }
        return false
    }

    private func buildSimulatorApplication(
        project: ManagedProject,
        plan: ScreenshotBuildPlan,
        buildRoot: URL,
        eventHandler: EventHandler?
    ) async throws -> SimulatorApplication {
        let settingsResult = try await processRunner.runAndRequireSuccess(
            executable: URL(fileURLWithPath: "/usr/bin/xcodebuild"),
            arguments: xcodeContainerArguments(for: project) + [
                "-scheme", plan.scheme,
                "-configuration", project.configuration,
                "-destination", plan.destination,
                "-showBuildSettings", "-json"
            ],
            workingDirectory: project.folderURL
        )
        guard let target = Self.applicationBuildTarget(
            from: settingsResult.output,
            platform: plan.platform
        ) else {
            throw AppStorePublishingError.noSimulatorApplication
        }
        let projectPath = target.projectPath
            ?? (project.containerKind == .project ? project.containerPath : nil)
        guard let projectPath else { throw AppStorePublishingError.missingProjectContainer }

        try fileManager.createDirectory(at: buildRoot, withIntermediateDirectories: true)
        let products = buildRoot.appendingPathComponent("Products", isDirectory: true)
        let intermediates = buildRoot.appendingPathComponent("Intermediates", isDirectory: true)
        let precompiled = buildRoot.appendingPathComponent("Precompiled", isDirectory: true)
        eventHandler?(.output(L10n.format(
            "Building %@ for %@ screenshot capture…\n",
            target.name,
            plan.platform.title
        )))
        _ = try await processRunner.runAndRequireSuccess(
            executable: URL(fileURLWithPath: "/usr/bin/xcodebuild"),
            arguments: [
                "-project", projectPath,
                "-target", target.name,
                "-configuration", project.configuration,
                "-sdk", plan.sdk,
                "SYMROOT=\(products.path)",
                "OBJROOT=\(intermediates.path)",
                "SHARED_PRECOMPS_DIR=\(precompiled.path)",
                "build"
            ],
            workingDirectory: project.folderURL,
            onOutput: { eventHandler?(.output($0)) }
        )
        guard let application = findApplication(
            in: products,
            bundleIdentifier: target.bundleIdentifier,
            platform: plan.platform
        ) else {
            throw AppStorePublishingError.noSimulatorApplication
        }
        return application
    }

    private func findApplication(
        in root: URL,
        bundleIdentifier: String?,
        platform: AppStoreScreenshotPlatform
    ) -> SimulatorApplication? {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        var fallback: SimulatorApplication?
        for case let url as URL in enumerator where url.pathExtension == "app" {
            guard let bundle = Bundle(url: url),
                  let identifier = bundle.bundleIdentifier,
                  Self.application(url, supports: platform)
            else {
                continue
            }
            let application = SimulatorApplication(url: url, bundleIdentifier: identifier)
            fallback = fallback ?? application
            if identifier == bundleIdentifier { return application }
        }
        return fallback
    }

    private static func application(_ url: URL, supports platform: AppStoreScreenshotPlatform) -> Bool {
        guard let data = try? Data(contentsOf: url.appendingPathComponent("Info.plist")),
              let values = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any],
              let supportedPlatforms = values["CFBundleSupportedPlatforms"] as? [String]
        else {
            return false
        }
        return supportedPlatforms.contains(platform.bundlePlatformName)
    }

    private func screenshotCacheRoot(for project: ManagedProject) -> URL {
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let version = Self.safeFilename(project.marketingVersion ?? "unknown")
        let build = Self.safeFilename(project.buildNumber ?? "unknown")
        return base
            .appendingPathComponent("DevManagement", isDirectory: true)
            .appendingPathComponent("AppStoreScreenshots", isDirectory: true)
            .appendingPathComponent(project.id.uuidString, isDirectory: true)
            .appendingPathComponent("\(version)-\(build)", isDirectory: true)
    }

    private func screenshotCacheDirectory(for project: ManagedProject) -> URL {
        screenshotCacheRoot(for: project).appendingPathComponent("Screenshots", isDirectory: true)
    }

    private func screenshotAssets(in directory: URL) -> [AppStoreScreenshotAsset] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }
        return enumerator.compactMap { value in
            guard let url = value as? URL else { return nil }
            return screenshotAsset(at: url, automaticallyCaptured: true)
        }
    }

    private static func platformHint(from path: String) -> AppStoreScreenshotPlatform? {
        let path = path.lowercased()
        if path.contains("watch") { return .appleWatch }
        if path.contains("vision") || path.contains("xros") { return .appleVisionPro }
        if path.contains("appletv") || path.contains("tvos") { return .appleTV }
        if path.contains("ipad") { return .iPad }
        if path.contains("iphone") { return .iPhone }
        return nil
    }

    private static func normalizedSchemeBase(
        _ value: String,
        removing extraTokens: [String] = []
    ) -> String {
        var result = value.lowercased().filter(\.isLetter)
        for suffix in extraTokens + ["ios", "iphone", "ipad", "app"] {
            if result.hasSuffix(suffix) {
                result.removeLast(suffix.count)
            }
        }
        return result
    }

    private static func safeFilename(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let result = value.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }
        return String(result).replacingOccurrences(of: "--", with: "-")
    }

    private static func applicationBuildTarget(
        from output: String,
        platform: AppStoreScreenshotPlatform
    ) -> SimulatorBuildTarget? {
        guard let entries = jsonBuildSettingsEntries(from: output) else { return nil }
        return entries.compactMap { entry -> SimulatorBuildTarget? in
            guard let settings = entry["buildSettings"] as? [String: Any],
                  let name = entry["target"] as? String,
                  let productType = settings["PRODUCT_TYPE"] as? String,
                  productType.contains("application"),
                  buildSettings(settings, support: platform)
            else {
                return nil
            }
            return SimulatorBuildTarget(
                name: name,
                projectPath: settings["PROJECT_FILE_PATH"] as? String,
                bundleIdentifier: (settings["PRODUCT_BUNDLE_IDENTIFIER"] as? String)?.nilIfEmpty
            )
        }.first
    }

    private static func buildSettings(
        _ settings: [String: Any],
        support platform: AppStoreScreenshotPlatform
    ) -> Bool {
        let supported = (settings["SUPPORTED_PLATFORMS"] as? String)?.lowercased() ?? ""
        let platformName = (settings["PLATFORM_NAME"] as? String)?.lowercased() ?? ""
        return supported.contains(platform.simulatorPlatformToken)
            || platformName == platform.simulatorPlatformToken
    }

    private static func jsonBuildSettingsEntries(from output: String) -> [[String: Any]]? {
        if let data = output.data(using: .utf8),
           let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return entries
        }
        guard let finalBracket = output.lastIndex(of: "]") else { return nil }
        var searchStart = output.startIndex
        while searchStart < finalBracket,
              let openingBracket = output[searchStart...].firstIndex(of: "[") {
            let candidate = Data(output[openingBracket...finalBracket].utf8)
            if let entries = try? JSONSerialization.jsonObject(with: candidate) as? [[String: Any]] {
                return entries
            }
            searchStart = output.index(after: openingBracket)
        }
        return nil
    }

    private func imageDimensions(at url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return (width, height)
    }

    private struct ScreenshotSimulatorDevice {
        let udid: String
        let name: String
        let state: String
        let runtimeIdentifier: String
        let platform: AppStoreScreenshotPlatform
    }

    private static func availableSimulators(from data: Data) -> [ScreenshotSimulatorDevice] {
        SimulatorDevice.availableDevices(fromSimctlList: data).compactMap { device in
            guard let platform = simulatorPlatform(
                runtimeIdentifier: device.runtimeIdentifier,
                deviceName: device.name
            ) else { return nil }
            return ScreenshotSimulatorDevice(
                udid: device.udid,
                name: device.name,
                state: device.state,
                runtimeIdentifier: device.runtimeIdentifier,
                platform: platform
            )
        }
    }

    private static func preferredSimulator(
        for platform: AppStoreScreenshotPlatform,
        devices: [ScreenshotSimulatorDevice]
    ) -> ScreenshotSimulatorDevice? {
        devices.filter { $0.platform == platform }.max { lhs, rhs in
            let leftVersion = runtimeVersion(lhs.runtimeIdentifier)
            let rightVersion = runtimeVersion(rhs.runtimeIdentifier)
            if leftVersion != rightVersion {
                return leftVersion.lexicographicallyPrecedes(rightVersion)
            }
            return simulatorPreference(lhs.name, platform: platform)
                < simulatorPreference(rhs.name, platform: platform)
        }
    }

    private static func simulatorPlatform(
        runtimeIdentifier: String,
        deviceName: String
    ) -> AppStoreScreenshotPlatform? {
        let runtime = runtimeIdentifier.lowercased()
        if runtime.contains("watchos-") { return .appleWatch }
        if runtime.contains("tvos-") { return .appleTV }
        if runtime.contains("xros-") || runtime.contains("visionos-") { return .appleVisionPro }
        if runtime.contains("ios-") {
            return deviceName.localizedCaseInsensitiveContains("iPad") ? .iPad : .iPhone
        }
        return nil
    }

    private static func simulatorPreference(
        _ name: String,
        platform: AppStoreScreenshotPlatform
    ) -> Int {
        switch platform {
        case .iPhone:
            if name.localizedCaseInsensitiveContains("Pro Max") { return 100 }
            if name.localizedCaseInsensitiveContains("Plus") { return 90 }
            return 10
        case .iPad:
            if name.localizedCaseInsensitiveContains("Pro 13-inch")
                || name.localizedCaseInsensitiveContains("12.9-inch") { return 100 }
            if name.localizedCaseInsensitiveContains("Pro") { return 80 }
            return 10
        case .appleWatch:
            if name.localizedCaseInsensitiveContains("Ultra 3") { return 110 }
            if name.localizedCaseInsensitiveContains("Ultra") { return 100 }
            if name.localizedCaseInsensitiveContains("Series 11") { return 90 }
            return 10
        case .appleTV:
            return name.localizedCaseInsensitiveContains("4K") ? 100 : 10
        case .appleVisionPro:
            return 10
        }
    }

    private static func runtimeVersion(_ identifier: String) -> [Int] {
        identifier.split(separator: "-").suffix(3).compactMap { Int($0) }
    }

    private static func friendlyRuntime(_ identifier: String) -> String {
        let component = identifier.split(separator: ".").last.map(String.init) ?? identifier
        return component
            .replacingOccurrences(of: "-", with: " ", options: [], range: component.range(of: "-") )
            .replacingOccurrences(of: "-", with: ".")
    }

    private struct ScreenshotBuildPlan {
        let platform: AppStoreScreenshotPlatform
        let scheme: String

        var buildKey: String {
            platform == .iPad ? AppStoreScreenshotPlatform.iPhone.rawValue : platform.rawValue
        }

        var destination: String {
            switch platform {
            case .iPhone, .iPad: "generic/platform=iOS Simulator"
            case .appleWatch: "generic/platform=watchOS Simulator"
            case .appleTV: "generic/platform=tvOS Simulator"
            case .appleVisionPro: "generic/platform=visionOS Simulator"
            }
        }

        var sdk: String { platform.simulatorPlatformToken }
    }

    private struct SimulatorBuildTarget {
        let name: String
        let projectPath: String?
        let bundleIdentifier: String?
    }

    private struct SimulatorApplication {
        let url: URL
        let bundleIdentifier: String
    }
}

final class AppStoreUploadFailureDetector: @unchecked Sendable {
    private static let checksumFailure = "checksums do not match"
    private static let defaultChecksumFailureLimit = 8

    private let lock = NSLock()
    private let checksumFailureLimit: Int
    private var bufferedOutput = ""
    private var checksumFailureCount = 0
    private var detectedRepeatedChecksumFailures = false

    init(checksumFailureLimit: Int = defaultChecksumFailureLimit) {
        self.checksumFailureLimit = max(checksumFailureLimit, 1)
    }

    func observe(_ output: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !detectedRepeatedChecksumFailures else { return true }
        bufferedOutput.append(output.lowercased())
        while let range = bufferedOutput.range(of: Self.checksumFailure) {
            checksumFailureCount += 1
            bufferedOutput.removeSubrange(bufferedOutput.startIndex..<range.upperBound)
        }
        let maximumRemainderLength = Self.checksumFailure.count - 1
        if bufferedOutput.count > maximumRemainderLength {
            bufferedOutput = String(bufferedOutput.suffix(maximumRemainderLength))
        }
        detectedRepeatedChecksumFailures = checksumFailureCount >= checksumFailureLimit
        return detectedRepeatedChecksumFailures
    }

    var didDetectRepeatedChecksumFailures: Bool {
        lock.lock()
        defer { lock.unlock() }
        return detectedRepeatedChecksumFailures
    }

    static func isTransientFailure(_ output: String) -> Bool {
        let normalized = output.lowercased()
        return [
            "checksums do not match",
            "the network connection was lost",
            "nsurlerrordomain code=-1001",
            "nsurlerrordomain code=-1005",
            "connection reset by peer",
            "network is unreachable"
        ].contains { normalized.contains($0) }
    }
}

private extension AppStoreScreenshotPlatform {
    var simulatorPlatformToken: String {
        switch self {
        case .iPhone, .iPad: "iphonesimulator"
        case .appleWatch: "watchsimulator"
        case .appleTV: "appletvsimulator"
        case .appleVisionPro: "xrsimulator"
        }
    }

    var bundlePlatformName: String {
        switch self {
        case .iPhone, .iPad: "iPhoneSimulator"
        case .appleWatch: "WatchSimulator"
        case .appleTV: "AppleTVSimulator"
        case .appleVisionPro: "XRSimulator"
        }
    }
}
