import Foundation

final class SimulatorService: Sendable {
    private let processRunner: any ProcessRunning

    private static let xcrunURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    private static let openURL = URL(fileURLWithPath: "/usr/bin/open")

    init(processRunner: any ProcessRunning = ProcessRunner()) {
        self.processRunner = processRunner
    }

    func availableDevices() async throws -> [SimulatorDevice] {
        let result = try await processRunner.runAndRequireSuccess(
            executable: Self.xcrunURL,
            arguments: ["simctl", "list", "devices", "available", "-j"]
        )
        return SimulatorDevice.availableDevices(fromSimctlList: Data(result.output.utf8))
    }

    func boot(udid: String) async throws {
        _ = try await processRunner.runAndRequireSuccess(
            executable: Self.xcrunURL,
            arguments: ["simctl", "boot", udid]
        )
    }

    func waitUntilBooted(udid: String) async throws {
        _ = try await processRunner.runAndRequireSuccess(
            executable: Self.xcrunURL,
            arguments: ["simctl", "bootstatus", udid, "-b"]
        )
    }

    /// Brings the Simulator application forward for the booted device.
    /// Failures are ignored; simctl keeps working without the UI frontmost.
    func openSimulatorApplication(udid: String) async {
        _ = try? await run(
            executable: Self.openURL,
            arguments: ["-a", "Simulator", "--args", "-CurrentDeviceUDID", udid]
        )
    }

    func install(udid: String, applicationURL: URL) async throws {
        _ = try await processRunner.runAndRequireSuccess(
            executable: Self.xcrunURL,
            arguments: ["simctl", "install", udid, applicationURL.path]
        )
    }

    func terminate(udid: String, bundleIdentifier: String) async {
        _ = try? await run(
            executable: Self.xcrunURL,
            arguments: ["simctl", "terminate", udid, bundleIdentifier]
        )
    }

    private func run(executable: URL, arguments: [String]) async throws -> CommandResult {
        try await processRunner.run(
            executable: executable,
            arguments: arguments,
            workingDirectory: nil,
            additionalEnvironment: [:],
            standardInput: nil,
            onOutput: nil,
            terminateWhenOutput: nil
        )
    }

    @discardableResult
    func launch(
        udid: String,
        bundleIdentifier: String,
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) async throws -> String {
        let result = try await processRunner.runAndRequireSuccess(
            executable: Self.xcrunURL,
            arguments: ["simctl", "launch", "--terminate-running-process", udid, bundleIdentifier]
                + arguments,
            additionalEnvironment: environment
        )
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func setLocation(udid: String, latitude: Double, longitude: Double) async throws {
        _ = try await processRunner.runAndRequireSuccess(
            executable: Self.xcrunURL,
            arguments: ["simctl", "location", udid, "set", "\(latitude),\(longitude)"]
        )
    }

    /// Adds images and videos to the simulator's Photos library.
    func addMedia(udid: String, fileURLs: [URL]) async throws {
        guard !fileURLs.isEmpty else { return }
        _ = try await processRunner.runAndRequireSuccess(
            executable: Self.xcrunURL,
            arguments: ["simctl", "addmedia", udid] + fileURLs.map(\.path)
        )
    }

    /// The app's writable data container on the simulator, whose Documents
    /// folder is where imported files become visible to the app.
    func appDataContainer(udid: String, bundleIdentifier: String) async throws -> URL {
        let result = try await processRunner.runAndRequireSuccess(
            executable: Self.xcrunURL,
            arguments: ["simctl", "get_app_container", udid, bundleIdentifier, "data"]
        )
        let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    func clearLocation(udid: String) async {
        _ = try? await run(
            executable: Self.xcrunURL,
            arguments: ["simctl", "location", udid, "clear"]
        )
    }
}
