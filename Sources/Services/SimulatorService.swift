import Foundation

/// The application that shows a booted simulator's screen. Xcode 26 and
/// earlier ship Simulator.app inside the developer directory and accept the
/// device to show as a launch argument. Xcode 27 removed Simulator.app: its
/// Device Hub lives beside Xcode's other bundled applications, lists every
/// booted simulator, and takes no device argument.
enum SimulatorUserInterface: Equatable {
    case simulator(URL)
    case deviceHub(URL)

    static func locate(
        developerDirectory: URL,
        applicationExists: (URL) -> Bool
    ) -> SimulatorUserInterface? {
        let simulator = developerDirectory
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("Simulator.app", isDirectory: true)
        if applicationExists(simulator) {
            return .simulator(simulator)
        }
        // <Xcode.app>/Contents/Developer -> <Xcode.app>/Contents/Applications
        let deviceHub = developerDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("DeviceHub.app", isDirectory: true)
        if applicationExists(deviceHub) {
            return .deviceHub(deviceHub)
        }
        return nil
    }

    /// Arguments for `/usr/bin/open`.
    func openArguments(udid: String) -> [String] {
        switch self {
        case .simulator(let url):
            return [url.path, "--args", "-CurrentDeviceUDID", udid]
        case .deviceHub(let url):
            return [url.path]
        }
    }
}

final class SimulatorService: Sendable {
    private let processRunner: any ProcessRunning
    private let applicationExists: @Sendable (URL) -> Bool

    private static let xcrunURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    private static let xcodeSelectURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
    private static let openURL = URL(fileURLWithPath: "/usr/bin/open")
    private static let pkillURL = URL(fileURLWithPath: "/usr/bin/pkill")
    private static let defaultDeveloperDirectory = URL(
        fileURLWithPath: "/Applications/Xcode.app/Contents/Developer", isDirectory: true
    )

    init(
        processRunner: any ProcessRunning = ProcessRunner(),
        applicationExists: @escaping @Sendable (URL) -> Bool = { url in
            FileManager.default.fileExists(atPath: url.path)
        }
    ) {
        self.processRunner = processRunner
        self.applicationExists = applicationExists
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

    /// Brings the simulator user interface forward for the booted device and
    /// returns a description of the failure when it could not be opened.
    /// simctl keeps working without the UI, so the caller only reports it.
    func openSimulatorApplication(udid: String) async -> String? {
        let developerDirectory = await selectedDeveloperDirectory()
        guard let userInterface = SimulatorUserInterface.locate(
            developerDirectory: developerDirectory,
            applicationExists: applicationExists
        ) else {
            return L10n.format(
                "Neither Simulator.app nor Device Hub was found in %@.",
                developerDirectory.deletingLastPathComponent().deletingLastPathComponent().path
            )
        }
        do {
            let result = try await run(
                executable: Self.openURL,
                arguments: userInterface.openArguments(udid: udid)
            )
            guard result.terminationStatus == 0 else {
                let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                return output.isEmpty
                    ? L10n.format("The open command failed (code %d).", result.terminationStatus)
                    : output
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// The developer directory of the selected Xcode, falling back to the
    /// standard installation when xcode-select cannot answer.
    private func selectedDeveloperDirectory() async -> URL {
        guard let result = try? await run(executable: Self.xcodeSelectURL, arguments: ["-p"]),
              result.terminationStatus == 0 else {
            return Self.defaultDeveloperDirectory
        }
        let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return Self.defaultDeveloperDirectory }
        return URL(fileURLWithPath: path, isDirectory: true)
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

    /// Terminates the app's extension processes (widgets, share extension)
    /// on the simulator so they respawn and read the values the app relays
    /// through its app group. `simctl launch` reaches only the app process:
    /// extensions are spawned by the simulator's launchd with a clean
    /// environment, and a long-lived widget process keeps whatever it read
    /// at its own start. simctl cannot address extension processes, but
    /// simulator processes are host processes whose executables live under
    /// the app bundle's PlugIns folder, so they are matched by path. No
    /// running extension is not a failure.
    func restartApplicationExtensions(udid: String, applicationName: String) async {
        _ = try? await run(
            executable: Self.pkillURL,
            arguments: [
                "-TERM", "-f",
                Self.extensionProcessPattern(udid: udid, applicationName: applicationName)
            ]
        )
    }

    /// Regular expression for `pkill -f` that matches executables inside
    /// `<app bundle>/PlugIns/` of the given app installed on the given
    /// simulator, and nothing on other devices or in the app itself.
    static func extensionProcessPattern(udid: String, applicationName: String) -> String {
        "/Devices/" + NSRegularExpression.escapedPattern(for: udid)
            + "/data/Containers/Bundle/Application/[^/]+/"
            + NSRegularExpression.escapedPattern(for: applicationName)
            + "/PlugIns/"
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
