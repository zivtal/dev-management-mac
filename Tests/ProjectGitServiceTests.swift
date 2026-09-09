import XCTest
@testable import DevManagement

final class ProjectGitServiceTests: XCTestCase {
    func testReadsCurrentBranchFromManagedProjectWorktree() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectGitServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await ProcessRunner().runAndRequireSuccess(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["init", "-b", "feature/menu-branch", root.path]
        )

        let project = ManagedProject(
            id: UUID(),
            displayName: "Example",
            folderPath: root.path,
            containerPath: root.appendingPathComponent("Example.xcodeproj").path,
            containerKind: .project,
            scheme: "Example",
            configuration: "Debug",
            availableSchemes: ["Example"],
            availableConfigurations: ["Debug"],
            isEnabled: true,
            marketingVersion: nil,
            buildNumber: nil
        )

        let branch = await ProjectGitService().activeBranch(for: project)
        XCTAssertEqual(branch, "feature/menu-branch")
    }

    func testListsLocalBranchesAndRemoteOnlyBranches() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectGitServiceTests-\(UUID().uuidString)", isDirectory: true)
        let originURL = root.appendingPathComponent("origin", isDirectory: true)
        let cloneURL = root.appendingPathComponent("clone", isDirectory: true)
        try FileManager.default.createDirectory(at: originURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = ProcessRunner()
        func git(_ arguments: [String], in directory: URL) async throws {
            _ = try await runner.runAndRequireSuccess(
                executable: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: ["-C", directory.path, "-c", "user.name=Tests", "-c", "user.email=tests@example.com",
                            "-c", "commit.gpgsign=false"] + arguments
            )
        }
        try await git(["init", "-b", "main"], in: originURL)
        try await git(["commit", "--quiet", "--allow-empty", "-m", "Initial"], in: originURL)
        try await git(["branch", "release/1.0"], in: originURL)
        try await git(["branch", "zeta"], in: originURL)
        try await git(["clone", "--quiet", originURL.path, cloneURL.path], in: root)
        try await git(["checkout", "--quiet", "-b", "local-only"], in: cloneURL)

        let project = ManagedProject(
            id: UUID(),
            displayName: "Example",
            folderPath: cloneURL.path,
            containerPath: cloneURL.appendingPathComponent("Example.xcodeproj").path,
            containerKind: .project,
            scheme: "Example",
            configuration: "Debug",
            availableSchemes: ["Example"],
            availableConfigurations: ["Debug"],
            isEnabled: true,
            marketingVersion: nil,
            buildNumber: nil
        )

        let branches = await ProjectGitService().availableBranches(for: project)
        XCTAssertEqual(branches, ["local-only", "main", "origin/release/1.0", "origin/zeta"])
    }

    func testAvailableBranchesIsEmptyOutsideGit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectGitServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = ManagedProject(
            id: UUID(),
            displayName: "Example",
            folderPath: root.path,
            containerPath: root.appendingPathComponent("Example.xcodeproj").path,
            containerKind: .project,
            scheme: "Example",
            configuration: "Debug",
            availableSchemes: ["Example"],
            availableConfigurations: ["Debug"],
            isEnabled: true,
            marketingVersion: nil,
            buildNumber: nil
        )
        let branches = await ProjectGitService().availableBranches(for: project)
        XCTAssertEqual(branches, [])
    }

    func testDetachedRevisionHasExplicitLabel() {
        XCTAssertEqual(
            ProjectGitService.displayName(branch: nil, detachedRevision: "a1b2c3d"),
            "detached@a1b2c3d"
        )
        XCTAssertNil(ProjectGitService.displayName(branch: nil, detachedRevision: nil))
    }
}
