import Foundation

actor ProjectIconService {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func iconURL(for project: ManagedProject) -> URL? {
        guard let enumerator = fileManager.enumerator(
            at: project.folderURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return nil
        }

        var candidates: [(url: URL, score: Int)] = []
        for case let url as URL in enumerator {
            let relativeDepth = url.pathComponents.count - project.folderURL.pathComponents.count
            if relativeDepth > 9 {
                enumerator.skipDescendants()
                continue
            }

            if url.pathExtension.lowercased() == "appiconset" {
                if let iconURL = bestImage(in: url) {
                    candidates.append((iconURL, score(for: url, project: project)))
                }
                enumerator.skipDescendants()
            }
        }

        if let best = candidates.max(by: { lhs, rhs in
            lhs.score == rhs.score
                ? lhs.url.path.localizedStandardCompare(rhs.url.path) == .orderedDescending
                : lhs.score < rhs.score
        }) {
            return best.url
        }

        return fallbackIconURL(in: project.folderURL)
    }

    private func bestImage(in appIconSetURL: URL) -> URL? {
        let contentsURL = appIconSetURL.appendingPathComponent("Contents.json")
        guard let data = try? Data(contentsOf: contentsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let images = json["images"] as? [[String: Any]]
        else {
            return nil
        }

        let rankedImages = images.compactMap { image -> (url: URL, pixels: Double)? in
            guard let filename = image["filename"] as? String, !filename.isEmpty else { return nil }
            let url = appIconSetURL.appendingPathComponent(filename)
            guard fileManager.fileExists(atPath: url.path) else { return nil }

            let size = (image["size"] as? String)?
                .split(separator: "x")
                .first
                .flatMap { Double($0) } ?? 0
            let scaleText = (image["scale"] as? String)?.replacingOccurrences(of: "x", with: "")
            let scale = scaleText.flatMap(Double.init) ?? 1
            return (url, size * scale)
        }

        return rankedImages.max { lhs, rhs in lhs.pixels < rhs.pixels }?.url
    }

    private func score(for appIconSetURL: URL, project: ManagedProject) -> Int {
        let path = appIconSetURL.path.lowercased()
        var score = appIconSetURL.lastPathComponent.lowercased() == "appicon.appiconset" ? 200 : 0
        if path.contains(project.scheme.lowercased()) { score += 300 }
        if path.contains("watch") { score -= 1_000 }
        if path.contains("widget") || path.contains("share") { score -= 500 }
        return score
    }

    private func fallbackIconURL(in folderURL: URL) -> URL? {
        guard let enumerator = fileManager.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return nil
        }

        let supportedExtensions = Set(["png", "jpg", "jpeg", "heic", "svg"])
        for case let url as URL in enumerator {
            let relativeDepth = url.pathComponents.count - folderURL.pathComponents.count
            if relativeDepth > 7 {
                enumerator.skipDescendants()
                continue
            }
            let filename = url.deletingPathExtension().lastPathComponent.lowercased()
            let path = url.path.lowercased()
            if filename == "appicon",
               supportedExtensions.contains(url.pathExtension.lowercased()),
               !path.contains("watch"), !path.contains("widget"), !path.contains("share") {
                return url
            }
        }
        return nil
    }
}
