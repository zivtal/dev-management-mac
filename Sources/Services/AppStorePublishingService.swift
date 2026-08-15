import ImageIO
import Foundation

enum AppStorePublishingError: LocalizedError {
    case busy
    case unsupportedProject
    case missingBundleIdentifier
    case missingVersion
    case missingBuildNumber
    case missingProjectContainer
    case noIPA
    case noScreenshots
    case noSimulator
    case noSimulatorApplication
    case uploaderUnavailable

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
        case .noIPA:
            return L10n.text("Xcode exported the archive, but no .ipa file was found.")
        case .noScreenshots:
            return L10n.text("No valid App Store screenshot was found or captured. Add screenshots to a Screenshots folder or install an iOS Simulator runtime.")
        case .noSimulator:
            return L10n.text("No available iPhone or iPad Simulator could be used to capture screenshots.")
        case .noSimulatorApplication:
            return L10n.text("The simulator build completed, but its application product was not found.")
        case .uploaderUnavailable:
            return L10n.text("Apple's App Store upload tool was not found in the selected Xcode installation.")
        }
    }
}

final class AppStorePublishingService {
    typealias EventHandler = @Sendable (PublishingEvent) -> Void

    private let processRunner: ProcessRunner
    private let fileManager: FileManager
    private let openAIService: OpenAIStoreMetadataService
    private let subscriptionDiscoveryService: StoreKitSubscriptionDiscoveryService

    init(
        processRunner: ProcessRunner = ProcessRunner(),
        fileManager: FileManager = .default,
        openAIService: OpenAIStoreMetadataService = OpenAIStoreMetadataService(),
        subscriptionDiscoveryService: StoreKitSubscriptionDiscoveryService = StoreKitSubscriptionDiscoveryService()
    ) {
        self.processRunner = processRunner
        self.fileManager = fileManager
        self.openAIService = openAIService
        self.subscriptionDiscoveryService = subscriptionDiscoveryService
    }

    func publish(
        project: ManagedProject,
        configuration: PublishingConfiguration,
        eventHandler: @escaping EventHandler
    ) async throws -> PublishingResult {
        guard !project.isMacOSApplication, project.installMethod == .xcodebuild else {
            throw AppStorePublishingError.unsupportedProject
        }
        guard let bundleIdentifier = project.bundleIdentifier, !bundleIdentifier.isEmpty else {
            throw AppStorePublishingError.missingBundleIdentifier
        }
        guard let version = project.marketingVersion, !version.isEmpty else {
            throw AppStorePublishingError.missingVersion
        }
        guard let buildNumber = project.buildNumber, !buildNumber.isEmpty else {
            throw AppStorePublishingError.missingBuildNumber
        }
        guard fileManager.fileExists(atPath: project.containerPath) else {
            throw AppStorePublishingError.missingProjectContainer
        }

        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("DevManagement-Publish-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        eventHandler(.phase(.discoveringSubscriptions))
        let subscriptionCatalog = try subscriptionDiscoveryService.discover(
            project: project,
            defaultLocale: configuration.locale
        )
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
            eventHandler(.output(L10n.format(
                "Generating structured App Store metadata with OpenAI for %d language(s)…\n",
                configuration.detectedLocales.count
            )))
            let generated = try await openAIService.generateLocalized(
                project: project,
                locales: configuration.detectedLocales,
                apiKey: configuration.openAIAPIKey,
                model: configuration.openAIModel
            )
            localizedMetadata = generated.localizations
            let preferred = localizedMetadata.first(where: {
                $0.locale.caseInsensitiveCompare(configuration.locale) == .orderedSame
            }) ?? localizedMetadata[0]
            metadata = preferred.metadata(
                primaryCategory: generated.primaryCategory,
                secondaryCategory: generated.secondaryCategory
            )
            eventHandler(.output(L10n.format(
                "App Store metadata generated and validated for %d language(s).\n",
                localizedMetadata.count
            )))
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

        eventHandler(.phase(.collectingScreenshots))
        let screenshots = try await collectScreenshots(
            project: project,
            configuredPaths: configuration.screenshotPaths,
            temporaryDirectory: temporaryDirectory,
            eventHandler: eventHandler
        )
        if screenshots.isEmpty {
            eventHandler(.output(L10n.text("No new screenshot was available; existing App Store Connect screenshots will be preserved.\n")))
        } else {
            eventHandler(.output(L10n.format("Prepared %d App Store screenshot(s).\n", screenshots.count)))
        }

        eventHandler(.phase(.archiving))
        let ipaURL = try await archiveAndExport(
            project: project,
            temporaryDirectory: temporaryDirectory,
            eventHandler: eventHandler
        )

        let appStoreConnect = try AppStoreConnectService(
            issuerID: configuration.appStoreConnectIssuerID,
            keyID: configuration.appStoreConnectKeyID,
            privateKeyPEM: configuration.appStoreConnectPrivateKey
        )

        eventHandler(.phase(.uploadingMetadata))
        eventHandler(.output(L10n.text("Finding the application and editable version in App Store Connect…\n")))
        let publication = try await appStoreConnect.preparePublication(
            bundleIdentifier: bundleIdentifier,
            version: version,
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
            releaseAutomatically: configuration.releaseAutomatically
        )
        eventHandler(.output(L10n.text("App Store metadata updated.\n")))

        try await appStoreConnect.configureFirstPublication(
            appID: publication.appID,
            configuration: applicationConfiguration,
            onOutput: { eventHandler(.output($0)) }
        )

        let subscriptionReviewItems: [AppStoreConnectReviewItem]
        if publication.isVersionOnlyUpdate {
            subscriptionReviewItems = []
            eventHandler(.output(L10n.text("A previous version is already published; reusing app and subscription setup for this version-only update.\n")))
        } else {
            eventHandler(.phase(.configuringSubscriptions))
            subscriptionReviewItems = try await appStoreConnect.reconcileSubscriptions(
                appID: publication.appID,
                catalog: subscriptionCatalog,
                requiresReviewAssets: configuration.submitForReview,
                onOutput: { eventHandler(.output($0)) }
            )
        }

        eventHandler(.phase(.uploadingScreenshots))
        try await appStoreConnect.uploadScreenshots(
            screenshots,
            localizationID: publication.localizationID,
            replaceExisting: configuration.replaceScreenshots,
            onOutput: { eventHandler(.output($0)) }
        )

        eventHandler(.phase(.uploadingBuild))
        try await uploadBuild(
            ipaURL: ipaURL,
            configuration: configuration,
            temporaryDirectory: temporaryDirectory,
            eventHandler: eventHandler
        )

        eventHandler(.phase(.waitingForBuild))
        let buildID = try await appStoreConnect.waitForBuild(
            appID: publication.appID,
            buildNumber: buildNumber,
            onOutput: { eventHandler(.output($0)) }
        )
        try await appStoreConnect.attachBuild(buildID, toVersion: publication.versionID)
        eventHandler(.output(L10n.text("The processed build is attached to the App Store version.\n")))

        if configuration.submitForReview {
            eventHandler(.phase(.submitting))
            try await appStoreConnect.submitForReview(
                appID: publication.appID,
                versionID: publication.versionID,
                additionalItems: subscriptionReviewItems
            )
            eventHandler(.output(L10n.text("The App Store version was submitted for review.\n")))
        }

        return PublishingResult(
            version: version,
            buildNumber: buildNumber,
            submittedForReview: configuration.submitForReview
        )
    }

    static func screenshotDisplayType(width: Int, height: Int) -> String? {
        let size = Set([width, height])
        switch size {
        case Set([1_320, 2_868]), Set([1_290, 2_796]), Set([1_260, 2_736]):
            return "APP_IPHONE_67"
        case Set([1_284, 2_778]), Set([1_242, 2_688]):
            return "APP_IPHONE_65"
        case Set([1_206, 2_622]), Set([1_179, 2_556]):
            return "APP_IPHONE_61"
        case Set([1_125, 2_436]):
            return "APP_IPHONE_58"
        case Set([1_242, 2_208]):
            return "APP_IPHONE_55"
        case Set([2_064, 2_752]), Set([2_048, 2_732]):
            return "APP_IPAD_PRO_3GEN_129"
        case Set([1_668, 2_388]), Set([1_640, 2_360]):
            return "APP_IPAD_PRO_3GEN_11"
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
                return enumerator.compactMap { ($0 as? URL).flatMap(screenshotAsset) }
            }
            return screenshotAsset(at: url).map { [$0] } ?? []
        }
        screenshots.append(contentsOf: discoverProjectScreenshots(project: project))
        var seenPaths: Set<String> = []
        return screenshots.filter {
            seenPaths.insert($0.url.standardizedFileURL.path).inserted
        }
    }

    private func collectScreenshots(
        project: ManagedProject,
        configuredPaths: [String],
        temporaryDirectory: URL,
        eventHandler: @escaping EventHandler
    ) async throws -> [AppStoreScreenshotAsset] {
        var screenshots = localScreenshotAssets(
            project: project,
            configuredPaths: configuredPaths
        )
        if !screenshots.isEmpty {
            eventHandler(.output(L10n.format("Found %d valid screenshot(s) in the project.\n", screenshots.count)))
        }

        let existingFamilies = Set(screenshots.map { $0.displayType.hasPrefix("APP_IPAD") ? MobileDeviceFamily.iPad : .iPhone })
        let missingFamilies = project.effectiveSupportedDeviceFamilies.subtracting(existingFamilies)
        if !missingFamilies.isEmpty {
            do {
                screenshots.append(contentsOf: try await captureSimulatorScreenshots(
                    project: project,
                    families: missingFamilies,
                    temporaryDirectory: temporaryDirectory,
                    eventHandler: eventHandler
                ))
            } catch AppStorePublishingError.noSimulator {
                eventHandler(.output(L10n.text("No additional simulator was available; existing App Store Connect or project screenshots will be used.\n")))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                eventHandler(.output(L10n.format(
                    "Simulator screenshot capture failed: %@ Existing App Store Connect or project screenshots will be used.\n",
                    error.localizedDescription
                )))
            }
        }
        return Array(screenshots.prefix(20))
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

    private func screenshotAsset(at url: URL) -> AppStoreScreenshotAsset? {
        guard ["png", "jpg", "jpeg"].contains(url.pathExtension.lowercased()),
              let dimensions = imageDimensions(at: url),
              let displayType = Self.screenshotDisplayType(
                width: dimensions.width,
                height: dimensions.height
              ) else { return nil }
        return AppStoreScreenshotAsset(url: url, displayType: displayType)
    }

    private func captureSimulatorScreenshots(
        project: ManagedProject,
        families: Set<MobileDeviceFamily>,
        temporaryDirectory: URL,
        eventHandler: @escaping EventHandler
    ) async throws -> [AppStoreScreenshotAsset] {
        let listResult = try await processRunner.runAndRequireSuccess(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: ["simctl", "list", "devices", "available", "-j"]
        )
        let devices = Self.availableSimulators(from: Data(listResult.output.utf8))
        let selected = families.compactMap { family in
            Self.preferredSimulator(for: family, devices: devices)
        }
        guard !selected.isEmpty else { throw AppStorePublishingError.noSimulator }

        let derivedDataURL = temporaryDirectory.appendingPathComponent("SimulatorDerivedData", isDirectory: true)
        let commonArguments = xcodeContainerArguments(for: project) + [
            "-scheme", project.scheme,
            "-configuration", project.configuration,
            "-destination", "generic/platform=iOS Simulator",
            "-derivedDataPath", derivedDataURL.path
        ]
        eventHandler(.output(L10n.text("Building once for iOS Simulator screenshot capture…\n")))
        _ = try await processRunner.runAndRequireSuccess(
            executable: URL(fileURLWithPath: "/usr/bin/xcodebuild"),
            arguments: commonArguments + ["build"],
            workingDirectory: project.folderURL,
            onOutput: { eventHandler(.output($0)) }
        )
        guard let appURL = findApplication(in: derivedDataURL, bundleIdentifier: project.bundleIdentifier) else {
            throw AppStorePublishingError.noSimulatorApplication
        }

        var results: [AppStoreScreenshotAsset] = []
        for simulator in selected {
            try Task.checkCancellation()
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
                arguments: ["simctl", "install", simulator.udid, appURL.path]
            )
            _ = try await processRunner.runAndRequireSuccess(
                executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
                arguments: ["simctl", "launch", "--terminate-running-process", simulator.udid, project.bundleIdentifier!]
            )
            try await Task.sleep(for: .seconds(3))
            let screenshotURL = temporaryDirectory.appendingPathComponent(
                "\(project.displayName)-\(simulator.name.replacingOccurrences(of: " ", with: "-"))-1.png"
            )
            _ = try await processRunner.runAndRequireSuccess(
                executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
                arguments: ["simctl", "io", simulator.udid, "screenshot", screenshotURL.path]
            )
            if let dimensions = imageDimensions(at: screenshotURL),
               let displayType = Self.screenshotDisplayType(width: dimensions.width, height: dimensions.height) {
                results.append(AppStoreScreenshotAsset(url: screenshotURL, displayType: displayType))
                eventHandler(.output(L10n.format("Captured %@ screenshot on %@.\n", displayType, simulator.name)))
            }
        }
        return results
    }

    private func archiveAndExport(
        project: ManagedProject,
        temporaryDirectory: URL,
        eventHandler: @escaping EventHandler
    ) async throws -> URL {
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
        return ipaURL
    }

    private func uploadBuild(
        ipaURL: URL,
        configuration: PublishingConfiguration,
        temporaryDirectory: URL,
        eventHandler: @escaping EventHandler
    ) async throws {
        let keyDirectory = temporaryDirectory.appendingPathComponent("private_keys", isDirectory: true)
        try fileManager.createDirectory(at: keyDirectory, withIntermediateDirectories: true)
        let keyURL = keyDirectory.appendingPathComponent("AuthKey_\(configuration.appStoreConnectKeyID).p8")
        try Data(configuration.appStoreConnectPrivateKey.utf8).write(to: keyURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)

        let uploaderURL = try appStoreUploaderURL()
        eventHandler(.output(L10n.text("Validating the exported IPA with Apple's App Store upload tool…\n")))
        _ = try await processRunner.runAndRequireSuccess(
            executable: uploaderURL,
            arguments: [
                "--validate-app", ipaURL.path,
                "--api-key", configuration.appStoreConnectKeyID,
                "--api-issuer", configuration.appStoreConnectIssuerID,
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
                "--api-key", configuration.appStoreConnectKeyID,
                "--api-issuer", configuration.appStoreConnectIssuerID,
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

    private func findApplication(in root: URL, bundleIdentifier: String?) -> URL? {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        var fallback: URL?
        for case let url as URL in enumerator where url.pathExtension == "app" {
            enumerator.skipDescendants()
            fallback = fallback ?? url
            if Bundle(url: url)?.bundleIdentifier == bundleIdentifier { return url }
        }
        return fallback
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
    }

    private static func availableSimulators(from data: Data) -> [SimulatorDevice] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runtimes = root["devices"] as? [String: [[String: Any]]] else {
            return []
        }
        return runtimes.keys.sorted().reversed().flatMap { runtime in
            (runtimes[runtime] ?? []).compactMap { value in
                guard value["isAvailable"] as? Bool != false,
                      let udid = value["udid"] as? String,
                      let name = value["name"] as? String else { return nil }
                return SimulatorDevice(udid: udid, name: name, state: value["state"] as? String ?? "Shutdown")
            }
        }
    }

    private static func preferredSimulator(
        for family: MobileDeviceFamily,
        devices: [SimulatorDevice]
    ) -> SimulatorDevice? {
        switch family {
        case .iPhone:
            return devices.first(where: { $0.name.contains("Pro Max") })
                ?? devices.first(where: { $0.name.hasPrefix("iPhone") })
        case .iPad:
            return devices.first(where: { $0.name.contains("iPad Pro") && ($0.name.contains("13-inch") || $0.name.contains("12.9-inch")) })
                ?? devices.first(where: { $0.name.hasPrefix("iPad") })
        }
    }
}
