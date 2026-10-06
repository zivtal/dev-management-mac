import Foundation
import XCTest
@testable import DevManagement

final class XcodeCompanionAppDiscoveryTests: XCTestCase {
    private func projectFile(companion: String = "com.example.app", sdk: String = "watchos") -> Data {
        Data("""
        // !$*UTF8*$!
        {
            objects = {
                TARGET = {
                    isa = PBXNativeTarget;
                    name = WristNavigation;
                    productType = "com.apple.product-type.application";
                    buildConfigurationList = CONFIGS;
                };
                CONFIGS = { buildConfigurations = (DEBUG, RELEASE); };
                DEBUG = { buildSettings = {
                    SDKROOT = \(sdk);
                    GENERATE_INFOPLIST_FILE = YES;
                    INFOPLIST_KEY_WKCompanionAppBundleIdentifier = "\(companion)";
                }; };
                RELEASE = { buildSettings = {
                    SDKROOT = \(sdk);
                    INFOPLIST_KEY_WKCompanionAppBundleIdentifier = "\(companion)";
                }; };
            };
        }
        """.utf8)
    }

    func testFindsGeneratedWatchPlistWithoutRelyingOnTargetName() {
        XCTAssertEqual(XcodeCompanionAppDiscovery.watchTargets(
            in: projectFile(), companionBundleIdentifier: "com.example.app"
        ), ["WristNavigation"])
    }

    func testIgnoresOtherCompanionsAndNonWatchTargets() {
        XCTAssertTrue(XcodeCompanionAppDiscovery.watchTargets(
            in: projectFile(companion: "com.example.other"),
            companionBundleIdentifier: "com.example.app"
        ).isEmpty)
        XCTAssertTrue(XcodeCompanionAppDiscovery.watchTargets(
            in: projectFile(sdk: "iphoneos"), companionBundleIdentifier: "com.example.app"
        ).isEmpty)
        XCTAssertTrue(XcodeCompanionAppDiscovery.watchTargets(
            in: Data("invalid".utf8), companionBundleIdentifier: "com.example.app"
        ).isEmpty)
    }

    func testScreenshotPlatformsIncludeWatchWithNoSourceInfoPlistOrListedWatchScheme() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let container = root.appendingPathComponent("Example.xcodeproj")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try projectFile().write(to: container.appendingPathComponent("project.pbxproj"))
        var project = ProjectDescriptor(
            displayName: "Example", folderPath: root.path, containerPath: container.path,
            containerKind: .project, schemes: ["Example"], configurations: ["Debug"]
        ).makeManagedProject()
        project.bundleIdentifier = "com.example.app"
        project.supportedDeviceFamilies = [.iPhone, .iPad]

        XCTAssertEqual(AppStorePublishingService().supportedScreenshotPlatforms(for: project),
                       [.iPhone, .iPad, .appleWatch])
    }
}
