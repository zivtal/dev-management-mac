import XCTest
@testable import DevManagement

final class ManagedProjectBuildBranchTests: XCTestCase {
    func testReootingMovesFolderAndNestedContainerPaths() {
        var project = makeProject(folder: "/Users/dev/App", container: "/Users/dev/App/ios/App.xcworkspace")
        project.buildBranch = "release"

        let rerooted = project.rerooted(to: URL(fileURLWithPath: "/tmp/checkout", isDirectory: true))

        XCTAssertEqual(rerooted.folderPath, "/tmp/checkout")
        XCTAssertEqual(rerooted.containerPath, "/tmp/checkout/ios/App.xcworkspace")
        XCTAssertEqual(rerooted.id, project.id)
        XCTAssertEqual(rerooted.scheme, project.scheme)
        XCTAssertEqual(rerooted.buildBranch, "release")
    }

    func testBuildBranchDefaultsToWorkingCopyForExistingSavedProjects() throws {
        let json = """
        {"id":"7B5C7E0C-6D5D-4C0E-9C8B-1F1C2E3D4A5B","displayName":"App","folderPath":"/a",
         "containerPath":"/a/App.xcodeproj","containerKind":"project","scheme":"App",
         "configuration":"Debug","availableSchemes":["App"],"availableConfigurations":["Debug"],
         "isEnabled":true}
        """
        let project = try JSONDecoder().decode(ManagedProject.self, from: Data(json.utf8))
        XCTAssertNil(project.buildBranch)
        XCTAssertTrue(project.buildsFromWorkingCopy)
    }

    func testBlankBuildBranchMeansWorkingCopy() {
        var project = makeProject(folder: "/a", container: "/a/App.xcodeproj")
        project.buildBranch = "  "
        XCTAssertTrue(project.buildsFromWorkingCopy)
        project.buildBranch = "main"
        XCTAssertFalse(project.buildsFromWorkingCopy)
    }

    private func makeProject(folder: String, container: String) -> ManagedProject {
        ManagedProject(
            id: UUID(),
            displayName: "App",
            folderPath: folder,
            containerPath: container,
            containerKind: .workspace,
            scheme: "App",
            configuration: "Debug",
            availableSchemes: ["App"],
            availableConfigurations: ["Debug"],
            isEnabled: true,
            marketingVersion: nil,
            buildNumber: nil
        )
    }
}

final class BuildBranchPickerTests: XCTestCase {
    func testDisplayNameShowsWorkingCopyBranchWhenNoBuildBranchIsSelected() {
        var project = makeProject()
        XCTAssertEqual(project.buildBranchDisplayName(workingCopyBranch: "main"), "main")
        XCTAssertEqual(project.buildBranchDisplayName(workingCopyBranch: nil), "—")
        project.buildBranch = "release/2.0"
        XCTAssertEqual(project.buildBranchDisplayName(workingCopyBranch: "main"), "release/2.0")
    }

    func testPickerOptionsKeepASelectedBranchThatIsNoLongerListed() {
        var project = makeProject()
        project.buildBranch = "gone"
        XCTAssertEqual(project.buildBranchOptions(available: ["main", "develop"]), ["gone", "main", "develop"])
        project.buildBranch = nil
        XCTAssertEqual(project.buildBranchOptions(available: ["main", "develop"]), ["main", "develop"])
    }

    private func makeProject() -> ManagedProject {
        ManagedProject(
            id: UUID(), displayName: "App", folderPath: "/a", containerPath: "/a/App.xcodeproj",
            containerKind: .project, scheme: "App", configuration: "Debug",
            availableSchemes: ["App"], availableConfigurations: ["Debug"], isEnabled: true,
            marketingVersion: nil, buildNumber: nil
        )
    }
}
