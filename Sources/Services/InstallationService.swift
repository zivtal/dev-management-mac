import Foundation

enum InstallationEvent: Sendable {
    case phase(InstallationProgress.Phase)
    case output(String)
}

struct InstallationEventBatch: Equatable, Sendable {
    private(set) var phase: InstallationProgress.Phase?
    private(set) var output = ""

    var isEmpty: Bool {
        phase == nil && output.isEmpty
    }

    mutating func append(_ event: InstallationEvent) {
        switch event {
        case .phase(let phase):
            self.phase = phase
        case .output(let output):
            self.output.append(output)
        }
    }
}

final class InstallationEventCoalescer: @unchecked Sendable {
    typealias DeliveryHandler = @Sendable (InstallationEventBatch) -> Void

    private let lock = NSLock()
    private let deliveryInterval: TimeInterval
    private let deliveryHandler: DeliveryHandler
    private var pendingBatch = InstallationEventBatch()
    private var isDeliveryScheduled = false
    private var isFinished = false

    init(
        deliveryInterval: TimeInterval = 0.2,
        deliveryHandler: @escaping DeliveryHandler
    ) {
        self.deliveryInterval = deliveryInterval
        self.deliveryHandler = deliveryHandler
    }

    func receive(_ event: InstallationEvent) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        pendingBatch.append(event)
        let shouldScheduleDelivery = !isDeliveryScheduled
        isDeliveryScheduled = true
        lock.unlock()

        guard shouldScheduleDelivery else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + deliveryInterval) { [weak self] in
            self?.deliverPendingEvents()
        }
    }

    func finish() -> InstallationEventBatch {
        lock.lock()
        defer { lock.unlock() }
        isFinished = true
        isDeliveryScheduled = false
        let batch = pendingBatch
        pendingBatch = InstallationEventBatch()
        return batch
    }

    private func deliverPendingEvents() {
        lock.lock()
        guard !isFinished else {
            isDeliveryScheduled = false
            lock.unlock()
            return
        }
        let batch = pendingBatch
        pendingBatch = InstallationEventBatch()
        isDeliveryScheduled = false
        lock.unlock()

        guard !batch.isEmpty else { return }
        deliveryHandler(batch)
    }
}

struct InstallationOutcome {
    let log: String
}

enum InstallationServiceError: LocalizedError {
    case missingInstallScript
    case missingProjectContainer
    case noBuiltApplication

    var errorDescription: String? {
        switch self {
        case .missingInstallScript:
            L10n.text("install.sh was not found. Switch to Direct Xcode build in Settings.")
        case .missingProjectContainer:
            L10n.text("The saved Xcode project or workspace no longer exists.")
        case .noBuiltApplication:
            L10n.text("The build finished, but no .app product was found to install.")
        }
    }
}

final class InstallationService {
    typealias EventHandler = @Sendable (InstallationEvent) -> Void

    private let processRunner: ProcessRunner
    private let fileManager: FileManager

    init(processRunner: ProcessRunner = ProcessRunner(), fileManager: FileManager = .default) {
        self.processRunner = processRunner
        self.fileManager = fileManager
    }

    func install(
        project: ManagedProject,
        on device: ConnectedDevice,
        eventHandler: @escaping EventHandler
    ) async throws -> InstallationOutcome {
        eventHandler(.phase(.preparing))

        switch project.installMethod {
        case .installScript:
            return try await installUsingScript(project: project, device: device, eventHandler: eventHandler)
        case .xcodebuild:
            return try await buildAndInstall(project: project, device: device, eventHandler: eventHandler)
        }
    }

    private func installUsingScript(
        project: ManagedProject,
        device: ConnectedDevice,
        eventHandler: @escaping EventHandler
    ) async throws -> InstallationOutcome {
        guard let scriptPath = project.installScriptPath,
              fileManager.fileExists(atPath: scriptPath)
        else {
            throw InstallationServiceError.missingInstallScript
        }

        eventHandler(.phase(.building))
        let result = try await processRunner.runAndRequireSuccess(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [scriptPath],
            workingDirectory: project.folderURL,
            additionalEnvironment: ["IOS_DEVICE_UDID": device.udid],
            onOutput: { text in
                if text.localizedCaseInsensitiveContains("installing") {
                    eventHandler(.phase(.installing))
                }
                eventHandler(.output(text))
            }
        )
        return InstallationOutcome(log: Self.trimmedLog(result.output))
    }

    private func buildAndInstall(
        project: ManagedProject,
        device: ConnectedDevice,
        eventHandler: @escaping EventHandler
    ) async throws -> InstallationOutcome {
        guard fileManager.fileExists(atPath: project.containerPath) else {
            throw InstallationServiceError.missingProjectContainer
        }

        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("DevManagement-Build-\(UUID().uuidString)", isDirectory: true)
        let derivedDataURL = temporaryDirectory.appendingPathComponent("DerivedData", isDirectory: true)
        try fileManager.createDirectory(at: derivedDataURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let commonArguments = Self.xcodeArguments(
            project: project,
            device: device,
            derivedDataURL: derivedDataURL
        )

        eventHandler(.phase(.building))
        let buildResult = try await processRunner.runAndRequireSuccess(
            executable: URL(fileURLWithPath: "/usr/bin/xcodebuild"),
            arguments: commonArguments + [
                "-allowProvisioningUpdates",
                "-allowProvisioningDeviceRegistration",
                "build"
            ],
            workingDirectory: project.folderURL,
            onOutput: { eventHandler(.output($0)) }
        )

        let appURL = try await locateBuiltApplication(
            project: project,
            commonArguments: commonArguments,
            derivedDataURL: derivedDataURL
        )

        eventHandler(.phase(.installing))
        let installResult = try await processRunner.runAndRequireSuccess(
            executable: URL(fileURLWithPath: "/usr/bin/xcrun"),
            arguments: [
                "devicectl", "device", "install", "app",
                "--device", device.udid,
                "--timeout", "180",
                appURL.path
            ],
            workingDirectory: project.folderURL,
            onOutput: { eventHandler(.output($0)) }
        )

        return InstallationOutcome(log: Self.trimmedLog(
            buildResult.output + "\n\n" + installResult.output
        ))
    }

    static func xcodeArguments(
        project: ManagedProject,
        device: ConnectedDevice,
        derivedDataURL: URL
    ) -> [String] {
        var arguments = [
            project.containerKind.xcodebuildFlag, project.containerPath,
            "-scheme", project.scheme,
            "-configuration", project.configuration,
            "-destination", "platform=iOS,id=\(device.udid)",
            "-destination-timeout", "45",
            "-derivedDataPath", derivedDataURL.path
        ]
        if let teamID = project.signingTeamID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !teamID.isEmpty {
            arguments.append(contentsOf: [
                "DEVELOPMENT_TEAM=\(teamID)",
                "CODE_SIGN_STYLE=Automatic",
                "PROVISIONING_PROFILE=",
                "PROVISIONING_PROFILE_SPECIFIER="
            ])
        }
        return arguments
    }

    private func locateBuiltApplication(
        project: ManagedProject,
        commonArguments: [String],
        derivedDataURL: URL
    ) async throws -> URL {
        let settingsResult = try? await processRunner.runAndRequireSuccess(
            executable: URL(fileURLWithPath: "/usr/bin/xcodebuild"),
            arguments: commonArguments + ["-showBuildSettings", "-json"],
            workingDirectory: project.folderURL
        )

        if let output = settingsResult?.output,
           let appURL = applicationURL(fromBuildSettingsJSON: output),
           fileManager.fileExists(atPath: appURL.path) {
            return appURL
        }

        return try fallbackBuiltApplication(
            project: project,
            productsURL: derivedDataURL.appendingPathComponent("Build/Products", isDirectory: true)
        )
    }

    private func fallbackBuiltApplication(project: ManagedProject, productsURL: URL) throws -> URL {
        guard let enumerator = fileManager.enumerator(
            at: productsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw InstallationServiceError.noBuiltApplication
        }

        var candidates: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "app" {
            let parentExtensions = url.deletingLastPathComponent().pathComponents
                .map { URL(fileURLWithPath: $0).pathExtension }
            guard !parentExtensions.contains("app"), !parentExtensions.contains("appex") else { continue }
            candidates.append(url)
            enumerator.skipDescendants()
        }

        guard let appURL = candidates.sorted(by: { lhs, rhs in
            let lhsMatches = lhs.deletingPathExtension().lastPathComponent
                .localizedCaseInsensitiveContains(project.scheme)
            let rhsMatches = rhs.deletingPathExtension().lastPathComponent
                .localizedCaseInsensitiveContains(project.scheme)
            if lhsMatches != rhsMatches { return lhsMatches }
            return lhs.pathComponents.count < rhs.pathComponents.count
        }).first else {
            throw InstallationServiceError.noBuiltApplication
        }
        return appURL
    }

    private func applicationURL(fromBuildSettingsJSON output: String) -> URL? {
        guard let data = output.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            return nil
        }

        for entry in entries {
            guard let settings = entry["buildSettings"] as? [String: Any],
                  (settings["WRAPPER_EXTENSION"] as? String) == "app",
                  (settings["SKIP_INSTALL"] as? String) != "YES",
                  let targetBuildDirectory = settings["TARGET_BUILD_DIR"] as? String,
                  let wrapperName = settings["WRAPPER_NAME"] as? String
            else {
                continue
            }
            return URL(fileURLWithPath: targetBuildDirectory, isDirectory: true)
                .appendingPathComponent(wrapperName, isDirectory: true)
        }
        return nil
    }

    private static func trimmedLog(_ log: String, limit: Int = 30_000) -> String {
        let trimmed = log.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return "…\n" + String(trimmed.suffix(limit))
    }
}
