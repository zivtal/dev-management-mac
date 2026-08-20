import XCTest
@testable import DevManagement

final class ProjectIconServiceTests: XCTestCase {
    func testPrefersPhoneApplicationIconOverWatchIcon() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectIconServiceTests-\(UUID().uuidString)", isDirectory: true)
        let phoneSet = root.appendingPathComponent("Phone/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
        let watchSet = root.appendingPathComponent("Watch/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
        try FileManager.default.createDirectory(at: phoneSet, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: watchSet, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let contents = #"{"images":[{"filename":"AppIcon.png","size":"1024x1024","scale":"1x"}]}"#
        try contents.write(to: phoneSet.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
        try contents.write(to: watchSet.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
        try Data([0]).write(to: phoneSet.appendingPathComponent("AppIcon.png"))
        try Data([0]).write(to: watchSet.appendingPathComponent("AppIcon.png"))

        let projectBundle = root.appendingPathComponent("Sample.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectBundle, withIntermediateDirectories: true)
        let project = ManagedProject(
            id: UUID(),
            displayName: "Sample",
            folderPath: root.path,
            containerPath: projectBundle.path,
            containerKind: .project,
            scheme: "Phone",
            configuration: "Debug",
            availableSchemes: ["Phone"],
            availableConfigurations: ["Debug"],
            isEnabled: true,
            marketingVersion: nil,
            buildNumber: nil
        )

        let result = await ProjectIconService().iconURL(for: project)
        XCTAssertEqual(
            result?.resolvingSymlinksInPath(),
            phoneSet.appendingPathComponent("AppIcon.png").resolvingSymlinksInPath()
        )
    }
}
