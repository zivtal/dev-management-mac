import Foundation

enum DeviceServiceError: LocalizedError {
    case invalidResponse

    var errorDescription: String? {
        L10n.text("Xcode returned the device list in an unknown format.")
    }
}

struct InstalledApplication: Decodable, Equatable {
    let bundleIdentifier: String
    let marketingVersion: String?
    let buildNumber: String?

    private enum CodingKeys: String, CodingKey {
        case bundleIdentifier
        case marketingVersion = "version"
        case buildNumber = "bundleVersion"
    }

    var versionDisplay: String? {
        switch (marketingVersion, buildNumber) {
        case let (marketingVersion?, buildNumber?) where !buildNumber.isEmpty:
            return "\(marketingVersion) (\(buildNumber))"
        case let (marketingVersion?, _):
            return marketingVersion
        case let (_, buildNumber?) where !buildNumber.isEmpty:
            return buildNumber
        default:
            return nil
        }
    }
}

struct DeviceAppListEnvelope: Decodable {
    struct Result: Decodable {
        let apps: [InstalledApplication]
    }

    let result: Result

    var applicationsByBundleIdentifier: [String: InstalledApplication] {
        Dictionary(
            result.apps.map { ($0.bundleIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }
}

final class DeviceService {
    private let processRunner: ProcessRunner
    private let fileManager: FileManager
    private var didAttemptCoreDeviceRecovery = false

    init(processRunner: ProcessRunner = ProcessRunner(), fileManager: FileManager = .default) {
        self.processRunner = processRunner
        self.fileManager = fileManager
    }

    func availableDevices() async throws -> [ConnectedDevice] {
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("DevManagement-\(UUID().uuidString)", isDirectory: true)
        let jsonURL = temporaryDirectory.appendingPathComponent("devices.json")

        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        _ = try await processRunner.runAndRequireSuccess(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: [
                "devicectl", "list", "devices",
                "--filter", "State == 'available (paired)' OR State == 'connected'",
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

    func installedApplications(on device: ConnectedDevice) async throws -> [String: InstalledApplication] {
        try await installedApplications(on: device, allowCoreDeviceRecovery: true)
    }

    private func installedApplications(
        on device: ConnectedDevice,
        allowCoreDeviceRecovery: Bool
    ) async throws -> [String: InstalledApplication] {
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("DevManagement-Apps-\(UUID().uuidString)", isDirectory: true)
        let jsonURL = temporaryDirectory.appendingPathComponent("apps.json")

        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        do {
            _ = try await processRunner.runAndRequireSuccess(
                executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
                arguments: [
                    "devicectl", "device", "info", "apps",
                    "--device", device.udid,
                    "--timeout", "20",
                    "--json-output", jsonURL.path
                ]
            )
        } catch {
            guard allowCoreDeviceRecovery,
                  !didAttemptCoreDeviceRecovery,
                  Self.isCoreDeviceConnectionTimeout(error)
            else {
                throw error
            }
            didAttemptCoreDeviceRecovery = true
            _ = try? await processRunner.run(
                executable: URL(fileURLWithPath: "/usr/bin/killall"),
                arguments: ["CoreDeviceService"]
            )
            try await Task.sleep(for: .milliseconds(500))
            return try await installedApplications(
                on: device,
                allowCoreDeviceRecovery: false
            )
        }

        guard fileManager.fileExists(atPath: jsonURL.path) else {
            throw DeviceServiceError.invalidResponse
        }

        let data = try Data(contentsOf: jsonURL)
        let envelope = try JSONDecoder().decode(DeviceAppListEnvelope.self, from: data)
        return envelope.applicationsByBundleIdentifier
    }

    static func isCoreDeviceConnectionTimeout(_ error: Error) -> Bool {
        guard case let ProcessRunnerError.commandFailed(executable, _, output) = error,
              executable == "xcrun"
        else {
            return false
        }
        let normalizedOutput = output.lowercased()
        return normalizedOutput.contains("command timeout")
            || normalizedOutput.contains("operation timed out")
    }
}
