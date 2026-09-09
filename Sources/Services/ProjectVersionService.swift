import Foundation

struct ProjectVersion: Equatable {
    let marketingVersion: String?
    let buildNumber: String?
}

final class ProjectVersionService {
    private static let maximumSearchDepth = 4
    private static let packageExtensions: Set<String> = [
        "xcodeproj", "xcworkspace", "xcassets", "app", "framework", "bundle", "playground"
    ]

    private let fileManager: FileManager
    private let processRunner: any ProcessRunning
    private let git = URL(fileURLWithPath: "/usr/bin/git")

    init(fileManager: FileManager = .default, processRunner: any ProcessRunning = ProcessRunner()) {
        self.fileManager = fileManager
        self.processRunner = processRunner
    }

    /// The version committed at the tip of `branch`, read straight from Git
    /// without touching the working copy or any checkout. `nil` when the
    /// folder is not a Git repository or the branch does not exist there.
    func currentVersion(for project: ManagedProject, branch: String) async -> ProjectVersion? {
        let repository = project.folderURL
        guard let reference = await resolveReference(branch, in: repository),
              let listing = await gitOutput(["ls-tree", "-r", "--name-only", "--full-tree", reference], in: repository)
        else {
            return nil
        }
        let paths = listing.split(whereSeparator: \.isNewline).map(String.init).filter(Self.isSearchable)

        var configurationPaths = paths.filter { $0.hasSuffix(".xcconfig") }
        configurationPaths.sort { lhs, rhs in
            let lhsIsVersion = (lhs as NSString).lastPathComponent.localizedCaseInsensitiveContains("version")
            let rhsIsVersion = (rhs as NSString).lastPathComponent.localizedCaseInsensitiveContains("version")
            if lhsIsVersion != rhsIsVersion { return lhsIsVersion }
            return lhs < rhs
        }
        if project.containerKind == .project,
           let containerPath = Self.relativePath(of: project.containerURL, in: repository) {
            configurationPaths.append(containerPath + "/project.pbxproj")
        }

        var marketingVersion: String?
        var buildNumber: String?
        for path in configurationPaths {
            guard let contents = await gitOutput(["show", "\(reference):\(path)"], in: repository) else { continue }
            marketingVersion = marketingVersion ?? value(for: "MARKETING_VERSION", in: contents)
            buildNumber = buildNumber ?? value(for: "CURRENT_PROJECT_VERSION", in: contents)
            if marketingVersion != nil, buildNumber != nil { break }
        }

        if marketingVersion == nil || buildNumber == nil {
            for path in paths where (path as NSString).lastPathComponent == "Info.plist" {
                guard let contents = await gitOutput(["show", "\(reference):\(path)"], in: repository),
                      let plistVersion = version(fromInfoPlist: Data(contents.utf8)) else { continue }
                marketingVersion = marketingVersion ?? plistVersion.marketingVersion
                buildNumber = buildNumber ?? plistVersion.buildNumber
                break
            }
        }

        return ProjectVersion(marketingVersion: marketingVersion, buildNumber: buildNumber)
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
                  let plistVersion = version(fromInfoPlist: data)
            else {
                continue
            }
            return plistVersion
        }
        return ProjectVersion(marketingVersion: nil, buildNumber: nil)
    }

    /// `nil` when the plist carries neither literal version key.
    private func version(fromInfoPlist data: Data) -> ProjectVersion? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }
        let marketingVersion = literalVersion(plist["CFBundleShortVersionString"] as? String)
        let buildNumber = literalVersion(plist["CFBundleVersion"] as? String)
        guard marketingVersion != nil || buildNumber != nil else { return nil }
        return ProjectVersion(marketingVersion: marketingVersion, buildNumber: buildNumber)
    }

    // MARK: - Git helpers

    /// Mirrors the on-disk search: at most four levels deep, no hidden
    /// entries, and nothing inside bundles such as `.xcodeproj`.
    private static func isSearchable(_ path: String) -> Bool {
        let components = path.split(separator: "/").map(String.init)
        guard components.count <= maximumSearchDepth else { return false }
        guard !components.contains(where: { $0.hasPrefix(".") }) else { return false }
        return !components.dropLast().contains {
            packageExtensions.contains(($0 as NSString).pathExtension.lowercased())
        }
    }

    private static func relativePath(of url: URL, in repository: URL) -> String? {
        let rootComponents = repository.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let targetComponents = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard targetComponents.count > rootComponents.count,
              Array(targetComponents.prefix(rootComponents.count)) == rootComponents else {
            return nil
        }
        return targetComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    private func resolveReference(_ branch: String, in repository: URL) async -> String? {
        for candidate in ["refs/heads/\(branch)", "refs/remotes/\(branch)"] {
            let result = try? await processRunner.run(
                executable: git,
                arguments: ["-C", repository.path, "show-ref", "--verify", "--quiet", candidate],
                workingDirectory: nil, additionalEnvironment: [:], standardInput: nil,
                onOutput: nil, terminateWhenOutput: nil
            )
            if result?.terminationStatus == 0 { return candidate }
        }
        return nil
    }

    private func gitOutput(_ arguments: [String], in repository: URL) async -> String? {
        guard let result = try? await processRunner.run(
            executable: git,
            arguments: ["-C", repository.path] + arguments,
            workingDirectory: nil, additionalEnvironment: [:], standardInput: nil,
            onOutput: nil, terminateWhenOutput: nil
        ), result.terminationStatus == 0 else {
            return nil
        }
        return result.output
    }

    private func literalVersion(_ value: String?) -> String? {
        guard let value, !value.isEmpty, !value.contains("$(") else { return nil }
        return value
    }
}
