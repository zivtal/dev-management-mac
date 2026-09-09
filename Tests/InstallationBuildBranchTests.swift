import XCTest
@testable import DevManagement

final class InstallationBuildBranchTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("InstallationBuildBranchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try await ProcessRunner().runAndRequireSuccess(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["init", "-b", "main", root.path]
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    func testDeviceInstallationResolvesTheBuildBranchBeforeBuilding() async {
        var project = makeProject()
        project.buildBranch = "missing-branch"
        let device = ConnectedDevice(
            udid: "device-1", name: "Phone", model: "iPhone", platform: "iOS",
            transportType: "usb", isInstallReady: true
        )

        do {
            _ = try await InstallationService(checkoutService: makeCheckoutService())
                .install(project: project, on: [device], eventHandler: { _ in })
            XCTFail("Expected the missing build branch to stop the installation")
        } catch let error as ProjectBuildCheckoutError {
            XCTAssertEqual(error, .branchNotFound("missing-branch"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMacInstallationResolvesTheBuildBranchBeforeBuilding() async {
        var project = makeProject()
        project.applicationPlatform = .macOS
        project.buildBranch = "missing-branch"

        do {
            _ = try await InstallationService(checkoutService: makeCheckoutService())
                .install(project: project, eventHandler: { _ in })
            XCTFail("Expected the missing build branch to stop the installation")
        } catch let error as ProjectBuildCheckoutError {
            XCTAssertEqual(error, .branchNotFound("missing-branch"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeCheckoutService() -> ProjectBuildCheckoutService {
        ProjectBuildCheckoutService(
            rootDirectory: root.appendingPathComponent("checkouts", isDirectory: true)
        )
    }

    private func makeProject() -> ManagedProject {
        ManagedProject(
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
    }
}
