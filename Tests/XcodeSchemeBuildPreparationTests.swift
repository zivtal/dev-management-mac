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

    func testPrepareRemovesTemporarySchemeResidueLeftByAnInterruptedRun() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SchemeResidue-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let projectURL = root.appendingPathComponent("Example.xcodeproj", isDirectory: true)
        let schemesURL = projectURL.appendingPathComponent(
            "xcshareddata/xcschemes",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: schemesURL, withIntermediateDirectories: true)
        let sourceURL = schemesURL.appendingPathComponent("Example.xcscheme")
        try Data(Self.schemeXML(includeScripts: true).utf8).write(to: sourceURL)
        // Residue from a run that was killed before its cleanup could run. Backdated
        // so it predates this process, which is what makes it residue rather than a
        // concurrent workflow's live scheme.
        let residueURL = schemesURL.appendingPathComponent(
            "DevelopmentManagement-Example-\(UUID().uuidString).xcscheme"
        )
        try Data(Self.schemeXML(includeScripts: false).utf8).write(to: residueURL)
        try FileManager.default.setAttributes(
            [.modificationDate: XcodeSchemeBuildPreparationService.processStartDate
                .addingTimeInterval(-60)],
            ofItemAtPath: residueURL.path
        )
        // A repository scheme with a similar name must survive.
        let unrelatedURL = schemesURL.appendingPathComponent("Example-Release.xcscheme")
        try Data(Self.schemeXML(includeScripts: false).utf8).write(to: unrelatedURL)

        let prepared = try XcodeSchemeBuildPreparationService().prepare(
            project: Self.project(root: root, container: projectURL)
        )
        defer { prepared.removeTemporaryFile() }

        XCTAssertFalse(FileManager.default.fileExists(atPath: residueURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
        // The freshly prepared scheme is not swept away by its own run.
        let preparedURL = try XCTUnwrap(prepared.temporaryURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: preparedURL.path))
    }

    /// Two managed apps that are targets of one Xcode project share a scheme
    /// directory, and only per-app concurrency guards exist, so a second prepare must
    /// never sweep away the first one's live scheme.
    func testConcurrentPrepareDoesNotDeleteAnotherWorkflowsLiveScheme() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SchemeConcurrency-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let projectURL = root.appendingPathComponent("Example.xcodeproj", isDirectory: true)
        let schemesURL = projectURL.appendingPathComponent(
            "xcshareddata/xcschemes",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: schemesURL, withIntermediateDirectories: true)
        let sourceURL = schemesURL.appendingPathComponent("Example.xcscheme")
        try Data(Self.schemeXML(includeScripts: true).utf8).write(to: sourceURL)

        let service = XcodeSchemeBuildPreparationService()
        let first = try service.prepare(project: Self.project(root: root, container: projectURL))
        defer { first.removeTemporaryFile() }
        let firstURL = try XCTUnwrap(first.temporaryURL)

        let second = try service.prepare(project: Self.project(root: root, container: projectURL))
        defer { second.removeTemporaryFile() }

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: firstURL.path),
            "the in-flight scheme of a concurrent build was deleted"
        )
        XCTAssertNotEqual(first.name, second.name)

        // Once released, the same file is eligible for sweeping again.
        first.removeTemporaryFile()
        XCTAssertFalse(TemporarySchemeRegistry.shared.isActive(firstURL))
    }

    func testResidueDetectionOnlyMatchesFilesOlderThanThisProcess() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SchemeResidueAge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("DevelopmentManagement-A-1.xcscheme")
        try Data("x".utf8).write(to: url)

        let start = Date().addingTimeInterval(60)
        XCTAssertTrue(XcodeSchemeBuildPreparationService.isResidue(url, processStartDate: start))
        XCTAssertFalse(XcodeSchemeBuildPreparationService.isResidue(
            url,
            processStartDate: Date().addingTimeInterval(-60)
        ))
        // An unreadable timestamp is treated as in-flight rather than as residue.
        XCTAssertFalse(XcodeSchemeBuildPreparationService.isResidue(
            root.appendingPathComponent("missing.xcscheme"),
            processStartDate: start
        ))
    }

    func testTemporarySchemeDetectionOnlyMatchesGeneratedNames() {
        XCTAssertTrue(XcodeSchemeBuildPreparationService.isTemporaryScheme(
            URL(fileURLWithPath: "/tmp/DevelopmentManagement-App-1234.xcscheme")
        ))
        XCTAssertFalse(XcodeSchemeBuildPreparationService.isTemporaryScheme(
            URL(fileURLWithPath: "/tmp/App.xcscheme")
        ))
        XCTAssertFalse(XcodeSchemeBuildPreparationService.isTemporaryScheme(
            URL(fileURLWithPath: "/tmp/DevelopmentManagement-App-1234.txt")
        ))
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
