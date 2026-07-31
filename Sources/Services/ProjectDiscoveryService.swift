import Foundation

enum ProjectDiscoveryError: LocalizedError {
    case folderDoesNotExist
    case noXcodeContainer
    case noSchemes
    case malformedXcodeResponse

    var errorDescription: String? {
        switch self {
        case .folderDoesNotExist:
            L10n.text("The selected folder does not exist.")
        case .noXcodeContainer:
            L10n.text("No .xcodeproj or .xcworkspace was found in the selected folder.")
        case .noSchemes:
            L10n.text("No shared schemes were found. Mark a scheme as Shared in Xcode.")
        case .malformedXcodeResponse:
            L10n.text("Could not read the project details from Xcode.")
        }
    }
}

final class ProjectDiscoveryService {
    private struct XcodeList: Decodable {
        struct Summary: Decodable {
            let name: String?
            let configurations: [String]?
            let schemes: [String]?
        }

        let project: Summary?
        let workspace: Summary?
    }

    private let processRunner: ProcessRunner
    private let fileManager: FileManager

    init(processRunner: ProcessRunner = ProcessRunner(), fileManager: FileManager = .default) {
        self.processRunner = processRunner
        self.fileManager = fileManager
    }

    func discover(folderURL: URL) async throws -> ProjectDescriptor {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folderURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ProjectDiscoveryError.folderDoesNotExist
        }

        let contents = try fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        let workspace = contents
            .filter { $0.pathExtension == "xcworkspace" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first
        let project = contents
            .filter { $0.pathExtension == "xcodeproj" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first

        let containerURL: URL
        let containerKind: ProjectContainerKind
        if let workspace {
            containerURL = workspace
            containerKind = .workspace
        } else if let project {
            containerURL = project
            containerKind = .project
        } else {
            throw ProjectDiscoveryError.noXcodeContainer
        }

        let result = try await processRunner.runAndRequireSuccess(
            executable: URL(fileURLWithPath: "/usr/bin/xcodebuild"),
            arguments: [containerKind.xcodebuildFlag, containerURL.path, "-list", "-json"],
            workingDirectory: folderURL
        )

        guard let data = result.output.data(using: .utf8),
              let list = try? JSONDecoder().decode(XcodeList.self, from: data),
              let summary = list.project ?? list.workspace
        else {
            throw ProjectDiscoveryError.malformedXcodeResponse
        }

        let schemes = (summary.schemes ?? []).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        guard !schemes.isEmpty else { throw ProjectDiscoveryError.noSchemes }

        let configurations = (summary.configurations ?? ["Debug"]).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        let scriptURL = folderURL.appendingPathComponent("install.sh")
        let scriptPath = fileManager.fileExists(atPath: scriptURL.path) ? scriptURL.path : nil
        let displayName = summary.name?.trimmingCharacters(in: .whitespacesAndNewlines)

        return ProjectDescriptor(
            displayName: (displayName?.isEmpty == false ? displayName : nil)
                ?? containerURL.deletingPathExtension().lastPathComponent,
            folderPath: folderURL.standardizedFileURL.path,
            containerPath: containerURL.standardizedFileURL.path,
            containerKind: containerKind,
            schemes: schemes,
            configurations: configurations,
            installScriptPath: scriptPath
        )
    }
}
