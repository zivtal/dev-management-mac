import XCTest
@testable import DevManagement

final class ProjectVersionServiceTests: XCTestCase {
    func testReadsVersionXCConfigBeforeProjectFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectVersionServiceTests-\(UUID().uuidString)", isDirectory: true)
        let config = root.appendingPathComponent("Config", isDirectory: true)
        let projectBundle = root.appendingPathComponent("Sample.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectBundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try "MARKETING_VERSION = 2.4.1\nCURRENT_PROJECT_VERSION = 73\n"
            .write(to: config.appendingPathComponent("Version.xcconfig"), atomically: true, encoding: .utf8)
        try "MARKETING_VERSION = 1.0;\nCURRENT_PROJECT_VERSION = 1;\n"
            .write(to: projectBundle.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)

        let project = ManagedProject(
            id: UUID(),
            displayName: "Sample",
            folderPath: root.path,
            containerPath: projectBundle.path,
            containerKind: .project,
            scheme: "Sample",
            configuration: "Debug",
            availableSchemes: ["Sample"],
            availableConfigurations: ["Debug"],
            isEnabled: true,
            marketingVersion: nil,
            buildNumber: nil
        )

        let version = ProjectVersionService().currentVersion(for: project)
        XCTAssertEqual(version.marketingVersion, "2.4.1")
        XCTAssertEqual(version.buildNumber, "73")
    }

    func testReadsUpdatedVersionFromDiskOnEveryCheck() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectVersionServiceTests-\(UUID().uuidString)", isDirectory: true)
        let projectBundle = root.appendingPathComponent("Sample.xcodeproj", isDirectory: true)
        let projectFile = projectBundle.appendingPathComponent("project.pbxproj")
        try FileManager.default.createDirectory(at: projectBundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let project = ManagedProject(
            id: UUID(),
            displayName: "Sample",
            folderPath: root.path,
            containerPath: projectBundle.path,
            containerKind: .project,
            scheme: "Sample",
            configuration: "Debug",
            availableSchemes: ["Sample"],
            availableConfigurations: ["Debug"],
            isEnabled: true,
            marketingVersion: nil,
            buildNumber: nil
        )
        let service = ProjectVersionService()

        try "MARKETING_VERSION = 1.0.0;\nCURRENT_PROJECT_VERSION = 1;\n"
            .write(to: projectFile, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            service.currentVersion(for: project),
            ProjectVersion(marketingVersion: "1.0.0", buildNumber: "1")
        )

        try "MARKETING_VERSION = 1.0.1;\nCURRENT_PROJECT_VERSION = 2;\n"
            .write(to: projectFile, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            service.currentVersion(for: project),
            ProjectVersion(marketingVersion: "1.0.1", buildNumber: "2")
        )
    }

    // MARK: - Selected build branch

    func testReadsVersionFromSelectedBranchWithoutTouchingWorkingCopy() async throws {
        let repository = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: repository.root) }
        let project = repository.project(buildBranch: "main")
        let service = ProjectVersionService()

        // The working copy sits on the feature branch with a newer version.
        XCTAssertEqual(
            service.currentVersion(for: project),
            ProjectVersion(marketingVersion: "2.0.0", buildNumber: "2")
        )
        let branchVersion = await service.currentVersion(for: project, branch: "main")
        XCTAssertEqual(branchVersion, ProjectVersion(marketingVersion: "1.0.0", buildNumber: "1"))

        let head = try await repository.git(["symbolic-ref", "--short", "HEAD"])
        XCTAssertEqual(head, "feature/newer")
        XCTAssertEqual(
            try String(contentsOf: repository.root.appendingPathComponent("Config/Version.xcconfig"), encoding: .utf8),
            "MARKETING_VERSION = 2.0.0\nCURRENT_PROJECT_VERSION = 2\n"
        )
    }

    func testBranchVersionFallsBackToProjectFileAndInfoPlist() async throws {
        let repository = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: repository.root) }
        try await repository.git(["checkout", "--quiet", "-b", "plist-only", "main"])
        try FileManager.default.removeItem(at: repository.root.appendingPathComponent("Config/Version.xcconfig"))
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleShortVersionString</key><string>3.1.4</string>
        <key>CFBundleVersion</key><string>31</string>
        </dict></plist>
        """.write(to: repository.root.appendingPathComponent("App/Info.plist"), atomically: true, encoding: .utf8)
        try await repository.commit("Plist only")
        try await repository.git(["checkout", "--quiet", "feature/newer"])

        let version = await ProjectVersionService().currentVersion(
            for: repository.project(buildBranch: "plist-only"), branch: "plist-only"
        )
        XCTAssertEqual(version, ProjectVersion(marketingVersion: "3.1.4", buildNumber: "31"))
    }

    func testBranchVersionIsNilForUnknownBranchOrOutsideGit() async throws {
        let repository = try await makeRepository()
        defer { try? FileManager.default.removeItem(at: repository.root) }
        let service = ProjectVersionService()

        let missing = await service.currentVersion(for: repository.project(buildBranch: "nope"), branch: "nope")
        XCTAssertNil(missing)

        let plainFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectVersionServiceTests-plain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: plainFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: plainFolder) }
        var plainProject = repository.project(buildBranch: "main")
        plainProject.folderPath = plainFolder.path
        plainProject.containerPath = plainFolder.appendingPathComponent("Sample.xcodeproj").path
        let outsideGit = await service.currentVersion(for: plainProject, branch: "main")
        XCTAssertNil(outsideGit)
    }

    // MARK: - Helpers

    private struct Repository {
        let root: URL
        private let runner = ProcessRunner()

        init(root: URL) { self.root = root }

        func project(buildBranch: String?) -> ManagedProject {
            var project = ManagedProject(
                id: UUID(),
                displayName: "Sample",
                folderPath: root.path,
                containerPath: root.appendingPathComponent("Sample.xcodeproj").path,
                containerKind: .project,
                scheme: "Sample",
                configuration: "Debug",
                availableSchemes: ["Sample"],
                availableConfigurations: ["Debug"],
                isEnabled: true,
                marketingVersion: nil,
                buildNumber: nil
            )
            project.buildBranch = buildBranch
            return project
        }

        @discardableResult
        func git(_ arguments: [String]) async throws -> String {
            try await runner.runAndRequireSuccess(
                executable: URL(fileURLWithPath: "/usr/bin/git"),
                arguments: ["-C", root.path, "-c", "user.name=Tests", "-c", "user.email=tests@example.com",
                            "-c", "commit.gpgsign=false"] + arguments
            ).output.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func commit(_ message: String) async throws {
            try await git(["add", "-A"])
            try await git(["commit", "--quiet", "-m", message])
        }

        func writeVersion(_ marketing: String, build: String) throws {
            try "MARKETING_VERSION = \(marketing)\nCURRENT_PROJECT_VERSION = \(build)\n"
                .write(to: root.appendingPathComponent("Config/Version.xcconfig"), atomically: true, encoding: .utf8)
        }
    }

    /// `main` holds 1.0.0 (1); the checked-out `feature/newer` branch holds 2.0.0 (2).
    private func makeRepository() async throws -> Repository {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectVersionServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Config", isDirectory: true), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("App", isDirectory: true), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Sample.xcodeproj", isDirectory: true), withIntermediateDirectories: true
        )
        let repository = Repository(root: root)
        try await repository.git(["init", "--quiet", "-b", "main"])
        try repository.writeVersion("1.0.0", build: "1")
        try "// no versions here\n".write(
            to: root.appendingPathComponent("Sample.xcodeproj/project.pbxproj"), atomically: true, encoding: .utf8
        )
        try await repository.commit("Initial")
        try await repository.git(["checkout", "--quiet", "-b", "feature/newer"])
        try repository.writeVersion("2.0.0", build: "2")
        try await repository.commit("Newer")
        return repository
    }
}
