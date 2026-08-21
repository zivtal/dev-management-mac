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

    func testSimulatorBuildsUseDebugEvenWhenProjectInstallsRelease() {
        var releaseProject = ProjectDescriptor(
            displayName: "TripFlow",
            folderPath: "/tmp/tripflow",
            containerPath: "/tmp/tripflow/TripFlow.xcodeproj",
            containerKind: .project,
            schemes: ["TripFlow"],
            configurations: ["Debug", "Release"]
        ).makeManagedProject()
        releaseProject.configuration = "Release"

        let arguments = InstallationService.simulatorXcodeArguments(
            project: releaseProject,
            simulatorUDID: "SIM-UDID",
            derivedDataURL: URL(fileURLWithPath: "/tmp/derived")
        )
        let configurationIndex = arguments.firstIndex(of: "-configuration")
        XCTAssertEqual(configurationIndex.map { arguments[$0 + 1] }, "Debug")
    }

    func testSimulatorConfigurationFallsBackWhenNoDebugExists() {
        var project = ProjectDescriptor(
            displayName: "App",
            folderPath: "/tmp/app",
            containerPath: "/tmp/app/App.xcodeproj",
            containerKind: .project,
            schemes: ["App"],
            configurations: ["Development-Debugging", "Production"]
        ).makeManagedProject()
        project.configuration = "Production"
        XCTAssertEqual(project.simulatorBuildConfiguration, "Development-Debugging")

        project.availableConfigurations = ["Production"]
        XCTAssertEqual(project.simulatorBuildConfiguration, "Production")
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

    func testPrepareFallsBackToOriginalSchemeWhenNoSchemeFileExists() throws {
        let fileManager = FileManager.default
        let folderURL = fileManager.temporaryDirectory
            .appendingPathComponent("SchemeLess-\(UUID().uuidString)", isDirectory: true)
        let containerURL = folderURL.appendingPathComponent("App.xcodeproj", isDirectory: true)
        try fileManager.createDirectory(at: containerURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: folderURL) }

        let schemelessProject = ProjectDescriptor(
            displayName: "App",
            folderPath: folderURL.path,
            containerPath: containerURL.path,
            containerKind: .project,
            schemes: ["App-iOS"],
            configurations: ["Debug"]
        ).makeManagedProject()

        let prepared = try XcodeSchemeBuildPreparationService().prepare(project: schemelessProject)
        XCTAssertEqual(prepared.name, "App-iOS")
        XCTAssertTrue(prepared.removedActionTitles.isEmpty)
        XCTAssertNil(prepared.temporaryURL)
    }

    func testFingerprintIsStableAcrossIdenticalRewritesAndIgnoredFiles() throws {
        let fileManager = FileManager.default
        let folderURL = fileManager.temporaryDirectory
            .appendingPathComponent("Fingerprint-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(
            at: folderURL.appendingPathComponent("App.xcodeproj", isDirectory: true),
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: folderURL) }
        let sourceURL = folderURL.appendingPathComponent("Main.swift")
        let projectURL = folderURL.appendingPathComponent("App.xcodeproj/project.pbxproj")
        try "let x = 1\n".write(to: sourceURL, atomically: true, encoding: .utf8)
        try "// pbxproj\n".write(to: projectURL, atomically: true, encoding: .utf8)

        let original = SourceFingerprintCalculator.fingerprint(of: folderURL)

        // An identical rewrite — what XcodeGen regeneration does — keeps the
        // fingerprint stable even though the file's modification date changed.
        try "// pbxproj\n".write(to: projectURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(SourceFingerprintCalculator.fingerprint(of: folderURL), original)

        // Ignored artifacts do not affect the fingerprint.
        try "notes".write(
            to: folderURL.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        try "temp".write(
            to: folderURL.appendingPathComponent(
                "\(XcodeSchemeBuildPreparationService.temporarySchemePrefix)App.xcscheme"
            ),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertEqual(SourceFingerprintCalculator.fingerprint(of: folderURL), original)

        // Real content changes do.
        try "let x = 2\n".write(to: sourceURL, atomically: true, encoding: .utf8)
        XCTAssertNotEqual(SourceFingerprintCalculator.fingerprint(of: folderURL), original)
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
