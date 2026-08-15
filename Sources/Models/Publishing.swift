import Foundation

struct AppStoreMetadata: Codable, Equatable, Sendable {
    let description: String
    let keywords: String
    let promotionalText: String
    let whatsNew: String

    func normalized() -> AppStoreMetadata {
        AppStoreMetadata(
            description: Self.limited(description, characters: 4_000),
            keywords: Self.limitedUTF8(keywords, bytes: 100),
            promotionalText: Self.limited(promotionalText, characters: 170),
            whatsNew: Self.limited(whatsNew, characters: 4_000)
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

struct PublishingConfiguration: Sendable {
    let openAIAPIKey: String
    let openAIModel: String
    let appStoreConnectIssuerID: String
    let appStoreConnectKeyID: String
    let appStoreConnectPrivateKey: String
    let locale: String
    let copyright: String
    let supportURL: String
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
        case generatingMetadata
        case collectingScreenshots
        case archiving
        case uploadingMetadata
        case uploadingScreenshots
        case uploadingBuild
        case waitingForBuild
        case submitting

        var title: String {
            switch self {
            case .preparing: L10n.text("Preparing App Store publication…")
            case .generatingMetadata: L10n.text("Generating App Store description…")
            case .collectingScreenshots: L10n.text("Collecting App Store screenshots…")
            case .archiving: L10n.text("Archiving and exporting the application…")
            case .uploadingMetadata: L10n.text("Updating App Store metadata…")
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
