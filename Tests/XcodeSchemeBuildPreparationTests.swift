import Foundation
import XCTest
@testable import DevManagement

final class XcodeSchemeBuildPreparationTests: XCTestCase {
    func testPrepareRemovesRepositoryScriptsFromTemporarySchemeOnly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SchemePreparation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let projectURL = root.appendingPathComponent("Example.xcodeproj", isDirectory: true)
        let schemesURL = projectURL.appendingPathComponent(
            "xcshareddata/xcschemes",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: schemesURL, withIntermediateDirectories: true)
        let sourceURL = schemesURL.appendingPathComponent("Example.xcscheme")
        let source = Self.schemeXML(includeScripts: true)
        try Data(source.utf8).write(to: sourceURL)

        let prepared = try XcodeSchemeBuildPreparationService().prepare(
            project: Self.project(root: root, container: projectURL)
        )
        defer { prepared.removeTemporaryFile() }

        XCTAssertNotEqual(prepared.name, "Example")
        XCTAssertEqual(prepared.removedActionTitles, ["Advance app version", "Repository setup"])
        let preparedURL = try XCTUnwrap(prepared.temporaryURL)
        let preparedText = try String(contentsOf: preparedURL, encoding: .utf8)
        XCTAssertFalse(preparedText.contains("ExecutionAction"))
        XCTAssertTrue(preparedText.contains("BuildActionEntries"))
        XCTAssertEqual(try String(contentsOf: sourceURL, encoding: .utf8), source)
    }

    func testPrepareUsesOriginalSchemeWhenItHasNoScripts() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SchemePreparation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let projectURL = root.appendingPathComponent("Example.xcodeproj", isDirectory: true)
        let schemesURL = projectURL.appendingPathComponent(
            "xcshareddata/xcschemes",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: schemesURL, withIntermediateDirectories: true)
        try Data(Self.schemeXML(includeScripts: false).utf8).write(
            to: schemesURL.appendingPathComponent("Example.xcscheme")
        )

        let prepared = try XcodeSchemeBuildPreparationService().prepare(
            project: Self.project(root: root, container: projectURL)
        )

        XCTAssertEqual(prepared.name, "Example")
        XCTAssertTrue(prepared.removedActionTitles.isEmpty)
        XCTAssertNil(prepared.temporaryURL)
    }

    private static func project(root: URL, container: URL) -> ManagedProject {
        ManagedProject(
            id: UUID(),
            displayName: "Example",
            folderPath: root.path,
            containerPath: container.path,
            containerKind: .project,
            scheme: "Example",
            configuration: "Debug",
            availableSchemes: ["Example"],
            availableConfigurations: ["Debug", "Release"],
            isEnabled: true,
            marketingVersion: "1.2.3",
            buildNumber: "4"
        )
    }

    private static func schemeXML(includeScripts: Bool) -> String {
        let scripts = includeScripts ? """
              <PreActions>
                 <ExecutionAction ActionType="ShellScriptAction">
                    <ActionContent title="Advance app version" scriptText="scripts/bump-version.sh" />
                 </ExecutionAction>
                 <ExecutionAction ActionType="ShellScriptAction">
                    <ActionContent title="Repository setup" scriptText="scripts/setup.sh" />
                 </ExecutionAction>
              </PreActions>
            """ : ""
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <Scheme version="1.7">
           <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
        \(scripts)
              <BuildActionEntries />
           </BuildAction>
        </Scheme>
        """
    }
}
