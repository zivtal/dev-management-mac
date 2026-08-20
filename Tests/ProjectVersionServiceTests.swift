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
}
