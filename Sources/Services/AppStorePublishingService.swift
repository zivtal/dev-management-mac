import ImageIO
import Foundation

enum AppStorePublishingError: LocalizedError {
    case busy
    case unsupportedProject
    case missingBundleIdentifier
    case missingVersion
    case missingBuildNumber
    case missingProjectContainer
    case missingArchiveApplication
    case archiveBundleIdentifierMismatch(String, String)
    case noIPA
    case noScreenshots
    case noSimulatorApplication
    case uploaderUnavailable
    case missingEditablePublishingDraft
    case privacyManifestUnavailable

    var errorDescription: String? {
        switch self {
        case .busy:
            return L10n.text("Another build, installation, publication, or offer-code request is already in progress.")
        case .unsupportedProject:
            return L10n.text("App Store publishing requires an iOS application using Direct Xcode build.")
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
        case .noIPA:
            return L10n.text("Xcode exported the archive, but no .ipa file was found.")
        case .noScreenshots:
            return L10n.text("The Simulator screenshot was captured, but its dimensions are not accepted by App Store Connect.")
        case .noSimulatorApplication:
            return L10n.text("The simulator build completed, but its application product was not found.")
        case .uploaderUnavailable:
            return L10n.text("Apple's App Store upload tool was not found in the selected Xcode installation.")
        case .missingEditablePublishingDraft:
            return L10n.text("Review and save the editable App Store listing and app declarations before releasing.")
        case .privacyManifestUnavailable:
            return L10n.text("App Privacy was published, but app-store-publishing.json could not be updated with the publication time.")
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
    private let privacyPublishingService: AppStorePrivacyPublishingService

    init(
        processRunner: ProcessRunner = ProcessRunner(),
        fileManager: FileManager = .default,
        subscriptionDiscoveryService: StoreKitSubscriptionDiscoveryService = StoreKitSubscriptionDiscoveryService(),
        reviewAssetService: AppStoreReviewAssetService = AppStoreReviewAssetService(),
        publicationURLValidator: AppStorePublicationURLValidator = AppStorePublicationURLValidator()
    ) {
        self.processRunner = processRunner
        self.fileManager = fileManager
        self.subscriptionDiscoveryService = subscriptionDiscoveryService
        self.reviewAssetService = reviewAssetService
        self.publicationURLValidator = publicationURLValidator
        self.xcodeGenPreparationService = XcodeGenProjectPreparationService(
            processRunner: processRunner,
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
        guard !project.isMacOSApplication, project.installMethod == .xcodebuild else {
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
        let metadata: AppStoreMetadata
        let localizedMetadata: [AppStoreLocalizedMetadata]
        if !configuration.manualLocalizations.isEmpty {
            localizedMetadata = configuration.manualLocalizations.map { $0.normalized() }
            let preferred = localizedMetadata.first(where: {
                $0.locale.caseInsensitiveCompare(configuration.locale) == .orderedSame
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
            let directory = fileManager.temporaryDirectory
                .appendingPathComponent("DevManagement-Publish-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            temporaryDirectory = directory

            eventHandler(.phase(.archiving))
            let archived = try await archiveAndExport(
                project: project,
                expectedBundleIdentifier: bundleIdentifier,
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
            if archived.version != project.marketingVersion || archived.buildNumber != project.buildNumber {
                eventHandler(.output(L10n.text("The Xcode scheme changed the version during archive; continuing with the archived version.\n")))
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
        eventHandler(.output(L10n.text(publication.preservedLockedAppInformation
            ? "Editable App Store version metadata updated; locked app-level information was preserved.\n"
            : "App Store metadata updated.\n")))

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

        if publication.preservedLockedAppInformation {
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
                eventHandler(.output(L10n.text("App Store Connect has locked app-level declarations in its current state; keeping the existing categories, rights, age rating, price, and availability for this TestFlight upload.\n")))
            }
        }

        eventHandler(.phase(.configuringSubscriptions))
        let subscriptionReviewItems = try await appStoreConnect.reconcileSubscriptions(
            appID: publication.appID,
            catalog: subscriptionCatalog,
            requiresReviewAssets: true,
            onOutput: { eventHandler(.output($0)) }
        )

        eventHandler(.phase(.uploadingScreenshots))
        try await appStoreConnect.uploadScreenshots(
            screenshots,
            localizationIDsByLocale: publication.localizationIDsByLocale,
            primaryLocale: configuration.locale,
            replaceExisting: configuration.replaceScreenshots,
            onOutput: { eventHandler(.output($0)) }
        )

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
        try await appStoreConnect.attachBuild(buildID, toVersion: publication.versionID)
        eventHandler(.output(L10n.text("The processed build is attached to the App Store version.\n")))

        eventHandler(.phase(.configuringTestFlight))
        try await appStoreConnect.assignBuildToInternalTestFlight(
            appID: publication.appID,
            buildID: buildID,
            configuration: configuration.testFlight,
            onOutput: { eventHandler(.output($0)) }
        )

        if !reviewAttachments.isEmpty {
            eventHandler(.phase(.uploadingReviewAssets))
            try await appStoreConnect.uploadReviewAttachments(
                reviewAttachments,
                versionID: publication.versionID,
                onOutput: { eventHandler(.output($0)) }
            )
        }

        if intent.submitsForReview {
            eventHandler(.phase(.submitting))
            try await appStoreConnect.submitForReview(
                appID: publication.appID,
                versionID: publication.versionID,
                additionalItems: subscriptionReviewItems,
                intent: intent
            )
            eventHandler(.output(L10n.text("The App Store version and configured subscriptions were submitted for review.\n")))
        } else {
            eventHandler(.output(L10n.text("Full App Store and TestFlight setup completed. Review submission was intentionally skipped.\n")))
        }

        return PublishingResult(
            version: targetVersion,
            buildNumber: targetBuildNumber,
            intent: intent,
            reusedExistingBuild: reusedExistingBuild
        )
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
        let simulators: [SimulatorDevice]
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

        var selectedSimulators: [AppStoreScreenshotPlatform: SimulatorDevice] = [:]
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
        simulator: SimulatorDevice,
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
        temporaryDirectory: URL,
        eventHandler: @escaping EventHandler
    ) async throws -> AppStoreBuildArtifact {
        try await xcodeGenPreparationService.prepare(
            project: project,
            onOutput: { eventHandler(.output($0)) }
        )
        let archiveURL = temporaryDirectory.appendingPathComponent("\(project.scheme).xcarchive")
        let exportURL = temporaryDirectory.appendingPathComponent("Export", isDirectory: true)
        let exportOptionsURL = temporaryDirectory.appendingPathComponent("ExportOptions.plist")
        let releaseConfiguration = project.availableConfigurations.first(where: {
            $0.caseInsensitiveCompare("Release") == .orderedSame
        }) ?? project.availableConfigurations.first(where: {
            $0.localizedCaseInsensitiveContains("release")
        }) ?? project.configuration
        var archiveArguments = xcodeContainerArguments(for: project) + [
            "-scheme", project.scheme,
            "-configuration", releaseConfiguration,
            "-destination", "generic/platform=iOS",
            "-archivePath", archiveURL.path,
            "-allowProvisioningUpdates"
        ]
        if let teamID = project.signingTeamID ?? project.projectSigningTeamID, !teamID.isEmpty {
            archiveArguments.append("DEVELOPMENT_TEAM=\(teamID)")
        }
        archiveArguments.append("archive")
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

        var exportOptions: [String: Any] = [
            "method": "app-store-connect",
            "destination": "export",
            "signingStyle": "automatic",
            "manageAppVersionAndBuildNumber": false,
            "uploadSymbols": true
        ]
        if let teamID = project.signingTeamID ?? project.projectSigningTeamID, !teamID.isEmpty {
            exportOptions["teamID"] = teamID
        }
        let plist = try PropertyListSerialization.data(
            fromPropertyList: exportOptions,
            format: .xml,
            options: 0
        )
        try plist.write(to: exportOptionsURL, options: .atomic)
        _ = try await processRunner.runAndRequireSuccess(
            executable: URL(fileURLWithPath: "/usr/bin/xcodebuild"),
            arguments: [
                "-exportArchive",
                "-archivePath", archiveURL.path,
                "-exportPath", exportURL.path,
                "-exportOptionsPlist", exportOptionsURL.path,
                "-allowProvisioningUpdates"
            ],
            workingDirectory: project.folderURL,
            onOutput: { eventHandler(.output($0)) }
        )
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

    private func uploadBuild(
        ipaURL: URL,
        issuerID: String,
        keyID: String,
        privateKey: String,
        temporaryDirectory: URL,
        eventHandler: @escaping EventHandler
    ) async throws {
        let keyDirectory = temporaryDirectory.appendingPathComponent("private_keys", isDirectory: true)
        try fileManager.createDirectory(at: keyDirectory, withIntermediateDirectories: true)
        let keyURL = keyDirectory.appendingPathComponent("AuthKey_\(keyID).p8")
        try Data(privateKey.utf8).write(to: keyURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)

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
        _ = try await processRunner.runAndRequireSuccess(
            executable: uploaderURL,
            arguments: [
                "--upload-package", ipaURL.path,
                "--api-key", keyID,
                "--api-issuer", issuerID,
                "--wait",
                "--output-format", "json",
                "--show-progress"
            ],
            workingDirectory: ipaURL.deletingLastPathComponent(),
            additionalEnvironment: ["API_PRIVATE_KEYS_DIR": keyDirectory.path],
            onOutput: { eventHandler(.output($0)) }
        )
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

    private struct SimulatorDevice {
        let udid: String
        let name: String
        let state: String
        let runtimeIdentifier: String
        let platform: AppStoreScreenshotPlatform
    }

    private static func availableSimulators(from data: Data) -> [SimulatorDevice] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runtimes = root["devices"] as? [String: [[String: Any]]] else {
            return []
        }
        return runtimes.flatMap { runtime, values in
            values.compactMap { value in
                guard value["isAvailable"] as? Bool != false,
                      let udid = value["udid"] as? String,
                      let name = value["name"] as? String,
                      let platform = simulatorPlatform(runtimeIdentifier: runtime, deviceName: name)
                else { return nil }
                return SimulatorDevice(
                    udid: udid,
                    name: name,
                    state: value["state"] as? String ?? "Shutdown",
                    runtimeIdentifier: runtime,
                    platform: platform
                )
            }
        }
    }

    private static func preferredSimulator(
        for platform: AppStoreScreenshotPlatform,
        devices: [SimulatorDevice]
    ) -> SimulatorDevice? {
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
