import XCTest
@testable import DevManagement

final class SimulatorBuildPreparationTests: XCTestCase {
    private var project: ManagedProject {
        var project = ProjectDescriptor(
            displayName: "TripFlow",
            folderPath: "/tmp/tripflow",
            containerPath: "/tmp/tripflow/TripFlow.xcodeproj",
            containerKind: .project,
            schemes: ["TripFlow"],
            configurations: ["Debug"]
        ).makeManagedProject()
        project.signingTeamID = "TEAM123456"
        return project
    }

    func testSimulatorArgumentsTargetTheSimulatorDestination() {
        let arguments = InstallationService.simulatorXcodeArguments(
            project: project,
            simulatorUDID: "SIM-UDID",
            derivedDataURL: URL(fileURLWithPath: "/tmp/derived")
        )
        XCTAssertEqual(arguments, [
            "-project", "/tmp/tripflow/TripFlow.xcodeproj",
            "-scheme", "TripFlow",
            "-configuration", "Debug",
            "-destination", "platform=iOS Simulator,id=SIM-UDID",
            "-destination-timeout", "30",
            "-derivedDataPath", "/tmp/derived"
        ])
    }

    func testSimulatorArgumentsNeverCarrySigningOverrides() {
        let arguments = InstallationService.simulatorXcodeArguments(
            project: project,
            simulatorUDID: "SIM-UDID",
            derivedDataURL: URL(fileURLWithPath: "/tmp/derived")
        )
        XCTAssertFalse(arguments.contains { $0.hasPrefix("DEVELOPMENT_TEAM") })
        XCTAssertFalse(arguments.contains { $0.hasPrefix("CODE_SIGN") })
    }

    func testSimulatorArgumentsHonorPreparedSchemeOverride() {
        let arguments = InstallationService.simulatorXcodeArguments(
            project: project,
            simulatorUDID: "SIM-UDID",
            derivedDataURL: URL(fileURLWithPath: "/tmp/derived"),
            scheme: "TripFlow-DevManagement"
        )
        let schemeIndex = arguments.firstIndex(of: "-scheme")
        XCTAssertEqual(schemeIndex.map { arguments[$0 + 1] }, "TripFlow-DevManagement")
    }

    func testSourceChangeWatcherIgnoresNonSourceArtifacts() {
        XCTAssertTrue(SourceChangeWatcher.shouldIgnore(path: "/repo/.git/index"))
        XCTAssertTrue(SourceChangeWatcher.shouldIgnore(path: "/repo/DerivedData/Build/foo.o"))
        XCTAssertTrue(SourceChangeWatcher.shouldIgnore(path: "/repo/Docs/README.md"))
        XCTAssertTrue(SourceChangeWatcher.shouldIgnore(path: "/repo/App/.DS_Store"))
        XCTAssertTrue(SourceChangeWatcher.shouldIgnore(
            path: "/repo/App.xcodeproj/xcuserdata/user.xcuserdatad/state.plist"
        ))
        XCTAssertFalse(SourceChangeWatcher.shouldIgnore(path: "/repo/App/ContentView.swift"))
        XCTAssertFalse(SourceChangeWatcher.shouldIgnore(path: "/repo/project.yml"))
        XCTAssertFalse(SourceChangeWatcher.shouldIgnore(
            path: "/repo/App.xcodeproj/project.pbxproj"
        ))
        XCTAssertFalse(SourceChangeWatcher.shouldIgnore(path: "/repo/Resources/he.lproj/Localizable.strings"))
    }
}
