import Foundation

struct AppStoreReviewAssetService {
    private static let supportedExtensions: Set<String> = [
        "doc", "docx", "mp4", "mov", "pdf", "rtf", "txt", "zip"
    ]

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func discover(project: ManagedProject, configuredPaths: [String]) -> [URL] {
        var candidates = configuredPaths.map {
            resolvedURL(for: $0, relativeTo: project.folderURL)
        }
        candidates.append(
            project.folderURL
                .appendingPathComponent("AppStore", isDirectory: true)
                .appendingPathComponent("ReviewAttachments", isDirectory: true)
        )

        var seen = Set<String>()
        return candidates
            .flatMap(reviewAssets(at:))
            .filter { seen.insert($0.standardizedFileURL.path).inserted }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func resolvedURL(for path: String, relativeTo root: URL) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        return URL(fileURLWithPath: expanded, relativeTo: root).standardizedFileURL
    }

    private func reviewAssets(at url: URL) -> [URL] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }
        if !isDirectory.boolValue {
            return isSupported(url) ? [url] : []
        }
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        return enumerator.compactMap { value in
            guard let fileURL = value as? URL, isSupported(fileURL) else { return nil }
            return fileURL
        }
    }

    private func isSupported(_ url: URL) -> Bool {
        Self.supportedExtensions.contains(url.pathExtension.lowercased())
    }
}
