import XCTest
@testable import DevManagement

final class AppStorePublishingCheckpointTests: XCTestCase {
    private var root: URL!
    private var project: ManagedProject!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        project = ManagedProject(
            id: UUID(), displayName: "Example", folderPath: "/Projects/Example",
            containerPath: "/Projects/Example/Example.xcodeproj", containerKind: .project,
            scheme: "Example", configuration: "Release", availableSchemes: ["Example"],
            availableConfigurations: ["Release"], isEnabled: true, marketingVersion: "7.4.15",
            buildNumber: "1016", bundleIdentifier: "com.example.app", signingTeamID: "team"
        )
    }

    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
    }

    private func checkpoint(issuer: String = "issuer", app: String = "app") throws -> AppStorePublishingCheckpoint {
        try AppStorePublishingCheckpoint(identity: .init(project: project, issuerID: issuer, appID: app), root: root)
    }

    private func writeArchive(_ checkpoint: AppStorePublishingCheckpoint, build: String = "1016") throws {
        let app = checkpoint.archiveURL.appendingPathComponent("Products/Applications/Example.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": "com.example.app", "CFBundleShortVersionString": "7.4.15",
            "CFBundleVersion": build
        ], format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))
    }

    @discardableResult
    private func writeIPA(_ checkpoint: AppStorePublishingCheckpoint, contents: String = "signed IPA") throws -> URL {
        try FileManager.default.createDirectory(at: checkpoint.exportURL, withIntermediateDirectories: true)
        let url = checkpoint.exportURL.appendingPathComponent("Example.ipa")
        try Data(contents.utf8).write(to: url)
        return url
    }

    func testArchiveSurvivesRestartAfterExportFailureButPartialExportIsNotReused() throws {
        let initial = try checkpoint()
        try writeArchive(initial)
        XCTAssertFalse(initial.hasArchive, "An incomplete archive must not be reused just because a plist exists.")
        try initial.markArchived()
        try writeIPA(initial, contents: "incomplete export")
        let resumed = try checkpoint()
        XCTAssertTrue(resumed.hasArchive)
        XCTAssertNil(try resumed.artifact())
        try resumed.prepareExport()
        XCTAssertTrue(resumed.hasArchive)
        XCTAssertFalse(FileManager.default.fileExists(atPath: resumed.exportURL.path))
    }

    func testValidatedIPASurvivesFailedUploadAndRestart() throws {
        let initial = try checkpoint()
        try writeArchive(initial)
        try initial.markArchived()
        let ipa = try writeIPA(initial)
        try initial.markExported(ipaURL: ipa)
        try initial.markValidated()
        let resumed = try checkpoint()
        XCTAssertEqual(try resumed.artifact()?.ipaURL, ipa)
        XCTAssertTrue(resumed.isValidated)
        XCTAssertFalse(resumed.uploadAccepted)
    }

    func testChangedOrMissingIPAIsNotReusedAndReexportNeedsValidation() throws {
        let initial = try checkpoint()
        try writeArchive(initial)
        try initial.markArchived()
        let ipa = try writeIPA(initial)
        try initial.markExported(ipaURL: ipa)
        try initial.markValidated()
        try Data("corrupted IPA".utf8).write(to: ipa)
        XCTAssertNil(try checkpoint().artifact())
        try FileManager.default.removeItem(at: ipa)
        XCTAssertNil(try checkpoint().artifact())
        try initial.prepareExport()
        try initial.markExported(ipaURL: writeIPA(initial, contents: "new export"))
        XCTAssertNotNil(try checkpoint().artifact())
        XCTAssertFalse(try checkpoint().isValidated)
    }

    func testUploadReceiptSurvivesRestartAndCompletedArtifactCleanup() throws {
        let initial = try checkpoint()
        try writeArchive(initial)
        try initial.markArchived()
        try initial.markExported(ipaURL: writeIPA(initial))
        try initial.markUploadAccepted()
        XCTAssertTrue(try checkpoint().uploadAccepted)
        initial.removeCompletedArtifacts()
        let resumed = try checkpoint()
        XCTAssertTrue(resumed.uploadAccepted)
        XCTAssertFalse(resumed.hasArchive)
        XCTAssertNil(try resumed.artifact())
    }

    func testCacheIsIsolatedByReleaseSchemeAccountAndApplication() throws {
        let initial = try checkpoint()
        try initial.markUploadAccepted()
        XCTAssertNotEqual(initial.directory, try checkpoint(issuer: "other").directory)
        XCTAssertNotEqual(initial.directory, try checkpoint(app: "other").directory)
        project.buildNumber = "1017"
        XCTAssertFalse(try checkpoint().uploadAccepted)
        project.buildNumber = "1016"
        project.marketingVersion = "7.4.16"
        XCTAssertFalse(try checkpoint().uploadAccepted)
        project.marketingVersion = "7.4.15"
        project.scheme = "Other"
        XCTAssertFalse(try checkpoint().uploadAccepted)
        project.scheme = "Example"
        XCTAssertTrue(try checkpoint().uploadAccepted)
    }

    func testWrongArchiveVersionCannotBeCheckpointed() throws {
        let initial = try checkpoint()
        try writeArchive(initial, build: "1017")
        XCTAssertThrowsError(try initial.markArchived())
        XCTAssertFalse(try checkpoint().hasArchive)
    }
}
