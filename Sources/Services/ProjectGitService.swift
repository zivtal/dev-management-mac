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
