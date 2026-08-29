import XCTest
@testable import DevManagement

final class SimulatorFilesStorageTests: XCTestCase {
    private var devicesDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        devicesDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SimulatorFilesStorageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: devicesDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: devicesDirectory)
        devicesDirectory = nil
        try super.tearDownWithError()
    }

    func testOnMyDeviceDirectoryResolvesTheFilesLocalStorageContainer() throws {
        try makeGroupContainer(udid: "UDID-1", containerName: "AAA", identifier: "group.com.apple.Maps")
        let filesContainer = try makeGroupContainer(
            udid: "UDID-1",
            containerName: "BBB",
            identifier: "group.com.apple.FileProvider.LocalStorage"
        )

        let directory = SimulatorFilesStorage.onMyDeviceDirectory(
            udid: "UDID-1",
            devicesDirectory: devicesDirectory
        )

        XCTAssertEqual(directory?.lastPathComponent, "File Provider Storage")
        XCTAssertEqual(
            directory?.deletingLastPathComponent().resolvingSymlinksInPath(),
            filesContainer.resolvingSymlinksInPath()
        )
    }

    func testOnMyDeviceDirectoryIsNilWhenTheFilesContainerIsMissing() throws {
        try makeGroupContainer(udid: "UDID-2", containerName: "AAA", identifier: "group.com.apple.Maps")

        XCTAssertNil(
            SimulatorFilesStorage.onMyDeviceDirectory(
                udid: "UDID-2",
                devicesDirectory: devicesDirectory
            )
        )
    }

    func testOnMyDeviceDirectoryIsNilForAnUnknownDevice() {
        XCTAssertNil(
            SimulatorFilesStorage.onMyDeviceDirectory(
                udid: "UDID-MISSING",
                devicesDirectory: devicesDirectory
            )
        )
    }

    func testDefaultDevicesDirectoryPointsAtCoreSimulator() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

        XCTAssertEqual(
            SimulatorFilesStorage.defaultDevicesDirectory(homeDirectory: home).path,
            "/Users/tester/Library/Developer/CoreSimulator/Devices"
        )
    }

    @discardableResult
    private func makeGroupContainer(
        udid: String,
        containerName: String,
        identifier: String
    ) throws -> URL {
        let container = devicesDirectory
            .appendingPathComponent(udid, isDirectory: true)
            .appendingPathComponent("data/Containers/Shared/AppGroup", isDirectory: true)
            .appendingPathComponent(containerName, isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let metadata = try PropertyListSerialization.data(
            fromPropertyList: ["MCMMetadataIdentifier": identifier],
            format: .binary,
            options: 0
        )
        try metadata.write(
            to: container.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist")
        )
        return container
    }
}
