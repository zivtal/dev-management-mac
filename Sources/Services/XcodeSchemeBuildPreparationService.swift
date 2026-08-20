import Foundation

struct PreparedXcodeScheme {
    let name: String
    let removedActionTitles: [String]
    let temporaryURL: URL?

    func removeTemporaryFile(fileManager: FileManager = .default) {
        guard let temporaryURL else { return }
        try? fileManager.removeItem(at: temporaryURL)
    }
}

enum XcodeSchemeBuildPreparationError: LocalizedError {
    case sharedSchemeNotFound(String)

    var errorDescription: String? {
        switch self {
        case .sharedSchemeNotFound(let scheme):
            L10n.format(
                "The shared Xcode scheme %@ could not be found, so its build actions could not be checked.",
                scheme
            )
        }
    }
}

final class XcodeSchemeBuildPreparationService {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func prepare(project: ManagedProject) throws -> PreparedXcodeScheme {
        guard let sourceURL = sharedSchemeURL(for: project) else {
            throw XcodeSchemeBuildPreparationError.sharedSchemeNotFound(project.scheme)
        }
        let document = try XMLDocument(contentsOf: sourceURL, options: [.nodePreserveAll])
        let executionActions = try document.nodes(forXPath: "//ExecutionAction")
            .compactMap { $0 as? XMLElement }
        var removedTitles: [String] = []

        for action in executionActions {
            guard let content = action.elements(forName: "ActionContent").first else { continue }
            let title = content.attribute(forName: "title")?.stringValue?.nilIfEmpty
                ?? L10n.text("Scheme script")
            removedTitles.append(title)
            action.detach()
        }

        guard !removedTitles.isEmpty else {
            return PreparedXcodeScheme(
                name: project.scheme,
                removedActionTitles: [],
                temporaryURL: nil
            )
        }

        for containerName in ["PreActions", "PostActions"] {
            for case let container as XMLElement in try document.nodes(forXPath: "//\(containerName)")
            where container.elements(forName: "ExecutionAction").isEmpty {
                container.detach()
            }
        }

        let safeBaseName = project.scheme.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "-",
            options: .regularExpression
        )
        let preparedName = "DevelopmentManagement-\(safeBaseName)-\(UUID().uuidString)"
        let temporaryURL = sourceURL.deletingLastPathComponent()
            .appendingPathComponent("\(preparedName).xcscheme")
        try document.xmlData(options: [.nodePrettyPrint]).write(to: temporaryURL, options: .atomic)
        return PreparedXcodeScheme(
            name: preparedName,
            removedActionTitles: removedTitles,
            temporaryURL: temporaryURL
        )
    }

    private func sharedSchemeURL(for project: ManagedProject) -> URL? {
        let directURL = project.containerURL
            .appendingPathComponent("xcshareddata/xcschemes", isDirectory: true)
            .appendingPathComponent("\(project.scheme).xcscheme")
        if fileManager.fileExists(atPath: directURL.path) {
            return directURL
        }

        guard let enumerator = fileManager.enumerator(
            at: project.folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        let expectedName = "\(project.scheme).xcscheme"
        for case let candidate as URL in enumerator {
            guard candidate.lastPathComponent == expectedName,
                  candidate.path.contains("/xcshareddata/xcschemes/") else { continue }
            return candidate
        }
        return nil
    }
}
