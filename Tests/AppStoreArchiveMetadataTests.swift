import XCTest
@testable import DevManagement

final class AppStoreArchiveMetadataTests: XCTestCase {
    func testReadsVersionProducedByTheArchivedApplication() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppStoreArchiveMetadataTests-\(UUID().uuidString)", isDirectory: true)
        let archive = root.appendingPathComponent("Sample.xcarchive", isDirectory: true)
        let application = archive
            .appendingPathComponent("Products/Applications", isDirectory: true)
            .appendingPathComponent("Sample.app", isDirectory: true)
        try FileManager.default.createDirectory(at: application, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let plist: [String: Any] = [
            "CFBundleIdentifier": "com.example.Sample",
            "CFBundleShortVersionString": "2.4.7",
            "CFBundleVersion": "108"
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: application.appendingPathComponent("Info.plist"))

        let metadata = try AppStorePublishingService.archiveMetadata(
            at: archive,
            expectedBundleIdentifier: "com.example.Sample"
        )

        XCTAssertEqual(metadata.bundleIdentifier, "com.example.Sample")
        XCTAssertEqual(metadata.version, "2.4.7")
        XCTAssertEqual(metadata.buildNumber, "108")
    }

    func testRejectsAnArchiveForAnotherBundleIdentifier() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppStoreArchiveMismatchTests-\(UUID().uuidString)", isDirectory: true)
        let archive = root.appendingPathComponent("Sample.xcarchive", isDirectory: true)
        let application = archive
            .appendingPathComponent("Products/Applications/Sample.app", isDirectory: true)
        try FileManager.default.createDirectory(at: application, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let data = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": "com.example.Wrong",
                "CFBundleShortVersionString": "1.0.0",
                "CFBundleVersion": "1"
            ],
            format: .xml,
            options: 0
        )
        try data.write(to: application.appendingPathComponent("Info.plist"))

        XCTAssertThrowsError(try AppStorePublishingService.archiveMetadata(
            at: archive,
            expectedBundleIdentifier: "com.example.Expected"
        )) { error in
            guard case AppStorePublishingError.archiveBundleIdentifierMismatch(
                "com.example.Expected",
                "com.example.Wrong"
            ) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }
}
