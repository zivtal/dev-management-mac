import Foundation

struct ProjectApplicationMetadata: Equatable {
    let supportedDeviceFamilies: Set<MobileDeviceFamily>?
    let bundleIdentifier: String?
}

enum ProjectDiscoveryError: LocalizedError {
    case folderDoesNotExist
    case noXcodeContainer
    case noSchemes
    case malformedXcodeResponse

    var errorDescription: String? {
        switch self {
        case .folderDoesNotExist:
            L10n.text("The selected folder does not exist.")
        case .noXcodeContainer:
            L10n.text("No .xcodeproj or .xcworkspace was found in the selected folder.")
        case .noSchemes:
            L10n.text("No shared schemes were found. Mark a scheme as Shared in Xcode.")
        case .malformedXcodeResponse:
            L10n.text("Could not read the project details from Xcode.")
        }
    }
}

final class ProjectDiscoveryService {
    private struct XcodeList: Decodable {
        struct Summary: Decodable {
            let name: String?
            let configurations: [String]?
            let schemes: [String]?
        }

        let project: Summary?
        let workspace: Summary?
    }

    private let processRunner: ProcessRunner
    private let fileManager: FileManager

    init(processRunner: ProcessRunner = ProcessRunner(), fileManager: FileManager = .default) {
        self.processRunner = processRunner
        self.fileManager = fileManager
    }

    func discover(folderURL: URL) async throws -> ProjectDescriptor {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folderURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ProjectDiscoveryError.folderDoesNotExist
        }

        let contents = try fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        let workspace = contents
            .filter { $0.pathExtension == "xcworkspace" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first
        let project = contents
            .filter { $0.pathExtension == "xcodeproj" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first

        let containerURL: URL
        let containerKind: ProjectContainerKind
        if let workspace {
            containerURL = workspace
            containerKind = .workspace
        } else if let project {
            containerURL = project
            containerKind = .project
        } else {
            throw ProjectDiscoveryError.noXcodeContainer
        }

        let result = try await processRunner.runAndRequireSuccess(
            executable: URL(fileURLWithPath: "/usr/bin/xcodebuild"),
            arguments: [containerKind.xcodebuildFlag, containerURL.path, "-list", "-json"],
            workingDirectory: folderURL
        )

        guard let data = result.output.data(using: .utf8),
              let list = try? JSONDecoder().decode(XcodeList.self, from: data),
              let summary = list.project ?? list.workspace
        else {
            throw ProjectDiscoveryError.malformedXcodeResponse
        }

        let schemes = (summary.schemes ?? []).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        guard !schemes.isEmpty else { throw ProjectDiscoveryError.noSchemes }

        let configurations = (summary.configurations ?? ["Debug"]).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        let scriptURL = folderURL.appendingPathComponent("install.sh")
        let scriptPath = fileManager.fileExists(atPath: scriptURL.path) ? scriptURL.path : nil
        let displayName = summary.name?.trimmingCharacters(in: .whitespacesAndNewlines)

        var descriptor = ProjectDescriptor(
            displayName: (displayName?.isEmpty == false ? displayName : nil)
                ?? containerURL.deletingPathExtension().lastPathComponent,
            folderPath: folderURL.standardizedFileURL.path,
            containerPath: containerURL.standardizedFileURL.path,
            containerKind: containerKind,
            schemes: schemes,
            configurations: configurations,
            installScriptPath: scriptPath
        )
        if let metadata = try? await applicationMetadata(for: descriptor.makeManagedProject()) {
            descriptor.supportedDeviceFamilies = metadata.supportedDeviceFamilies
            descriptor.bundleIdentifier = metadata.bundleIdentifier
        }
        return descriptor
    }

    func supportedDeviceFamilies(for project: ManagedProject) async throws -> Set<MobileDeviceFamily>? {
        try await applicationMetadata(for: project).supportedDeviceFamilies
    }

    func applicationMetadata(for project: ManagedProject) async throws -> ProjectApplicationMetadata {
        let result = try await processRunner.runAndRequireSuccess(
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
        guard let metadata = Self.applicationMetadata(fromBuildSettingsJSON: result.output) else {
            throw ProjectDiscoveryError.malformedXcodeResponse
        }
        return metadata
    }

    static func supportedDeviceFamilies(fromBuildSettingsJSON output: String) -> Set<MobileDeviceFamily>? {
        applicationMetadata(fromBuildSettingsJSON: output)?.supportedDeviceFamilies
    }

    static func applicationMetadata(fromBuildSettingsJSON output: String) -> ProjectApplicationMetadata? {
        guard let entries = buildSettingsEntries(from: output) else { return nil }

        for entry in entries {
            guard let settings = entry["buildSettings"] as? [String: Any],
                  isIOSApplicationBuildSettings(settings),
                  let rawFamilies = settings["TARGETED_DEVICE_FAMILY"] as? String
            else {
                continue
            }

            let identifiers = rawFamilies
                .split(whereSeparator: { !$0.isNumber })
                .compactMap { Int($0) }
            var families: Set<MobileDeviceFamily> = []
            if identifiers.contains(1) { families.insert(.iPhone) }
            if identifiers.contains(2) { families.insert(.iPad) }
            let rawBundleIdentifier = settings["PRODUCT_BUNDLE_IDENTIFIER"] as? String
            let bundleIdentifier = rawBundleIdentifier?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return ProjectApplicationMetadata(
                supportedDeviceFamilies: families.isEmpty ? nil : families,
                bundleIdentifier: bundleIdentifier?.isEmpty == false
                    && bundleIdentifier?.contains("$(") == false
                        ? bundleIdentifier
                        : nil
            )
        }
        return nil
    }

    private static func buildSettingsEntries(from output: String) -> [[String: Any]]? {
        if let data = output.data(using: .utf8),
           let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return entries
        }

        guard let finalBracket = output.lastIndex(of: "]") else { return nil }
        var searchStart = output.startIndex
        while searchStart < finalBracket,
              let openingBracket = output[searchStart...].firstIndex(of: "[") {
            let candidate = String(output[openingBracket...finalBracket])
            if let data = candidate.data(using: .utf8),
               let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                return entries
            }
            searchStart = output.index(after: openingBracket)
        }
        return nil
    }

    private static func isIOSApplicationBuildSettings(_ settings: [String: Any]) -> Bool {
        let productType = settings["PRODUCT_TYPE"] as? String
        guard productType == "com.apple.product-type.application",
              (settings["SKIP_INSTALL"] as? String) != "YES"
        else {
            return false
        }

        let supportedPlatforms = (settings["SUPPORTED_PLATFORMS"] as? String)?.lowercased() ?? ""
        let sdkRoot = (settings["SDKROOT"] as? String)?.lowercased() ?? ""
        let platformName = (settings["PLATFORM_NAME"] as? String)?.lowercased() ?? ""
        return supportedPlatforms.split(separator: " ").contains("iphoneos")
            || sdkRoot.hasPrefix("iphoneos")
            || platformName == "iphoneos"
    }
}
