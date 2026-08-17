import Foundation

enum AppStorePrivacyPublishingError: LocalizedError {
    case fastlaneUnavailable
    case missingAppleID
    case missingSession
    case collectedDataNeedsDetails

    var errorDescription: String? {
        switch self {
        case .fastlaneUnavailable:
            L10n.text("Automatic App Privacy publishing requires Fastlane. Install it with Homebrew, then reopen Publish.")
        case .missingAppleID:
            L10n.text("Enter the App Store Connect Apple ID for App Privacy automation in Publishing settings.")
        case .missingSession:
            L10n.text("Save a Fastlane App Store Connect session in Publishing settings before publishing App Privacy answers.")
        case .collectedDataNeedsDetails:
            L10n.text("Apps that collect data require Apple purpose, linking, and tracking answers. Complete App Privacy in App Store Connect for this app.")
        }
    }
}

struct FastlaneAppPrivacyUsage: Codable, Equatable, Sendable {
    var category: String? = nil
    var purposes: [String]? = nil
    var dataProtections: [String]

    private enum CodingKeys: String, CodingKey {
        case category
        case purposes
        case dataProtections = "data_protections"
    }
}

final class AppStorePrivacyPublishingService {
    typealias OutputHandler = @Sendable (String) -> Void

    private let processRunner: ProcessRunner
    private let fileManager: FileManager

    init(
        processRunner: ProcessRunner = ProcessRunner(),
        fileManager: FileManager = .default
    ) {
        self.processRunner = processRunner
        self.fileManager = fileManager
    }

    static func executableURL(fileManager: FileManager = .default) -> URL? {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let searchPaths = [
            "/opt/homebrew/bin/fastlane",
            "/usr/local/bin/fastlane",
            "\(home)/.rbenv/shims/fastlane",
            "\(home)/.asdf/shims/fastlane"
        ] + (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { "\($0)/fastlane" }
        var seen = Set<String>()
        return searchPaths
            .filter { seen.insert($0).inserted }
            .first(where: fileManager.isExecutableFile(atPath:))
            .map(URL.init(fileURLWithPath:))
    }

    static func payload(for draft: AppStorePrivacyDraft) throws -> [FastlaneAppPrivacyUsage] {
        guard !draft.collectsData else {
            throw AppStorePrivacyPublishingError.collectedDataNeedsDetails
        }
        return [FastlaneAppPrivacyUsage(dataProtections: ["DATA_NOT_COLLECTED"])]
    }

    static func normalizedSession(_ value: String) -> String? {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("export FASTLANE_SESSION=") {
            result.removeFirst("export FASTLANE_SESSION=".count)
        } else if result.hasPrefix("FASTLANE_SESSION=") {
            result.removeFirst("FASTLANE_SESSION=".count)
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.count >= 2,
           let first = result.first,
           let last = result.last,
           (first == "'" && last == "'") || (first == "\"" && last == "\"") {
            result.removeFirst()
            result.removeLast()
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    func publish(
        draft: AppStorePrivacyDraft,
        bundleIdentifier: String,
        appleID: String?,
        teamID: String?,
        session: String?,
        onOutput: @escaping OutputHandler
    ) async throws {
        guard let executable = Self.executableURL(fileManager: fileManager) else {
            throw AppStorePrivacyPublishingError.fastlaneUnavailable
        }
        guard let appleID = appleID?.nilIfEmpty else {
            throw AppStorePrivacyPublishingError.missingAppleID
        }
        guard let session = session.flatMap(Self.normalizedSession) else {
            throw AppStorePrivacyPublishingError.missingSession
        }
        let payload = try Self.payload(for: draft)
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("DevManagement-AppPrivacy-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let payloadURL = temporaryDirectory.appendingPathComponent("app-privacy-details.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(payload).write(to: payloadURL, options: .atomic)

        onOutput(L10n.text("Publishing the reviewed App Privacy answers through the authenticated Fastlane session…\n"))
        var arguments = [
            "run", "upload_app_privacy_details_to_app_store",
            "username:\(appleID)",
            "app_identifier:\(bundleIdentifier)",
            "json_path:\(payloadURL.path)",
            "skip_publish:false"
        ]
        if let teamID = teamID?.nilIfEmpty {
            arguments.append("team_id:\(teamID)")
        }
        _ = try await processRunner.runAndRequireSuccess(
            executable: executable,
            arguments: arguments,
            workingDirectory: temporaryDirectory,
            additionalEnvironment: [
                "FASTLANE_SESSION": session,
                "FASTLANE_IS_INTERACTIVE": "false",
                "SPACESHIP_ONLY_ALLOW_INTERACTIVE_2FA": "true",
                "FASTLANE_SKIP_UPDATE_CHECK": "true",
                "FASTLANE_OPT_OUT_USAGE": "true",
                "FASTLANE_DISABLE_COLORS": "1"
            ],
            onOutput: onOutput
        )
        onOutput(L10n.text("App Privacy answers were published in App Store Connect.\n"))
    }
}
