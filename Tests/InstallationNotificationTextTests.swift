import XCTest
@testable import DevManagement

final class InstallationNotificationTextTests: XCTestCase {
    func testSuccessMessageContainsApplicationAndDeviceDetails() {
        let project = ManagedProject(
            id: UUID(),
            displayName: "Test App",
            folderPath: "/tmp/TestApp",
            containerPath: "/tmp/TestApp/TestApp.xcodeproj",
            containerKind: .project,
            scheme: "TestApp",
            configuration: "Debug",
            availableSchemes: ["TestApp"],
            availableConfigurations: ["Debug"],
            isEnabled: true,
            marketingVersion: "1.2.3",
            buildNumber: "8"
        )
        let device = ConnectedDevice(
            udid: "PHONE-1",
            name: "Ziv Tal",
            model: "iPhone 15 Pro Max",
            platform: "iOS",
            transportType: "localNetwork",
            isInstallReady: true
        )

        let title = InstallationNotificationText.title(project: project)
        let body = InstallationNotificationText.body(project: project, device: device)

        XCTAssertTrue(title.contains("Test App"))
        XCTAssertTrue(body.contains("Test App"))
        XCTAssertTrue(body.contains("Ziv Tal"))
        XCTAssertTrue(body.contains("iPhone 15 Pro Max"))
        XCTAssertTrue(body.contains("Wi‑Fi"))
    }
}
