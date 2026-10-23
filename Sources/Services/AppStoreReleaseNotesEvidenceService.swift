import Foundation

struct AppStoreReleaseNotesEvidence: Equatable, Sendable {
    enum Source: String, Equatable, Sendable {
        case readme
        case git
        case combined
    }

    let source: Source
    let sourceDescription: String
    let content: String
}

final class AppStoreReleaseNotesEvidenceService {
    private static let maximumEvidenceCharacters = 120_000

    private let processRunner: ProcessRunner
    private let fileManager: FileManager

    init(
        processRunner: ProcessRunner = ProcessRunner(),
        fileManager: FileManager = .default
    ) {
        self.processRunner = processRunner
        self.fileManager = fileManager
    }

    /// The release notes documented in the README and the commits made since
    /// the approved version answer different halves of "what changed", so both
    /// are sent when both exist.
    func evidence(
        project: ManagedProject,
        previousVersion: String,
        currentVersion: String
    ) async throws -> AppStoreReleaseNotesEvidence? {
        let readme = readmeEvidence(project: project, currentVersion: currentVersion)
        let git = try await gitEvidence(
            projectDirectory: project.folderURL,
            previousVersion: previousVersion
        )
        guard let readme else { return git }
        guard let git else { return readme }
        return Self.combining(readme: readme, git: git)
    }

    static func combining(
        readme: AppStoreReleaseNotesEvidence,
        git: AppStoreReleaseNotesEvidence
    ) -> AppStoreReleaseNotesEvidence {
        // Split the budget so a long README cannot crowd out the commits.
        let readmeContent = String(readme.content.prefix(12_000))
        let gitContent = String(
            git.content.prefix(maximumEvidenceCharacters - readmeContent.count)
        )
        return AppStoreReleaseNotesEvidence(
            source: .combined,
            sourceDescription: L10n.format(
                "%@ and %@",
                readme.sourceDescription,
                git.sourceDescription
            ),
            content: """
            --- Release notes documented in \(readme.sourceDescription) ---
            \(readmeContent)

            \(gitContent)
            """
        )
    }

    private func readmeEvidence(
        project: ManagedProject,
        currentVersion: String
    ) -> AppStoreReleaseNotesEvidence? {
        guard let readme = readmeURL(in: project.folderURL),
              let text = try? String(contentsOf: readme, encoding: .utf8),
              let section = Self.releaseSection(in: text, currentVersion: currentVersion) else {
            return nil
        }
        return AppStoreReleaseNotesEvidence(
            source: .readme,
            sourceDescription: readme.lastPathComponent,
            content: String(section.prefix(Self.maximumEvidenceCharacters))
        )
    }

    static func releaseSection(in readme: String, currentVersion: String) -> String? {
        let lines = readme.components(separatedBy: .newlines)
        let headings = lines.enumerated().compactMap { index, line -> (Int, Int, String)? in
            guard let level = headingLevel(line) else { return nil }
            return (index, level, line)
        }
        let escapedVersion = NSRegularExpression.escapedPattern(for: currentVersion)
        let versionPattern = "(?i)(^|[^0-9A-Za-z])v?\(escapedVersion)($|[^0-9A-Za-z])"
        let releaseNames = ["what's new", "what’s new", "release notes", "recent changes", "changelog"]
        let selected = headings.first(where: { heading in
            heading.2.range(of: versionPattern, options: .regularExpression) != nil
        }) ?? headings.first(where: { heading in
            let normalized = heading.2.lowercased()
            return releaseNames.contains(where: normalized.contains)
        })
        guard let selected else { return nil }
        let end = headings.first(where: {
            $0.0 > selected.0 && $0.1 <= selected.1
        })?.0 ?? lines.count
        let sectionLines = Array(lines[selected.0..<end])
        guard sectionLines.dropFirst().contains(where: {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else { return nil }
        return sectionLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func headingLevel(_ line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let count = trimmed.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(count), trimmed.dropFirst(count).first?.isWhitespace == true else {
            return nil
        }
        return count
    }

    private func readmeURL(in directory: URL) -> URL? {
        (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ))?.first(where: { $0.lastPathComponent.caseInsensitiveCompare("README.md") == .orderedSame })
    }

    private func gitEvidence(
        projectDirectory: URL,
        previousVersion: String
    ) async throws -> AppStoreReleaseNotesEvidence? {
        guard await git(["rev-parse", "--is-inside-work-tree"], in: projectDirectory)?
            .trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
            return nil
        }
        guard let resolved = await baselineReference(
            previousVersion: previousVersion,
            projectDirectory: projectDirectory
        ) else {
            // Recent commits cannot establish what changed since an approved release.
            throw OpenAIStoreMetadataError.missingReleaseBaseline(previousVersion)
        }
        let baseline = resolved.reference

        // Keep the entire interval, oldest first, without per-commit stats drowning
        // out the commit that introduced a feature before its subsequent fixes.
        let history = await git([
            "log", "--reverse", "--date=short", "--pretty=format:%h%x09%ad%x09%s",
            "\(baseline)..HEAD", "--", "."
        ], in: projectDirectory) ?? ""
        let changes = await git([
            "diff", "--no-ext-diff", "--no-textconv", "--name-status", baseline, "--", "."
        ], in: projectDirectory) ?? ""
        let status = await git(["status", "--short"], in: projectDirectory) ?? ""
        let patches = await sourceChanges(since: baseline, in: projectDirectory)
        let content = """
        Previous approved App Store version: \(previousVersion)
        Git baseline: \(baseline)
        \(resolved.disclosure.map { "Baseline note: \($0)\n" } ?? "")Comparison: approved baseline through HEAD and the current tracked working tree.
        A = added since approval, M = modified, D = removed. Newly added features take priority over later refinements.

        --- Commit history across the full release interval (oldest first) ---
        \(Self.bounded(history, limit: 45_000))

        --- Net changed files since approval (including staged and unstaged changes) ---
        \(Self.bounded(changes, limit: 20_000))

        --- Source changes from the approved baseline to now ---
        \(patches)

        --- Current working-tree status (untracked files have no baseline diff) ---
        \(Self.bounded(status.isEmpty ? "Clean" : status, limit: 4_000))
        """
        guard !history.isEmpty || !changes.isEmpty || !status.isEmpty else { return nil }
        return AppStoreReleaseNotesEvidence(
            source: .git,
            sourceDescription: resolved.sourceDescription,
            content: content
        )
    }

    private func sourceChanges(since baseline: String, in directory: URL) async -> String {
        let paths = await git([
            "diff", "--no-ext-diff", "--no-textconv", "--name-only", "-z", baseline, "--", "."
        ], in: directory)?.split(separator: "\0").map(String.init).filter { path in
            let url = URL(fileURLWithPath: path)
            return ["swift", "m", "mm", "h", "js", "jsx", "ts", "tsx", "dart", "strings"].contains(url.pathExtension)
                && !path.split(separator: "/").contains(where: {
                    OpenAIStoreMetadataService.isExcludedDirectory(String($0))
                })
                && !OpenAIStoreMetadataService.isSensitiveFile(url.lastPathComponent)
        } ?? []
        guard !paths.isEmpty else { return "No supported source changes." }
        let perFileBudget = min(4_000, 34_000 / paths.count)
        // The full file inventory above still covers every path if excerpts cannot fit.
        guard perFileBudget >= 200 else { return "Source excerpts omitted due to size; use the full-interval history and file inventory." }
        var sections: [String] = []
        for path in paths {
            guard let patch = await git([
                "diff", "--no-ext-diff", "--no-textconv", "--unified=2", baseline, "--", path
            ], in: directory) else { continue }
            sections.append(Self.bounded(patch, limit: perFileBudget))
        }
        return sections.joined(separator: "\n")
    }

    /// Preserve both ends and disclose limits instead of silently keeping only
    /// the most recent changes or allowing a single large file to consume the budget.
    static func bounded(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text.isEmpty ? "None" : text }
        let marker = "\n[Middle omitted due to evidence size limit]\n"
        let half = max(0, (limit - marker.count) / 2)
        return String(text.prefix(half)) + marker + String(text.suffix(half))
    }

    /// A Git reference that ends the approved release, plus how it was chosen.
    private struct ReleaseBaseline {
        let reference: String
        let sourceDescription: String
        /// Set when the approved version itself was never committed and the
        /// baseline is the nearest committed version before it.
        let disclosure: String?

        static func exact(_ reference: String, previousVersion: String) -> ReleaseBaseline {
            ReleaseBaseline(
                reference: reference,
                sourceDescription: L10n.format(
                    "Git changes after approved version %@ (%@)", previousVersion, reference
                ),
                disclosure: nil
            )
        }
    }

    private func baselineReference(
        previousVersion: String,
        projectDirectory: URL
    ) async -> ReleaseBaseline? {
        let tags = await git(["tag", "--list"], in: projectDirectory)?
            .components(separatedBy: .newlines).filter { !$0.isEmpty } ?? []
        let matchingTags = tags.filter { tag in
            let tail = tag.split(separator: "/").last.map(String.init) ?? tag
            return [previousVersion, "v\(previousVersion)", "release-\(previousVersion)"].contains {
                tail.caseInsensitiveCompare($0) == .orderedSame
            }
        }.sorted { lhs, rhs in
            if lhs.contains("/") != rhs.contains("/") { return !lhs.contains("/") }
            return lhs < rhs
        }
        for tag in matchingTags {
            // Ignore matching releases on unrelated branches and resolve the actual
            // spelling of tags (Git references are case sensitive).
            if await gitCommandSucceeded([
                "merge-base", "--is-ancestor", "refs/tags/\(tag)", "HEAD"
            ], in: projectDirectory) {
                return .exact(tag, previousVersion: previousVersion)
            }
        }

        // Only actual version declarations qualify. README, publishing metadata,
        // lockfiles, and arbitrary occurrences of the number are not release markers.
        let paths = await git(["ls-tree", "-r", "--name-only", "HEAD", "--", "."], in: projectDirectory)?
            .components(separatedBy: .newlines).filter { path in
                let url = URL(fileURLWithPath: path)
                return (url.pathExtension == "xcconfig" || url.lastPathComponent == "project.yml"
                    || url.lastPathComponent == "project.pbxproj" || url.lastPathComponent == "Info.plist")
                    && !path.split(separator: "/").contains(where: {
                        OpenAIStoreMetadataService.isExcludedDirectory(String($0))
                    })
            }.sorted { lhs, rhs in
                func priority(_ path: String) -> Int {
                    if path.lowercased().hasSuffix("version.xcconfig") { return 0 }
                    if path.hasSuffix(".xcconfig") { return 1 }
                    if path.hasSuffix("project.yml") { return 2 }
                    return 3
                }
                return priority(lhs) == priority(rhs) ? lhs < rhs : priority(lhs) < priority(rhs)
            } ?? []
        for path in paths {
            let commits = await git([
                "log", "--first-parent", "--format=%H", "-G\(NSRegularExpression.escapedPattern(for: previousVersion))",
                "HEAD", "--", path
            ], in: projectDirectory)?.split(whereSeparator: \.isNewline).map(String.init) ?? []
            for commit in commits {
                if let contents = await git(["show", "\(commit):\(path)"], in: projectDirectory),
                   Self.containsMarketingVersion(previousVersion, in: contents) {
                    return .exact(commit, previousVersion: previousVersion)
                }
                // A delivery commit can bump the version and add a new feature
                // together. Its parent is the final snapshot of the approved version.
                if let contents = await git(["show", "\(commit)^:\(path)"], in: projectDirectory),
                   Self.containsMarketingVersion(previousVersion, in: contents),
                   let parent = await git(["rev-parse", "\(commit)^"], in: projectDirectory)?
                       .trimmingCharacters(in: .whitespacesAndNewlines) {
                    return .exact(parent, previousVersion: previousVersion)
                }
            }
        }

        // Build-time version bumps that were never committed leave the approved
        // version absent from history. The last committed version before it is
        // still a real end of the approved release interval, as long as a later
        // committed version proves the approved build fell between the two.
        for path in paths {
            guard let bounds = await boundingCommittedVersions(
                around: previousVersion, path: path, in: projectDirectory
            ) else { continue }
            return ReleaseBaseline(
                reference: bounds.lower.commit,
                sourceDescription: L10n.format(
                    "Git changes after version %@, the last committed version before approved version %@ (%@)",
                    bounds.lower.version, previousVersion, bounds.lower.commit
                ),
                disclosure: "Approved version \(previousVersion) was never committed to this repository. "
                    + "The baseline is the last committed version before it, \(bounds.lower.version) at \(bounds.lower.commit); "
                    + "the next committed version is \(bounds.upper.version) at \(bounds.upper.commit). "
                    + "Changes between those two commits may already have shipped in version \(previousVersion), "
                    + "so verify them against the saved App Store text before announcing them as new."
            )
        }
        return nil
    }

    private typealias CommittedVersion = (version: String, commit: String)

    /// Walks the first-parent history of one version file, newest first, and
    /// returns the last committed version older than `version` together with
    /// the committed version that immediately followed it.
    private func boundingCommittedVersions(
        around version: String,
        path: String,
        in directory: URL
    ) async -> (lower: CommittedVersion, upper: CommittedVersion)? {
        let commits = await git(["log", "--first-parent", "--format=%H", "HEAD", "--", path], in: directory)?
            .split(whereSeparator: \.isNewline).map(String.init) ?? []
        var newer: CommittedVersion?
        for commit in commits.prefix(500) {
            guard let contents = await git(["show", "\(commit):\(path)"], in: directory),
                  let declared = Self.declaredMarketingVersion(in: contents) else { continue }
            if Self.isVersion(declared, olderThan: version) {
                // Without a later committed version the interval has no known end.
                guard let newer else { return nil }
                return (lower: (declared, commit), upper: newer)
            }
            newer = (declared, commit)
        }
        return nil
    }

    static func declaredMarketingVersion(in contents: String) -> String? {
        let number = "([0-9]+(?:\\.[0-9]+)*)"
        let patterns = [
            "(?m)^\\s*MARKETING_VERSION\\s*[=:]\\s*[\\\"']?\(number)[\\\"']?\\s*(?:;|//[^\\n]*|#[^\\n]*)?$",
            "<key>CFBundleShortVersionString</key>\\s*<string>\(number)</string>"
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: contents, range: NSRange(contents.startIndex..., in: contents)),
                  let range = Range(match.range(at: 1), in: contents) else { continue }
            return String(contents[range])
        }
        return nil
    }

    static func isVersion(_ lhs: String, olderThan rhs: String) -> Bool {
        var left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        var right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        let width = max(left.count, right.count)
        left += Array(repeating: 0, count: width - left.count)
        right += Array(repeating: 0, count: width - right.count)
        return left.lexicographicallyPrecedes(right)
    }

    static func containsMarketingVersion(_ version: String, in contents: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: version)
        let assignment = "(?m)^\\s*MARKETING_VERSION\\s*[=:]\\s*[\\\"']?\(escaped)[\\\"']?\\s*(?:;|//[^\\n]*|#[^\\n]*)?$"
        let plist = "<key>CFBundleShortVersionString</key>\\s*<string>\(escaped)</string>"
        return contents.range(of: assignment, options: .regularExpression) != nil
            || contents.range(of: plist, options: .regularExpression) != nil
    }

    private func git(_ arguments: [String], in directory: URL) async -> String? {
        guard let result = try? await processRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: arguments,
            workingDirectory: directory
        ), result.terminationStatus == 0 else {
            return nil
        }
        return result.output
    }

    private func gitCommandSucceeded(_ arguments: [String], in directory: URL) async -> Bool {
        guard let result = try? await processRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: arguments,
            workingDirectory: directory
        ) else {
            return false
        }
        return result.terminationStatus == 0
    }
}
