import Foundation

enum DeviceServiceError: LocalizedError {
    case invalidResponse

    var errorDescription: String? {
        L10n.text("Xcode returned the device list in an unknown format.")
    }
}

final class DeviceService {
    private let processRunner: ProcessRunner
    private let fileManager: FileManager

    init(processRunner: ProcessRunner = ProcessRunner(), fileManager: FileManager = .default) {
        self.processRunner = processRunner
        self.fileManager = fileManager
    }

    func availableDevices() async throws -> [ConnectedDevice] {
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("DevReinstaller-\(UUID().uuidString)", isDirectory: true)
        let jsonURL = temporaryDirectory.appendingPathComponent("devices.json")

        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        _ = try await processRunner.runAndRequireSuccess(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: [
                "devicectl", "list", "devices",
                "--filter", "State == 'available (paired)'",
                "--timeout", "20",
                "--json-output", jsonURL.path
            ]
        )

        guard fileManager.fileExists(atPath: jsonURL.path) else {
            throw DeviceServiceError.invalidResponse
        }

        let data = try Data(contentsOf: jsonURL)
        let envelope = try JSONDecoder().decode(DeviceListEnvelope.self, from: data)
        return envelope.availableAppleDevices
    }
}
