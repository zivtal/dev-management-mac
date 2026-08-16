import Foundation

enum XcodeGenProjectPreparation {
    static func specificationURL(
        for project: ManagedProject,
        fileManager: FileManager = .default
    ) -> URL? {
        guard project.containerKind == .project else { return nil }
        guard project.containerURL.deletingLastPathComponent().standardizedFileURL
            == project.folderURL.standardizedFileURL else { return nil }
        let specificationURL = project.folderURL.appendingPathComponent("project.yml")
        guard fileManager.fileExists(atPath: specificationURL.path) else { return nil }
        return specificationURL
    }

    static func executableURL(fileManager: FileManager = .default) -> URL? {
        let searchPaths = [
            "/opt/homebrew/bin/xcodegen",
            "/usr/local/bin/xcodegen",
            "/usr/bin/xcodegen"
        ] + (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { "\($0)/xcodegen" }
        return searchPaths
            .uniqued()
            .first(where: fileManager.isExecutableFile(atPath:))
            .map(URL.init(fileURLWithPath:))
    }
}

private extension Sequence where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
            .map { $0 }
    }
}

final class XcodeGenProjectPreparationService {
    private let processRunner: ProcessRunner
    private let fileManager: FileManager

    init(
        processRunner: ProcessRunner = ProcessRunner(),
        fileManager: FileManager = .default
    ) {
        self.processRunner = processRunner
        self.fileManager = fileManager
    }

    func prepare(
        project: ManagedProject,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws {
        guard let specificationURL = XcodeGenProjectPreparation.specificationURL(
            for: project,
            fileManager: fileManager
        ) else {
            return
        }
        guard let executableURL = XcodeGenProjectPreparation.executableURL(
            fileManager: fileManager
        ) else {
            throw XcodeGenProjectPreparationError.executableUnavailable
        }

        onOutput(L10n.text("Regenerating the Xcode project from project.yml…\n"))
        _ = try await processRunner.runAndRequireSuccess(
            executable: executableURL,
            arguments: ["generate", "--spec", specificationURL.path],
            workingDirectory: project.folderURL,
            onOutput: onOutput
        )
        guard fileManager.fileExists(atPath: project.containerPath) else {
            throw XcodeGenProjectPreparationError.generatedContainerMissing(
                project.containerURL.lastPathComponent
            )
        }
        onOutput(L10n.text("The XcodeGen project is up to date.\n"))
    }
}

enum XcodeGenProjectPreparationError: LocalizedError {
    case executableUnavailable
    case generatedContainerMissing(String)

    var errorDescription: String? {
        switch self {
        case .executableUnavailable:
            L10n.text("project.yml was found, but XcodeGen is not installed. Install XcodeGen or regenerate the Xcode project before building.")
        case .generatedContainerMissing(let name):
            L10n.format("XcodeGen completed, but it did not create the selected project %@.", name)
        }
    }
}
