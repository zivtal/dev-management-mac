import XCTest
@testable import DevManagement

/// App Store Connect rejects iPad-capable bundles without interface orientations
/// (ITMS-90474) only after the package was validated by altool. Catching it in the
/// archive avoids uploading, and avoids touching App Store metadata first.
final class AppStoreArchiveOrientationTests: XCTestCase {
    private var root: URL!
    private var archive: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppStoreArchiveOrientationTests-\(UUID().uuidString)", isDirectory: true)
        archive = root.appendingPathComponent("Sample.xcarchive", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let allFour = [
        "UIInterfaceOrientationPortrait",
        "UIInterfaceOrientationPortraitUpsideDown",
        "UIInterfaceOrientationLandscapeLeft",
        "UIInterfaceOrientationLandscapeRight"
    ]

    private func writeArchive(info: [String: Any], mac: Bool = false, embedded: [String: Any]? = nil) throws {
        let application = archive
            .appendingPathComponent("Products/Applications/Sample.app", isDirectory: true)
        let infoURL = mac
            ? application.appendingPathComponent("Contents/Info.plist")
            : application.appendingPathComponent("Info.plist")
        try FileManager.default.createDirectory(
            at: infoURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var values = info
        values["CFBundleIdentifier"] = values["CFBundleIdentifier"] ?? "com.example.Sample"
        try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
            .write(to: infoURL)
        if let embedded {
            let watch = application.appendingPathComponent("Watch/Sample Watch.app", isDirectory: true)
            try FileManager.default.createDirectory(at: watch, withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: embedded, format: .xml, options: 0)
                .write(to: watch.appendingPathComponent("Info.plist"))
        }
    }

    private func failure(platform: AppStorePlatform = .iOS) -> AppStoreArchiveOrientationCheck.Failure? {
        AppStoreArchiveOrientationCheck.failure(at: archive, platform: platform)
    }

    func testAcceptsIPadAppDeclaringAllFourIPadOrientations() throws {
        try writeArchive(info: [
            "UIDeviceFamily": [1, 2],
            "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait"],
            "UISupportedInterfaceOrientations~ipad": allFour
        ])
        XCTAssertNil(failure())
    }

    func testAcceptsIPadAppUsingTheGeneralKeyForAllFourOrientations() throws {
        try writeArchive(info: [
            "UIDeviceFamily": [1, 2],
            "UISupportedInterfaceOrientations": allFour
        ])
        XCTAssertNil(failure())
    }

    func testRejectsBundleWithoutAnyOrientation() throws {
        // The exact shape of the KeyPassX 0.1.32 (33) rejection: iPhone and iPad
        // families, no orientation key at all.
        try writeArchive(info: ["UIDeviceFamily": [1, 2]])
        XCTAssertEqual(failure(), .noOrientations(bundleIdentifier: "com.example.Sample"))
    }

    func testRejectsIPadAppMissingAnOrientation() throws {
        try writeArchive(info: [
            "UIDeviceFamily": [1, 2],
            "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait"],
            "UISupportedInterfaceOrientations~ipad": [
                "UIInterfaceOrientationPortrait",
                "UIInterfaceOrientationLandscapeLeft",
                "UIInterfaceOrientationLandscapeRight"
            ]
        ])
        XCTAssertEqual(failure(), .incompleteIPadOrientations(
            bundleIdentifier: "com.example.Sample",
            missing: ["UIInterfaceOrientationPortraitUpsideDown"]
        ))
    }

    func testAcceptsFullScreenIPadAppWithPortraitOnly() throws {
        try writeArchive(info: [
            "UIDeviceFamily": [1, 2],
            "UIRequiresFullScreen": true,
            "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait"]
        ])
        XCTAssertNil(failure())
    }

    func testAcceptsIPhoneOnlyAppWithPortraitOnly() throws {
        try writeArchive(info: [
            "UIDeviceFamily": [1],
            "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait"]
        ])
        XCTAssertNil(failure())
    }

    func testIgnoresEmbeddedBundlesSuchAsTheWatchApp() throws {
        try writeArchive(
            info: ["UIDeviceFamily": [1, 2], "UISupportedInterfaceOrientations": allFour],
            embedded: ["CFBundleIdentifier": "com.example.Sample.watchkitapp", "UIDeviceFamily": [4]]
        )
        XCTAssertNil(failure())
    }

    func testSkipsMacAppStoreArchives() throws {
        try writeArchive(info: ["LSMinimumSystemVersion": "14.0"], mac: true)
        XCTAssertNil(failure(platform: .macOS))
    }

    func testReportsAnUnreadableArchiveAsNoFailureSoLaterStepsExplainIt() {
        XCTAssertNil(failure())
    }

    func testFailureDescriptionsNameTheInfoPlistKeys() {
        let none = AppStorePublishingError.unsupportedInterfaceOrientations(
            .noOrientations(bundleIdentifier: "com.example.Sample")
        ).errorDescription ?? ""
        XCTAssertTrue(none.contains("com.example.Sample"))
        XCTAssertTrue(none.contains("UISupportedInterfaceOrientations"))

        let missing = AppStorePublishingError.unsupportedInterfaceOrientations(
            .incompleteIPadOrientations(
                bundleIdentifier: "com.example.Sample",
                missing: ["UIInterfaceOrientationPortraitUpsideDown"]
            )
        ).errorDescription ?? ""
        XCTAssertTrue(missing.contains("UIInterfaceOrientationPortraitUpsideDown"))
        XCTAssertTrue(missing.contains("UIRequiresFullScreen"))
    }
}
