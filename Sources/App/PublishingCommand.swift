import Foundation

/// Invoked directly through the app executable; no menu bar or monitoring. Screenshot capture builds locally; it never writes to ASC.
enum PublishingCommand {
    static let commands = ["doctor", "status", "dry-run", "capture-screenshots", "app-status", "replace-screenshots", "resubmit", "publish"]
    /// Commands that talk to App Store Connect for a project resolved by its bundle identifier.
    static let projectConnectCommands = ["app-status", "replace-screenshots", "resubmit"]

    @MainActor static func run(_ arguments: [String]) async -> Int32 {
        do {
            guard let command = arguments.first, commands.contains(command) else { throw AppStoreReleaseError.invalid(usage) }
            var options: [String: String] = [:]
            var index = 1
            while index < arguments.count {
                let key = arguments[index]
                guard ["--app-id", "--project", "--platform", "--issuer-id", "--key-id", "--private-key-path",
                       "--version", "--display-types"].contains(key),
                      index + 1 < arguments.count, options[key] == nil else { throw AppStoreReleaseError.invalid(usage) }
                options[key] = arguments[index + 1]; index += 2
            }
            let state = SettingsStore().load()
            let preferences = state.preferences
            let store = KeychainCredentialStore()
            let issuer = options["--issuer-id"] ?? preferences.appStoreConnectIssuerID ?? ""
            let keyID = options["--key-id"] ?? preferences.appStoreConnectKeyID ?? ""
            let privateKey: String
            if let path = options["--private-key-path"] { privateKey = try String(contentsOfFile: path, encoding: .utf8) }
            else if ["doctor", "status", "publish"].contains(command) || projectConnectCommands.contains(command) || options["--app-id"] != nil {
                privateKey = try store.appStoreConnectPrivateKey(profileID: nil) ?? ""
            }
            else { privateKey = "" }
            let platforms = try parsePlatforms(options["--platform"])
            if ["doctor", "status"].contains(command) {
                guard let appID = options["--app-id"] else { throw AppStoreReleaseError.invalid(usage) }
                for platform in (platforms ?? Set(AppStorePlatform.allCases)).sorted(by: { $0.rawValue < $1.rawValue }) {
                    let service = try AppStoreConnectService(issuerID: issuer, keyID: keyID, privateKeyPEM: privateKey, platform: platform)
                    print(try await service.doctor(appID: appID))
                }
                return 0
            }
            guard let path = options["--project"] else { throw AppStoreReleaseError.invalid(usage) }
            let folder = URL(fileURLWithPath: path).standardizedFileURL
            let descriptor = try await ProjectDiscoveryService().discover(folderURL: folder)
            let project = state.projects.first { $0.folderURL.standardizedFileURL == folder } ?? descriptor.makeManagedProject()
            let review = AppStoreReviewConfiguration(contactFirstName: preferences.appStoreReviewFirstName ?? "",
                contactLastName: preferences.appStoreReviewLastName ?? "", contactPhone: preferences.appStoreReviewPhone ?? "",
                contactEmail: preferences.appStoreReviewEmail ?? "", notes: preferences.appStoreReviewNotes ?? "",
                demoAccountRequired: preferences.appStoreReviewDemoAccountRequired ?? false,
                demoAccountName: nil, demoAccountPassword: nil)
            let config = PublishingConfiguration(intent: .publish, appStoreConnectIssuerID: issuer,
                appStoreConnectKeyID: keyID, appStoreConnectPrivateKey: privateKey,
                appStorePrivacyAppleID: nil, appStorePrivacyTeamID: nil, appStorePrivacyFastlaneSession: nil,
                locale: preferences.appStoreLocale ?? "en-US", copyright: preferences.appStoreCopyright ?? "",
                supportURL: preferences.appStoreSupportURL ?? "", marketingURL: nil, termsURL: nil,
                privacyPolicyURL: nil, privacyChoicesURL: nil, appName: nil, subtitle: nil, licenseAgreementText: nil,
                review: review, manualMetadata: nil, manualLocalizations: [], screenshotPaths: [], screenshotSimulatorUDIDs: [:],
                reviewAttachmentPaths: [], replaceScreenshots: false, releaseAutomatically: true,
                replaceActiveReviewVersion: false,
                testFlight: AppStoreTestFlightConfiguration(groupName: "Internal Testing", feedbackEmail: review.contactEmail,
                    reviewNotes: review.notes, internalTesterEmails: [review.contactEmail]),
                selectedPlatforms: platforms)
            if command == "publish" {
                // The same service call the Publish button makes: archive, export, upload, metadata,
                // screenshots, review details, attach, submit. The manifest supplies listing fields.
                let result = try await AppStorePublishingService().publish(project: project, configuration: config) { event in
                    switch event {
                    case .output(let text): print(text, terminator: "")
                    case .phase(let phase): print("== \(phase)")
                    default: break
                    }
                }
                print("Published \(result.version) (\(result.buildNumber)): \(result.platformSummaries.joined(separator: "; "))"
                    + (result.submittedForReview ? " — submitted for App Review." : "."))
                return 0
            }
            let targets = try await AppStoreReleaseCoordinator.targets(project: project, configuration: config, validateReviewRequirements: false)
            let manifest = try AppStorePublishingManifest.load(from: folder)
            if command == "capture-screenshots" {
                for target in targets {
                    print("Capturing \(target.label). No uploads or App Store changes.")
                    let preview = try await AppStorePublishingService().prepareScreenshotPreview(
                        project: target.project, configuredPaths: target.configuration.screenshotPaths,
                        screenshotSimulatorUDIDs: target.configuration.screenshotSimulatorUDIDs,
                        eventHandler: { event in
                            if case .output(let text) = event { print(text, terminator: "") }
                        }, regenerate: true)
                    guard preview.blockingIssues.isEmpty, !preview.screenshots.isEmpty else {
                        throw AppStoreScreenshotValidationError(issues: preview.blockingIssues.isEmpty
                            ? ["No screenshots captured."] : preview.blockingIssues)
                    }
                    try AppStoreScreenshotValidator.validateSet(preview.screenshots)
                    for asset in preview.screenshots {
                        print("VALID \(asset.displayType): \(asset.url.path)")
                    }
                }
                return 0
            }
            if projectConnectCommands.contains(command) {
                for target in targets {
                    let service = try AppStoreConnectService(issuerID: issuer, keyID: keyID, privateKeyPEM: privateKey,
                        platform: target.project.appStorePlatform)
                    guard let bundleIdentifier = target.project.bundleIdentifier?.nilIfEmpty else {
                        throw AppStoreReleaseError.invalid("\(target.label): the project has no bundle identifier.")
                    }
                    let appID = try await service.applicationID(bundleIdentifier: bundleIdentifier)
                    if command == "app-status" {
                        print(try await service.doctor(appID: appID))
                        continue
                    }
                    guard let version = options["--version"] else { throw AppStoreReleaseError.invalid(usage) }
                    if command == "replace-screenshots" {
                        let displayTypes = (options["--display-types"] ?? "").split(separator: ",").map(String.init)
                        guard !displayTypes.isEmpty else { throw AppStoreReleaseError.invalid(usage) }
                        // The same validated preview Publish uses: supplied files first, then cached captures.
                        let preview = try await AppStorePublishingService().prepareScreenshotPreview(
                            project: target.project, configuredPaths: target.configuration.screenshotPaths,
                            screenshotSimulatorUDIDs: target.configuration.screenshotSimulatorUDIDs,
                            eventHandler: { event in if case .output(let text) = event { print(text, terminator: "") } })
                        for displayType in displayTypes {
                            try await service.replaceScreenshots(bundleIdentifier: bundleIdentifier,
                                version: version, displayType: displayType, screenshots: preview.screenshots,
                                onOutput: { print($0, terminator: "") })
                        }
                        print("Replaced \(displayTypes.joined(separator: ", ")) on \(target.label) \(version). No review submission was made.")
                    } else {
                        guard let versionID = try await service.editableVersionID(appID: appID, version: version) else {
                            throw AppStoreReleaseError.invalid("\(target.label): version \(version) is not editable (preparing or rejected) on App Store Connect.")
                        }
                        let readiness = try await service.submissionReadiness(versionID: versionID, expectedVersion: version)
                        print(readiness.text, terminator: "")
                        try readiness.requireReady()
                        try await service.submitForReview(appID: appID, versionID: versionID, intent: .publish)
                        print("Submitted \(target.label) \(version) for App Review with its attached build.")
                    }
                }
                return 0
            }
            let history = AppStoreReleaseHistory()
            print("Dry run: no archives, uploads, version changes, or App Store writes.")
            for target in targets {
                let current = try history.fingerprint(project: target.project, manifest: manifest)
                let previous = try history.previous(project: target.project, intent: .publish)
                print("\(target.label): \(previous == current ? "UNCHANGED — skip" : previous == nil ? "NO RELEASE BASELINE — verify selection" : "CHANGED")")
                print("  Destination: \(target.project.appStorePlatform.destination); export: .\(target.project.appStorePlatform.artifactExtension)")
                print("  Release: \(target.configuration.releaseAutomatically ? "AFTER_APPROVAL" : "MANUAL")")
                if target.configuration.review.demoVideoRequired && target.configuration.review.demoVideoURL?.nilIfEmpty == nil {
                    print("  [MISSING] Hardware demo video URL required before submission")
                }
                print("  Steps: archive → export → upload → poll → metadata/screenshots/review → attach → preflight → submit → verify")
                if let appID = options["--app-id"] {
                    let service = try AppStoreConnectService(issuerID: issuer, keyID: keyID, privateKeyPEM: privateKey,
                        platform: target.project.appStorePlatform)
                    print(try await service.doctor(appID: appID))
                }
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            return 1
        }
    }

    static func parsePlatforms(_ value: String?) throws -> Set<AppStorePlatform>? {
        guard let value else { return nil }
        let names = value.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let platforms = names.compactMap(AppStorePlatform.init(rawValue:))
        guard !names.isEmpty, platforms.count == names.count else {
            throw AppStoreReleaseError.invalid("--platform accepts IOS, MAC_OS, or IOS,MAC_OS.")
        }
        return Set(platforms)
    }
    private static let usage = """
    Usage: Development Management doctor|status --app-id ID [--platform IOS,MAC_OS]
           Development Management dry-run --project PATH [--platform MAC_OS] [--app-id ID]
           Development Management capture-screenshots --project PATH [--platform IOS]
           Development Management app-status --project PATH [--platform IOS]
           Development Management replace-screenshots --project PATH --version X.Y.Z --display-types APP_IPAD_PRO_3GEN_129,APP_IPHONE_67 [--platform IOS]
           Development Management resubmit --project PATH --version X.Y.Z [--platform IOS]
           Development Management publish --project PATH [--platform IOS]
    app-status reports builds and versions by bundle identifier. replace-screenshots deletes and recreates the
    display types' sets on an editable (rejected or preparing) version from the validated local screenshots.
    resubmit sends that version, with its attached build, to App Review again. publish runs the full
    archive → upload → metadata/screenshots → submit workflow from the manifest, like the Publish button. Replies in the Resolution
    Center have no public API and stay in App Store Connect.
    Credentials default to Publishing settings/Keychain. Override with --issuer-id ID --key-id ID --private-key-path PATH.
    Doctor reports current state; missing fields are diagnostics. API/configuration errors exit nonzero.
    """
}
