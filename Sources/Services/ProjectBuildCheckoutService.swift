import Foundation

enum ProjectBuildCheckoutError: LocalizedError, Equatable {
    case notAGitRepository(String)
    case branchNotFound(String)

    var errorDescription: String? {
        switch self {
        case .notAGitRepository(let path):
            L10n.format("%@ is not a Git repository, so a build branch cannot be checked out.", path)
        case .branchNotFound(let branch):
            L10n.format("Branch %@ was not found in the repository.", branch)
        }
    }
}

/// Materialises a managed application's selected build branch as a detached
/// Git worktree owned by Development Management. The repository's own
/// checkout (branch, index, and working files) is never modified, so other
/// tools may keep working there while a different branch is built.
final class ProjectBuildCheckoutService {
    typealias OutputHandler = @Sendable (String) -> Void

    private let processRunner: ProcessRunner
    private let fileManager: FileManager
    private let rootDirectory: URL
    private let git = URL(fileURLWithPath: "/usr/bin/git")

    static func defaultRootDirectory(fileManager: FileManager = .default) -> URL {
        (fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support"))
            .appendingPathComponent("Development Management", isDirectory: true)
            .appendingPathComponent("Build Checkouts", isDirectory: true)
    }

    init(
        processRunner: ProcessRunner = ProcessRunner(),
        fileManager: FileManager = .default,
        rootDirectory: URL? = nil
    ) {
        self.processRunner = processRunner
        self.fileManager = fileManager
        self.rootDirectory = rootDirectory ?? Self.defaultRootDirectory(fileManager: fileManager)
    }

    func checkoutURL(for project: ManagedProject) -> URL {
        rootDirectory.appendingPathComponent(project.id.uuidString, isDirectory: true)
    }

    /// Returns the project to build: the project itself for working-copy
    /// builds, otherwise a copy rerooted into an up-to-date detached worktree
    /// of the selected branch.
    func prepare(project: ManagedProject, onOutput: @escaping OutputHandler) async throws -> ManagedProject {
        guard let branch = project.normalizedBuildBranch else { return project }

        let repository = project.folderURL
        guard await isGitWorkTree(repository) else {
            throw ProjectBuildCheckoutError.notAGitRepository(project.folderPath)
        }

        onOutput(L10n.format("Preparing a detached checkout of branch %@…\n", branch))
        let reference = try await resolveReference(branch, in: repository, onOutput: onOutput)
        let checkout = checkoutURL(for: project)

        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        _ = try? await run(["worktree", "prune"], in: repository)

        if await isRegisteredWorktree(checkout, of: repository) {
            _ = try await run(["checkout", "--quiet", "--detach", reference], in: checkout)
            _ = try await run(["reset", "--quiet", "--hard"], in: checkout)
            _ = try await run(["clean", "--quiet", "-fd"], in: checkout)
        } else {
            if fileManager.fileExists(atPath: checkout.path) {
                try fileManager.removeItem(at: checkout)
            }
            _ = try await run(["worktree", "add", "--detach", checkout.path, reference], in: repository)
        }

        let revision = (try? await run(["rev-parse", "--short", "HEAD"], in: checkout))?
            .output.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
        onOutput(L10n.format(
            "Building branch %@ at %@ from %@; the repository's checked-out branch was left unchanged.\n",
            branch, revision, checkout.path
        ))
        return project.rerooted(to: checkout)
    }

    func removeCheckout(for project: ManagedProject) async {
        let checkout = checkoutURL(for: project)
        _ = try? await run(["worktree", "remove", "--force", checkout.path], in: project.folderURL)
        try? fileManager.removeItem(at: checkout)
        _ = try? await run(["worktree", "prune"], in: project.folderURL)
    }

    // MARK: - Git helpers

    private func resolveReference(
        _ branch: String,
        in repository: URL,
        onOutput: @escaping OutputHandler
    ) async throws -> String {
        if await referenceExists("refs/heads/\(branch)", in: repository) {
            return "refs/heads/\(branch)"
        }
        if let slash = branch.firstIndex(of: "/") {
            let remote = String(branch[..<slash])
            let remoteBranch = String(branch[branch.index(after: slash)...])
            if await referenceExists("refs/remotes/\(branch)", in: repository) {
                if (try? await run(["fetch", "--quiet", remote, remoteBranch], in: repository)) == nil {
                    onOutput(L10n.format(
                        "Could not fetch %@ from %@; building the last known revision.\n",
                        remoteBranch, remote
                    ))
                }
                return "refs/remotes/\(branch)"
            }
        }
        throw ProjectBuildCheckoutError.branchNotFound(branch)
    }

    private func referenceExists(_ reference: String, in repository: URL) async -> Bool {
        let result = try? await processRunner.run(
            executable: git,
            arguments: ["-C", repository.path, "show-ref", "--verify", "--quiet", reference]
        )
        return result?.terminationStatus == 0
    }

    private func isGitWorkTree(_ directory: URL) async -> Bool {
        let result = try? await processRunner.run(
            executable: git,
            arguments: ["-C", directory.path, "rev-parse", "--is-inside-work-tree"]
        )
        return result?.terminationStatus == 0
            && result?.output.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    private func isRegisteredWorktree(_ checkout: URL, of repository: URL) async -> Bool {
        guard fileManager.fileExists(atPath: checkout.appendingPathComponent(".git").path),
              let list = try? await run(["worktree", "list", "--porcelain"], in: repository) else {
            return false
        }
        let target = checkout.standardizedFileURL.resolvingSymlinksInPath().path
        return list.output.split(whereSeparator: \.isNewline).contains { line in
            guard line.hasPrefix("worktree ") else { return false }
            let path = String(line.dropFirst("worktree ".count))
            return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path == target
        }
    }

    @discardableResult
    private func run(_ arguments: [String], in directory: URL) async throws -> CommandResult {
        try await processRunner.runAndRequireSuccess(
            executable: git,
            arguments: ["-C", directory.path] + arguments
        )
    }
}
