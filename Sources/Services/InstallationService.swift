import AppKit
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
    let artifactURL: URL?

    init(log: String, artifactURL: URL? = nil) {
        self.log = log
        self.artifactURL = artifactURL
    }
}

enum InstallationServiceError: LocalizedError {
    case missingInstallScript
    case missingProjectContainer
    case missingDevelopmentTeam
    case noBuiltApplication
    case couldNotStopRunningApplication(String)
    case cannotReplaceDevelopmentManagement

    var errorDescription: String? {
        switch self {
        case .missingInstallScript:
            L10n.text("install.sh was not found. Switch to Direct Xcode build in Settings.")
        case .missingProjectContainer:
            L10n.text("The saved Xcode project or workspace no longer exists.")
        case .missingDevelopmentTeam:
            L10n.text("The Xcode project does not specify a development team, and no matching team could be selected automatically. Choose a signing team for this application in Settings.")
        case .noBuiltApplication:
            L10n.text("The build finished, but no .app product was found to install.")
        case .couldNotStopRunningApplication(let name):
            L10n.format("Could not stop the running %@ application.", name)
        case .cannotReplaceDevelopmentManagement:
            L10n.text("Development Management cannot replace itself. Choose a different macOS application.")
        }
    }
}

final class InstallationService {
    typealias EventHandler = @Sendable (InstallationEvent) -> Void

    private let processRunner: ProcessRunner
    private let fileManager: FileManager
    private let developerTeamService: DeveloperTeamService

    init(
        processRunner: ProcessRunner = ProcessRunner(),
        fileManager: FileManager = .default,
        developerTeamService: DeveloperTeamService = DeveloperTeamService()
    ) {
        self.processRunner = processRunner
        self.fileManager = fileManager
        self.developerTeamService = developerTeamService
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

    func install(
        project: ManagedProject,
        eventHandler: @escaping EventHandler
    ) async throws -> InstallationOutcome {
        eventHandler(.phase(.preparing))

        switch project.installMethod {
        case .installScript:
            return try await installUsingScript(project: project, eventHandler: eventHandler)
        case .xcodebuild:
            return try await buildPackageAndInstallMacApplication(
                project: project,
                eventHandler: eventHandler
            )
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

    private func installUsingScript(
        project: ManagedProject,
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
            additionalEnvironment: ["MACOS_INSTALL_TARGET": "local"],
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

        let buildProject = try await projectResolvingAutomaticSigning(project)
        if project.signingTeamID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false,
           let inferredTeamID = buildProject.signingTeamID {
            eventHandler(.output(L10n.format(
                "Using signing team %@ selected from matching Xcode provisioning profiles.\n",
                inferredTeamID
            )))
        }

        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("DevManagement-Build-\(UUID().uuidString)", isDirectory: true)
        let derivedDataURL = temporaryDirectory.appendingPathComponent("DerivedData", isDirectory: true)
        try fileManager.createDirectory(at: derivedDataURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let commonArguments = Self.xcodeArguments(
            project: buildProject,
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
            project: buildProject,
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

    private func buildPackageAndInstallMacApplication(
        project: ManagedProject,
        eventHandler: @escaping EventHandler
    ) async throws -> InstallationOutcome {
        guard fileManager.fileExists(atPath: project.containerPath) else {
            throw InstallationServiceError.missingProjectContainer
        }

        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("DevManagement-Mac-Build-\(UUID().uuidString)", isDirectory: true)
        let derivedDataURL = temporaryDirectory.appendingPathComponent("DerivedData", isDirectory: true)
        let stagingURL = temporaryDirectory.appendingPathComponent("DMG", isDirectory: true)
        let mountURL = temporaryDirectory.appendingPathComponent("MountedDMG", isDirectory: true)
        try fileManager.createDirectory(at: derivedDataURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let commonArguments = Self.macOSXcodeArguments(
            project: project,
            derivedDataURL: derivedDataURL
        )
        eventHandler(.phase(.building))
        let buildResult = try await processRunner.runAndRequireSuccess(
            executable: URL(fileURLWithPath: "/usr/bin/xcodebuild"),
            arguments: commonArguments + ["-allowProvisioningUpdates", "build"],
            workingDirectory: project.folderURL,
            onOutput: { eventHandler(.output($0)) }
        )

        let appURL = try await locateBuiltApplication(
            project: project,
            commonArguments: commonArguments,
            derivedDataURL: derivedDataURL
        )
        let builtBundleIdentifier = Bundle(url: appURL)?.bundleIdentifier ?? project.bundleIdentifier
        if builtBundleIdentifier == Bundle.main.bundleIdentifier {
            throw InstallationServiceError.cannotReplaceDevelopmentManagement
        }

        eventHandler(.phase(.packaging))
        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: project.macOSDMGURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let stagedAppURL = stagingURL.appendingPathComponent(appURL.lastPathComponent, isDirectory: true)
        try fileManager.copyItem(at: appURL, to: stagedAppURL)
        try fileManager.createSymbolicLink(
            atPath: stagingURL.appendingPathComponent("Applications").path,
            withDestinationPath: "/Applications"
        )

        let createResult = try await processRunner.runAndRequireSuccess(
            executable: URL(fileURLWithPath: "/usr/bin/hdiutil"),
            arguments: [
                "create",
                "-volname", appURL.deletingPathExtension().lastPathComponent,
                "-srcfolder", stagingURL.path,
                "-fs", "HFS+",
                "-format", "UDZO",
                "-ov",
                project.macOSDMGURL.path
            ],
            workingDirectory: project.folderURL,
            onOutput: { eventHandler(.output($0)) }
        )
        let verifyResult = try await processRunner.runAndRequireSuccess(
            executable: URL(fileURLWithPath: "/usr/bin/hdiutil"),
            arguments: ["verify", project.macOSDMGURL.path],
            workingDirectory: project.folderURL,
            onOutput: { eventHandler(.output($0)) }
        )
        eventHandler(.output(L10n.format(
            "Created and verified DMG at %@.\n",
            project.macOSDMGURL.path
        )))

        try fileManager.createDirectory(at: mountURL, withIntermediateDirectories: true)
        var isDMGAttached = false
        do {
            let attachResult = try await processRunner.runAndRequireSuccess(
                executable: URL(fileURLWithPath: "/usr/bin/hdiutil"),
                arguments: [
                    "attach", project.macOSDMGURL.path,
                    "-nobrowse", "-readonly", "-mountpoint", mountURL.path
                ],
                workingDirectory: project.folderURL,
                onOutput: { eventHandler(.output($0)) }
            )
            isDMGAttached = true

            let mountedAppURL = mountURL.appendingPathComponent(appURL.lastPathComponent, isDirectory: true)
            guard fileManager.fileExists(atPath: mountedAppURL.path) else {
                throw InstallationServiceError.noBuiltApplication
            }

            eventHandler(.phase(.stopping))
            try await stopRunningApplication(
                bundleIdentifier: builtBundleIdentifier,
                bundleName: appURL.deletingPathExtension().lastPathComponent
            )

            eventHandler(.phase(.installing))
            let installationURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
                .appendingPathComponent(appURL.lastPathComponent, isDirectory: true)
            let installationTemporaryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
                .appendingPathComponent(".\(appURL.lastPathComponent).installing-\(UUID().uuidString)", isDirectory: true)
            let backupURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
                .appendingPathComponent(".\(appURL.lastPathComponent).backup-\(UUID().uuidString)", isDirectory: true)
            defer {
                try? fileManager.removeItem(at: installationTemporaryURL)
            }

            let copyResult = try await processRunner.runAndRequireSuccess(
                executable: URL(fileURLWithPath: "/usr/bin/ditto"),
                arguments: [mountedAppURL.path, installationTemporaryURL.path],
                onOutput: { eventHandler(.output($0)) }
            )
            try replaceApplication(
                at: installationURL,
                with: installationTemporaryURL,
                backupURL: backupURL
            )

            let detachResult = try await processRunner.runAndRequireSuccess(
                executable: URL(fileURLWithPath: "/usr/bin/hdiutil"),
                arguments: ["detach", mountURL.path],
                onOutput: { eventHandler(.output($0)) }
            )
            isDMGAttached = false

            eventHandler(.phase(.launching))
            let launchResult = try await processRunner.runAndRequireSuccess(
                executable: URL(fileURLWithPath: "/usr/bin/open"),
                arguments: [installationURL.path],
                onOutput: { eventHandler(.output($0)) }
            )

            let log = [
                buildResult.output,
                createResult.output,
                verifyResult.output,
                attachResult.output,
                copyResult.output,
                detachResult.output,
                launchResult.output,
                L10n.format("Created and verified DMG at %@.", project.macOSDMGURL.path),
                L10n.format("Installed and launched %@.", installationURL.path)
            ]
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n\n")
            return InstallationOutcome(
                log: Self.trimmedLog(log),
                artifactURL: project.macOSDMGURL
            )
        } catch {
            if isDMGAttached {
                _ = try? await processRunner.run(
                    executable: URL(fileURLWithPath: "/usr/bin/hdiutil"),
                    arguments: ["detach", mountURL.path, "-force"]
                )
            }
            throw error
        }
    }

    private func stopRunningApplication(
        bundleIdentifier: String?,
        bundleName: String
    ) async throws {
        func matchingApplications() -> [NSRunningApplication] {
            NSWorkspace.shared.runningApplications.filter { application in
                if let bundleIdentifier, application.bundleIdentifier == bundleIdentifier {
                    return true
                }
                return application.localizedName == bundleName
            }
        }

        var applications = matchingApplications()
        guard !applications.isEmpty else { return }
        applications.forEach { _ = $0.terminate() }
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(100))
            applications = matchingApplications()
            if applications.isEmpty { return }
        }

        applications.forEach { _ = $0.forceTerminate() }
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(100))
            if matchingApplications().isEmpty { return }
        }
        throw InstallationServiceError.couldNotStopRunningApplication(bundleName)
    }

    func replaceApplication(
        at installationURL: URL,
        with temporaryURL: URL,
        backupURL: URL
    ) throws {
        let hasExistingApplication = fileManager.fileExists(atPath: installationURL.path)
        if hasExistingApplication {
            try fileManager.moveItem(at: installationURL, to: backupURL)
        }

        do {
            try fileManager.moveItem(at: temporaryURL, to: installationURL)
            if hasExistingApplication {
                try? fileManager.removeItem(at: backupURL)
            }
        } catch {
            if hasExistingApplication,
               !fileManager.fileExists(atPath: installationURL.path),
               fileManager.fileExists(atPath: backupURL.path) {
                try? fileManager.moveItem(at: backupURL, to: installationURL)
            }
            throw error
        }
    }

    private func projectResolvingAutomaticSigning(_ project: ManagedProject) async throws -> ManagedProject {
        if let selectedTeamID = project.signingTeamID?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !selectedTeamID.isEmpty {
            return project
        }

        var resolvedProject = project
        if resolvedProject.projectSigningTeamID == nil || resolvedProject.bundleIdentifier == nil,
           let metadata = await currentApplicationMetadata(for: resolvedProject) {
            resolvedProject.projectSigningTeamID = metadata.projectSigningTeamID
            resolvedProject.bundleIdentifier = metadata.bundleIdentifier
        }

        guard let projectTeamID = resolvedProject.projectSigningTeamID else {
            return resolvedProject
        }
        guard projectTeamID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return resolvedProject
        }
        guard let recommendedTeamID = developerTeamService.recommendedTeamID(
            for: resolvedProject.bundleIdentifier
        ) else {
            throw InstallationServiceError.missingDevelopmentTeam
        }

        resolvedProject.signingTeamID = recommendedTeamID
        return resolvedProject
    }

    private func currentApplicationMetadata(for project: ManagedProject) async -> ProjectApplicationMetadata? {
        let result = try? await processRunner.runAndRequireSuccess(
            executable: URL(fileURLWithPath: "/usr/bin/xcodebuild"),
            arguments: [
                project.containerKind.xcodebuildFlag, project.containerPath,
                "-scheme", project.scheme,
                "-configuration", project.configuration,
                "-destination", "generic/platform=iOS",
                "-showBuildSettings", "-json"
            ],
            workingDirectory: project.folderURL
        )
        return result.flatMap {
            ProjectDiscoveryService.applicationMetadata(fromBuildSettingsJSON: $0.output)
        }
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

    static func macOSXcodeArguments(
        project: ManagedProject,
        derivedDataURL: URL
    ) -> [String] {
        var arguments = [
            project.containerKind.xcodebuildFlag, project.containerPath,
            "-scheme", project.scheme,
            "-configuration", project.configuration,
            "-destination", "generic/platform=macOS",
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
