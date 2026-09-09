import Foundation

actor ProjectGitService {
    private let processRunner: ProcessRunner

    init(processRunner: ProcessRunner = ProcessRunner()) {
        self.processRunner = processRunner
    }

    func activeBranch(for project: ManagedProject) async -> String? {
        guard let workTree = try? await processRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", project.folderPath, "rev-parse", "--is-inside-work-tree"]
        ), workTree.terminationStatus == 0,
           workTree.output.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        else {
            return nil
        }

        let branch = try? await processRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", project.folderPath, "symbolic-ref", "--quiet", "--short", "HEAD"]
        )
        let branchName = branch?.terminationStatus == 0
            ? branch?.output.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        if let branchName, !branchName.isEmpty {
            return branchName
        }

        let revision = try? await processRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", project.folderPath, "rev-parse", "--short", "HEAD"]
        )
        let shortRevision = revision?.terminationStatus == 0
            ? revision?.output.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        return Self.displayName(branch: nil, detachedRevision: shortRevision)
    }

    /// Local branch names followed by remote-tracking branches (as
    /// `remote/branch`) that have no local counterpart. Empty outside Git.
    func availableBranches(for project: ManagedProject) async -> [String] {
        guard let result = try? await processRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: [
                "-C", project.folderPath, "for-each-ref",
                "--format=%(refname)", "refs/heads", "refs/remotes"
            ]
        ), result.terminationStatus == 0 else {
            return []
        }
        return Self.branchNames(fromRefs: result.output)
    }

    static func branchNames(fromRefs output: String) -> [String] {
        var local: [String] = []
        var remote: [String] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let ref = line.trimmingCharacters(in: .whitespaces)
            if ref.hasPrefix("refs/heads/") {
                local.append(String(ref.dropFirst("refs/heads/".count)))
            } else if ref.hasPrefix("refs/remotes/") {
                let name = String(ref.dropFirst("refs/remotes/".count))
                guard !name.hasSuffix("/HEAD") else { continue }
                remote.append(name)
            }
        }
        let localSet = Set(local)
        let remoteOnly = remote.filter { name in
            guard let slash = name.firstIndex(of: "/") else { return true }
            return !localSet.contains(String(name[name.index(after: slash)...]))
        }
        let compare: (String, String) -> Bool = {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        return local.sorted(by: compare) + remoteOnly.sorted(by: compare)
    }

    static func displayName(branch: String?, detachedRevision: String?) -> String? {
        if let branch = branch?.trimmingCharacters(in: .whitespacesAndNewlines),
           !branch.isEmpty {
            return branch
        }
        if let revision = detachedRevision?.trimmingCharacters(in: .whitespacesAndNewlines),
           !revision.isEmpty {
            return "detached@\(revision)"
        }
        return nil
    }
}
