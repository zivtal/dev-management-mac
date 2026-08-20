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

    func testDetachedRevisionHasExplicitLabel() {
        XCTAssertEqual(
            ProjectGitService.displayName(branch: nil, detachedRevision: "a1b2c3d"),
            "detached@a1b2c3d"
        )
        XCTAssertNil(ProjectGitService.displayName(branch: nil, detachedRevision: nil))
    }
}
