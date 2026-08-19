import Foundation

struct AppStoreReleaseNotesEvidence: Equatable, Sendable {
    enum Source: String, Equatable, Sendable {
        case readme
        case git
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

    func evidence(
        project: ManagedProject,
        previousVersion: String,
        currentVersion: String
    ) async -> AppStoreReleaseNotesEvidence? {
        if let readme = readmeURL(in: project.folderURL),
           let text = try? String(contentsOf: readme, encoding: .utf8),
           let section = Self.releaseSection(in: text, currentVersion: currentVersion) {
            return AppStoreReleaseNotesEvidence(
                source: .readme,
                sourceDescription: readme.lastPathComponent,
                content: String(section.prefix(Self.maximumEvidenceCharacters))
            )
        }
        return await gitEvidence(
            projectDirectory: project.folderURL,
            previousVersion: previousVersion
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
    ) async -> AppStoreReleaseNotesEvidence? {
        guard await git(["rev-parse", "--is-inside-work-tree"], in: projectDirectory)?
            .trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
            return nil
        }

        let baseline = await baselineReference(
            previousVersion: previousVersion,
            projectDirectory: projectDirectory
        )
        let historyArguments: [String]
        let sourceDescription: String
        if let baseline {
            historyArguments = [
                "log", "--no-merges", "--date=short",
                "--pretty=format:%h%x09%ad%x09%s", "--stat", "--max-count=80",
                "\(baseline)..HEAD"
            ]
            sourceDescription = L10n.format(
                "Git changes after approved version %@ (%@)",
                previousVersion,
                baseline
            )
        } else {
            historyArguments = [
                "log", "--no-merges", "--date=short",
                "--pretty=format:%h%x09%ad%x09%s", "--stat", "--max-count=20", "HEAD"
            ]
            sourceDescription = L10n.format(
                "the 20 latest Git commits because approved version %@ has no matching tag or version commit",
                previousVersion
            )
        }

        let history = await git(historyArguments, in: projectDirectory) ?? ""
        let status = await git(["status", "--short"], in: projectDirectory) ?? ""
        let workingDiffStat = await git(["diff", "--stat", "HEAD"], in: projectDirectory) ?? ""
        let stagedDiffStat = await git(["diff", "--cached", "--stat"], in: projectDirectory) ?? ""
        let content = """
        Previous approved App Store version: \(previousVersion)
        Git baseline: \(baseline ?? "not found; bounded recent history used")

        --- Commit history and changed files ---
        \(history.isEmpty ? "No committed changes were found." : history)

        --- Current working-tree status ---
        \(status.isEmpty ? "Clean" : status)

        --- Uncommitted changed-file summary ---
        \(workingDiffStat.isEmpty ? "None" : workingDiffStat)

        --- Staged changed-file summary ---
        \(stagedDiffStat.isEmpty ? "None" : stagedDiffStat)
        """
        guard !history.isEmpty || !status.isEmpty else { return nil }
        return AppStoreReleaseNotesEvidence(
            source: .git,
            sourceDescription: sourceDescription,
            content: String(content.prefix(Self.maximumEvidenceCharacters))
        )
    }

    private func baselineReference(
        previousVersion: String,
        projectDirectory: URL
    ) async -> String? {
        if let tags = await git(["tag", "--list"], in: projectDirectory)?
            .components(separatedBy: .newlines)
            .filter({ !$0.isEmpty }) {
            let exactCandidates = [previousVersion, "v\(previousVersion)"]
            if let exact = exactCandidates.first(where: { candidate in
                tags.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame })
            }) {
                return exact
            }
            if let releaseTag = tags.first(where: { tag in
                let tail = tag.split(separator: "/").last.map(String.init) ?? tag
                return tail.caseInsensitiveCompare("release-\(previousVersion)") == .orderedSame
                    || tail.caseInsensitiveCompare("v\(previousVersion)") == .orderedSame
            }) {
                return releaseTag
            }
        }

        guard let changeCommit = await git(
            ["log", "--all", "-S\(previousVersion)", "--format=%H", "--max-count=1"],
            in: projectDirectory
        )?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            return nil
        }
        let commitContainsVersion = await gitCommandSucceeded(
            ["grep", "-q", "-F", previousVersion, changeCommit],
            in: projectDirectory
        )
        if commitContainsVersion {
            return changeCommit
        }
        return await git(["rev-parse", "\(changeCommit)^"], in: projectDirectory)?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
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
