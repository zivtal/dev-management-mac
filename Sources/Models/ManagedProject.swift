import Foundation

enum ProjectContainerKind: String, Codable, CaseIterable, Identifiable {
    case project
    case workspace

    var id: String { rawValue }

    var xcodebuildFlag: String {
        switch self {
        case .project: "-project"
        case .workspace: "-workspace"
        }
    }
}

enum InstallMethod: String, Codable, CaseIterable, Identifiable {
    case installScript
    case xcodebuild

    var id: String { rawValue }

    var title: String {
        switch self {
        case .installScript: L10n.text("install.sh (recommended)")
        case .xcodebuild: L10n.text("Direct Xcode build")
        }
    }
}

struct ManagedProject: Identifiable, Codable, Equatable {
    var id: UUID
    var displayName: String
    var folderPath: String
    var containerPath: String
    var containerKind: ProjectContainerKind
    var scheme: String
    var configuration: String
    var availableSchemes: [String]
    var availableConfigurations: [String]
    var installMethod: InstallMethod
    var installScriptPath: String?
    var isEnabled: Bool
    var marketingVersion: String?
    var buildNumber: String?

    var folderURL: URL { URL(fileURLWithPath: folderPath, isDirectory: true) }
    var containerURL: URL { URL(fileURLWithPath: containerPath) }

    var versionDisplay: String {
        switch (marketingVersion, buildNumber) {
        case let (marketingVersion?, buildNumber?) where !buildNumber.isEmpty:
            "\(marketingVersion) (\(buildNumber))"
        case let (marketingVersion?, _):
            marketingVersion
        case let (_, buildNumber?):
            buildNumber
        default:
            L10n.text("Unknown")
        }
    }
}

struct ProjectDescriptor: Equatable {
    let displayName: String
    let folderPath: String
    let containerPath: String
    let containerKind: ProjectContainerKind
    let schemes: [String]
    let configurations: [String]
    let installScriptPath: String?

    func makeManagedProject() -> ManagedProject {
        let preferredScheme = Self.preferredScheme(in: schemes, projectName: displayName)
        let preferredConfiguration = configurations.contains("Debug")
            ? "Debug"
            : configurations.first(where: { $0.localizedCaseInsensitiveContains("debug") })
                ?? configurations.first
                ?? "Debug"

        return ManagedProject(
            id: UUID(),
            displayName: displayName,
            folderPath: folderPath,
            containerPath: containerPath,
            containerKind: containerKind,
            scheme: preferredScheme,
            configuration: preferredConfiguration,
            availableSchemes: schemes,
            availableConfigurations: configurations,
            installMethod: installScriptPath == nil ? .xcodebuild : .installScript,
            installScriptPath: installScriptPath,
            isEnabled: true,
            marketingVersion: nil,
            buildNumber: nil
        )
    }

    private static func preferredScheme(in schemes: [String], projectName: String) -> String {
        if let exact = schemes.first(where: { $0.caseInsensitiveCompare(projectName) == .orderedSame }) {
            return exact
        }

        let unsuitableSuffixes = ["tests", "uitests", "widget", "watch", "share"]
        if let applicationScheme = schemes.first(where: { scheme in
            !unsuitableSuffixes.contains(where: { scheme.lowercased().hasSuffix($0) })
        }) {
            return applicationScheme
        }

        return schemes.first ?? projectName
    }
}
