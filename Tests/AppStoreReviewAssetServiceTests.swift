import XCTest
@testable import DevManagement

final class AppStoreReviewAssetServiceTests: XCTestCase {
    func testDiscoversConfiguredAndConventionalReviewAttachments() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppStoreReviewAssetTests-\(UUID().uuidString)", isDirectory: true)
        let conventional = root.appendingPathComponent("AppStore/ReviewAttachments", isDirectory: true)
        let configured = root.appendingPathComponent("ReviewVideo", isDirectory: true)
        try FileManager.default.createDirectory(at: conventional, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: configured, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("video".utf8).write(to: conventional.appendingPathComponent("Demo.mp4"))
        try Data("document".utf8).write(to: configured.appendingPathComponent("Access.pdf"))
        try Data("ignored".utf8).write(to: conventional.appendingPathComponent("README.md"))

        let assets = AppStoreReviewAssetService().discover(
            project: project(at: root),
            configuredPaths: ["ReviewVideo", "AppStore/ReviewAttachments/Demo.mp4"]
        )

        XCTAssertEqual(assets.map(\.lastPathComponent), ["Access.pdf", "Demo.mp4"])
    }

    private func project(at root: URL) -> ManagedProject {
        ManagedProject(
            id: UUID(),
            displayName: "Sample",
            folderPath: root.path,
            containerPath: root.appendingPathComponent("Sample.xcodeproj").path,
            containerKind: .project,
            scheme: "Sample",
            configuration: "Debug",
            availableSchemes: ["Sample"],
            availableConfigurations: ["Debug", "Release"],
            isEnabled: true,
            marketingVersion: "1.0.0",
            buildNumber: "1",
            bundleIdentifier: "com.example.Sample"
        )
    }
}
