import Foundation

/// Invoked directly through the app executable; no menu bar, monitoring, builds or ASC writes.
enum PublishingCommand {
    static let commands = ["doctor", "status", "dry-run"]

    @MainActor static func run(_ arguments: [String]) async -> Int32 {
        do {
            guard let command = arguments.first, commands.contains(command) else { throw AppStoreReleaseError.invalid(usage) }
            var options: [String: String] = [:]
            var index = 1
            while index < arguments.count {
                let key = arguments[index]
                guard ["--app-id", "--project", "--platform", "--issuer-id", "--key-id", "--private-key-path"].contains(key),
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
            else if command != "dry-run" || options["--app-id"] != nil { privateKey = try store.appStoreConnectPrivateKey(profileID: nil) ?? "" }
            else { privateKey = "" }
            let platforms = try parsePlatforms(options["--platform"])
            if command != "dry-run" {
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
            let project = descriptor.makeManagedProject()
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
                replaceActiveReviewVersion: false, testFlight: nil, selectedPlatforms: platforms)
            let targets = try await AppStoreReleaseCoordinator.targets(project: project, configuration: config, validateReviewRequirements: false)
            let manifest = try AppStorePublishingManifest.load(from: folder)
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
    Credentials default to Publishing settings/Keychain. Override with --issuer-id ID --key-id ID --private-key-path PATH.
    Doctor reports current state; missing fields are diagnostics. API/configuration errors exit nonzero.
    """
}
