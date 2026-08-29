import Foundation

/// Locates the simulator's local "On My iPhone" storage.
///
/// An app's own Documents folder is private: the Files app and every document
/// picker can only browse it when the app publishes it with
/// `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace`. Files placed
/// in the Files app's local storage appear under "On My iPhone" for every app,
/// so that is where imported documents belong.
enum SimulatorFilesStorage {
    static let localStorageGroupIdentifier = "group.com.apple.FileProvider.LocalStorage"

    private static let storageFolderName = "File Provider Storage"
    private static let metadataFileName = ".com.apple.mobile_container_manager.metadata.plist"
    private static let metadataIdentifierKey = "MCMMetadataIdentifier"

    static func defaultDevicesDirectory(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Developer", isDirectory: true)
            .appendingPathComponent("CoreSimulator", isDirectory: true)
            .appendingPathComponent("Devices", isDirectory: true)
    }

    /// The device's "On My iPhone" directory, or `nil` when the runtime has not
    /// created the Files app's group container yet.
    static func onMyDeviceDirectory(
        udid: String,
        devicesDirectory: URL = defaultDevicesDirectory(),
        fileManager: FileManager = .default
    ) -> URL? {
        let appGroups = devicesDirectory
            .appendingPathComponent(udid, isDirectory: true)
            .appendingPathComponent("data", isDirectory: true)
            .appendingPathComponent("Containers", isDirectory: true)
            .appendingPathComponent("Shared", isDirectory: true)
            .appendingPathComponent("AppGroup", isDirectory: true)
        guard let containers = try? fileManager.contentsOfDirectory(
            at: appGroups,
            includingPropertiesForKeys: nil
        ) else {
            return nil
        }
        for container in containers.sorted(by: { $0.path < $1.path })
        where groupIdentifier(ofContainerAt: container, fileManager: fileManager)
            == localStorageGroupIdentifier {
            return container.appendingPathComponent(storageFolderName, isDirectory: true)
        }
        return nil
    }

    private static func groupIdentifier(
        ofContainerAt container: URL,
        fileManager: FileManager
    ) -> String? {
        let metadataURL = container.appendingPathComponent(metadataFileName)
        guard let data = fileManager.contents(atPath: metadataURL.path),
              let metadata = try? PropertyListSerialization.propertyList(
                  from: data,
                  format: nil
              ) as? [String: Any] else {
            return nil
        }
        return metadata[metadataIdentifierKey] as? String
    }
}
