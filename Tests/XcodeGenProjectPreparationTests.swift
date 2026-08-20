import XCTest
@testable import DevManagement

final class XcodeGenProjectPreparationTests: XCTestCase {
    func testRootProjectWithProjectYMLIsPrepared() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let container = root.appendingPathComponent("Sample.xcodeproj", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try "name: Sample\n".write(
            to: root.appendingPathComponent("project.yml"),
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let project = managedProject(root: root, container: container, kind: .project)

        XCTAssertEqual(
            XcodeGenProjectPreparation.specificationURL(for: project),
            root.appendingPathComponent("project.yml")
        )
    }

    func testWorkspaceAndNestedProjectAreNotRegenerated() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let nested = root.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "name: Sample\n".write(
            to: root.appendingPathComponent("project.yml"),
            atomically: true,
            encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = managedProject(
            root: root,
            container: root.appendingPathComponent("Sample.xcworkspace"),
            kind: .workspace
        )
        let nestedProject = managedProject(
            root: root,
            container: nested.appendingPathComponent("Sample.xcodeproj"),
            kind: .project
        )

        XCTAssertNil(XcodeGenProjectPreparation.specificationURL(for: workspace))
        XCTAssertNil(XcodeGenProjectPreparation.specificationURL(for: nestedProject))
    }

    private func managedProject(
        root: URL,
        container: URL,
        kind: ProjectContainerKind
    ) -> ManagedProject {
        ManagedProject(
            id: UUID(),
            displayName: "Sample",
            folderPath: root.path,
            containerPath: container.path,
            containerKind: kind,
            scheme: "Sample",
            configuration: "Release",
            availableSchemes: ["Sample"],
            availableConfigurations: ["Release"],
            isEnabled: true,
            marketingVersion: "1.0.0",
            buildNumber: "1"
        )
    }
}
