import XCTest
@testable import DevManagement

final class ProjectBuildCheckoutServiceTests: XCTestCase {
    private var root: URL!
    private var repositoryURL: URL!
    private var checkoutsURL: URL!
    private let git = URL(fileURLWithPath: "/usr/bin/git")
    private let runner = ProcessRunner()

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectBuildCheckoutServiceTests-\(UUID().uuidString)", isDirectory: true)
        repositoryURL = root.appendingPathComponent("repo", isDirectory: true)
        checkoutsURL = root.appendingPathComponent("checkouts", isDirectory: true)
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)

        try await run(["init", "-b", "main"], in: repositoryURL)
        try write("main version\n", to: "VERSION")
        try await commit("Initial", in: repositoryURL)
        try await run(["checkout", "-b", "feature/branch-build"], in: repositoryURL)
        try write("feature version\n", to: "VERSION")
        try await commit("Feature", in: repositoryURL)
        try await run(["checkout", "main"], in: repositoryURL)
        // Uncommitted change in the working copy that must never leak into a branch build.
        try write("dirty working copy\n", to: "VERSION")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    func testWorkingCopyProjectIsReturnedUnchanged() async throws {
        let project = makeProject(buildBranch: nil)
        let service = makeService()

        let checkout = try await service.prepare(project: project, onOutput: { _ in })

        XCTAssertEqual(checkout, project)
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkoutsURL.path))
    }

    func testBranchBuildUsesDetachedWorktreeAndLeavesWorkingCopyAlone() async throws {
        let project = makeProject(buildBranch: "feature/branch-build")
        let service = makeService()

        let checkout = try await service.prepare(project: project, onOutput: { _ in })

        let expectedFolder = checkoutsURL
            .appendingPathComponent(project.id.uuidString, isDirectory: true)
        XCTAssertEqual(checkout.folderURL.standardizedFileURL, expectedFolder.standardizedFileURL)
        XCTAssertEqual(
            checkout.containerURL.standardizedFileURL,
            expectedFolder.appendingPathComponent("Example.xcodeproj").standardizedFileURL
        )
        XCTAssertEqual(try contents(of: checkout.folderURL.appendingPathComponent("VERSION")), "feature version\n")

        XCTAssertEqual(try contents(of: repositoryURL.appendingPathComponent("VERSION")), "dirty working copy\n")
        let repositoryHead = try await output(["symbolic-ref", "--short", "HEAD"], in: repositoryURL)
        XCTAssertEqual(repositoryHead, "main")
        let checkoutHead = try await output(["rev-parse", "--abbrev-ref", "HEAD"], in: checkout.folderURL)
        XCTAssertEqual(checkoutHead, "HEAD")
    }

    func testRepeatedBuildsFollowNewCommitsOnTheBranch() async throws {
        let project = makeProject(buildBranch: "feature/branch-build")
        let service = makeService()
        _ = try await service.prepare(project: project, onOutput: { _ in })

        let scratchURL = root.appendingPathComponent("scratch", isDirectory: true)
        try await run(["worktree", "add", scratchURL.path, "feature/branch-build"], in: repositoryURL)
        try "second feature version\n".write(
            to: scratchURL.appendingPathComponent("VERSION"), atomically: true, encoding: .utf8
        )
        try await commit("Feature 2", in: scratchURL)

        let checkout = try await service.prepare(project: project, onOutput: { _ in })

        XCTAssertEqual(
            try contents(of: checkout.folderURL.appendingPathComponent("VERSION")),
            "second feature version\n"
        )
    }

    func testSwitchingBranchesReusesTheSameCheckoutFolder() async throws {
        let service = makeService()
        let featureProject = makeProject(buildBranch: "feature/branch-build")
        let first = try await service.prepare(project: featureProject, onOutput: { _ in })
        try "stale artifact".write(
            to: first.folderURL.appendingPathComponent("untracked.txt"), atomically: true, encoding: .utf8
        )

        var mainProject = featureProject
        mainProject.buildBranch = "main"
        let second = try await service.prepare(project: mainProject, onOutput: { _ in })

        XCTAssertEqual(first.folderPath, second.folderPath)
        XCTAssertEqual(try contents(of: second.folderURL.appendingPathComponent("VERSION")), "main version\n")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: second.folderURL.appendingPathComponent("untracked.txt").path
        ))
    }

    func testRemoteOnlyBranchIsCheckedOut() async throws {
        let cloneURL = root.appendingPathComponent("clone", isDirectory: true)
        try await run(["clone", "--quiet", "--branch", "main", repositoryURL.path, cloneURL.path], in: root)
        var project = makeProject(buildBranch: "origin/feature/branch-build")
        project.folderPath = cloneURL.path
        project.containerPath = cloneURL.appendingPathComponent("Example.xcodeproj").path
        let service = makeService()

        let checkout = try await service.prepare(project: project, onOutput: { _ in })

        XCTAssertEqual(try contents(of: checkout.folderURL.appendingPathComponent("VERSION")), "feature version\n")
    }

    func testUnknownBranchFails() async throws {
        let project = makeProject(buildBranch: "does/not/exist")
        let service = makeService()

        do {
            _ = try await service.prepare(project: project, onOutput: { _ in })
            XCTFail("Expected a missing branch error")
        } catch let error as ProjectBuildCheckoutError {
            XCTAssertEqual(error, .branchNotFound("does/not/exist"))
        }
    }

    func testRemovingCheckoutDeletesFolderAndWorktreeRegistration() async throws {
        let project = makeProject(buildBranch: "feature/branch-build")
        let service = makeService()
        let checkout = try await service.prepare(project: project, onOutput: { _ in })

        await service.removeCheckout(for: project)

        XCTAssertFalse(FileManager.default.fileExists(atPath: checkout.folderPath))
        let worktrees = try await output(["worktree", "list", "--porcelain"], in: repositoryURL)
        XCTAssertFalse(worktrees.contains(project.id.uuidString))
    }

    // MARK: - Helpers

    private func makeService() -> ProjectBuildCheckoutService {
        ProjectBuildCheckoutService(processRunner: runner, rootDirectory: checkoutsURL)
    }

    private func makeProject(buildBranch: String?) -> ManagedProject {
        var project = ManagedProject(
            id: UUID(),
            displayName: "Example",
            folderPath: repositoryURL.path,
            containerPath: repositoryURL.appendingPathComponent("Example.xcodeproj").path,
            containerKind: .project,
            scheme: "Example",
            configuration: "Debug",
            availableSchemes: ["Example"],
            availableConfigurations: ["Debug"],
            isEnabled: true,
            marketingVersion: nil,
            buildNumber: nil
        )
        project.buildBranch = buildBranch
        return project
    }

    private func write(_ text: String, to name: String) throws {
        try text.write(to: repositoryURL.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func contents(of url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func run(_ arguments: [String], in directory: URL) async throws {
        _ = try await runner.runAndRequireSuccess(
            executable: git,
            arguments: ["-C", directory.path] + arguments
        )
    }

    private func output(_ arguments: [String], in directory: URL) async throws -> String {
        try await runner.runAndRequireSuccess(
            executable: git,
            arguments: ["-C", directory.path] + arguments
        ).output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commit(_ message: String, in directory: URL) async throws {
        try await run(["add", "-A"], in: directory)
        try await run([
            "-c", "user.name=Tests", "-c", "user.email=tests@example.com",
            "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", message
        ], in: directory)
    }
}
