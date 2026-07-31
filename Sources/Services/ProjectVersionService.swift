import Foundation

struct ProjectVersion: Equatable {
    let marketingVersion: String?
    let buildNumber: String?
}

final class ProjectVersionService {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func currentVersion(for project: ManagedProject) -> ProjectVersion {
        let folderURL = project.folderURL
        let configurationFiles = versionConfigurationFiles(in: folderURL)
        let projectFile = project.containerKind == .project
            ? project.containerURL.appendingPathComponent("project.pbxproj")
            : nil
        let candidates = configurationFiles + [projectFile].compactMap { $0 }

        var marketingVersion: String?
        var buildNumber: String?
        for url in candidates {
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            marketingVersion = marketingVersion ?? value(for: "MARKETING_VERSION", in: contents)
            buildNumber = buildNumber ?? value(for: "CURRENT_PROJECT_VERSION", in: contents)
            if marketingVersion != nil, buildNumber != nil { break }
        }

        if marketingVersion == nil || buildNumber == nil {
            let plistVersion = versionFromInfoPlist(in: folderURL)
            marketingVersion = marketingVersion ?? plistVersion.marketingVersion
            buildNumber = buildNumber ?? plistVersion.buildNumber
        }

        return ProjectVersion(marketingVersion: marketingVersion, buildNumber: buildNumber)
    }

    private func versionConfigurationFiles(in folderURL: URL) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var files: [URL] = []
        for case let url as URL in enumerator {
            let relativeDepth = url.pathComponents.count - folderURL.pathComponents.count
            if relativeDepth > 4 {
                enumerator.skipDescendants()
                continue
            }
            if url.pathExtension == "xcconfig" {
                files.append(url)
            }
        }

        return files.sorted { lhs, rhs in
            let lhsIsVersion = lhs.lastPathComponent.localizedCaseInsensitiveContains("version")
            let rhsIsVersion = rhs.lastPathComponent.localizedCaseInsensitiveContains("version")
            if lhsIsVersion != rhsIsVersion { return lhsIsVersion }
            return lhs.path < rhs.path
        }
    }

    private func value(for key: String, in contents: String) -> String? {
        for sourceLine in contents.components(separatedBy: .newlines) {
            let line = sourceLine.components(separatedBy: "//").first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard line.hasPrefix(key), let equalsIndex = line.firstIndex(of: "=") else { continue }
            let foundKey = line[..<equalsIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            guard foundKey == key else { continue }
            var value = line[line.index(after: equalsIndex)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ";\"'"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, !value.contains("$(") else { continue }
            if let commentIndex = value.firstIndex(of: "#") {
                value = String(value[..<commentIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private func versionFromInfoPlist(in folderURL: URL) -> ProjectVersion {
        guard let enumerator = fileManager.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return ProjectVersion(marketingVersion: nil, buildNumber: nil)
        }

        for case let url as URL in enumerator {
            let relativeDepth = url.pathComponents.count - folderURL.pathComponents.count
            if relativeDepth > 4 {
                enumerator.skipDescendants()
                continue
            }
            guard url.lastPathComponent == "Info.plist",
                  let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else {
                continue
            }
            let marketingVersion = literalVersion(plist["CFBundleShortVersionString"] as? String)
            let buildNumber = literalVersion(plist["CFBundleVersion"] as? String)
            if marketingVersion != nil || buildNumber != nil {
                return ProjectVersion(marketingVersion: marketingVersion, buildNumber: buildNumber)
            }
        }
        return ProjectVersion(marketingVersion: nil, buildNumber: nil)
    }

    private func literalVersion(_ value: String?) -> String? {
        guard let value, !value.isEmpty, !value.contains("$(") else { return nil }
        return value
    }
}
