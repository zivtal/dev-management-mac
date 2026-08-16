import Foundation

enum ProjectContainerKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case project
    case workspace

    var id: String { rawValue }

    var xcodebuildFlag: String {
        switch self {
        case .project: "-project"
        case .workspace: "-workspace"
        }
    }
}

enum InstallMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    case installScript
    case xcodebuild

    var id: String { rawValue }

    var title: String {
        switch self {
        case .installScript: L10n.text("install.sh (optional)")
        case .xcodebuild: L10n.text("Direct Xcode build")
        }
    }
}

enum ApplicationPlatform: String, Codable, CaseIterable, Identifiable, Sendable {
    case iOS
    case macOS

    var id: String { rawValue }

    var title: String {
        switch self {
        case .iOS: "iOS / iPadOS"
        case .macOS: "macOS"
        }
    }
}

struct ManagedProject: Identifiable, Codable, Equatable, Sendable {
    static let localMacInstallationTargetID = "local-mac"

    var id: UUID
    var displayName: String
    var folderPath: String
    var containerPath: String
    var containerKind: ProjectContainerKind
    var scheme: String
    var configuration: String
    var availableSchemes: [String]
    var availableConfigurations: [String]
    var installMethod: InstallMethod
    var installScriptPath: String?
    var isEnabled: Bool
    var marketingVersion: String?
    var buildNumber: String?
    var supportedDeviceFamilies: Set<MobileDeviceFamily>? = nil
    var bundleIdentifier: String? = nil
    var excludedDeviceUDIDs: Set<String>? = nil
    var installationDeviceOrder: [String]? = nil
    var signingTeamID: String? = nil
    var projectSigningTeamID: String? = nil
    var applicationPlatform: ApplicationPlatform? = nil

    var folderURL: URL { URL(fileURLWithPath: folderPath, isDirectory: true) }
    var containerURL: URL { URL(fileURLWithPath: containerPath) }

    var effectiveApplicationPlatform: ApplicationPlatform {
        applicationPlatform ?? .iOS
    }

    var isMacOSApplication: Bool {
        effectiveApplicationPlatform == .macOS
    }

    var macOSDMGURL: URL {
        let invalidCharacters = CharacterSet(charactersIn: "/:")
        let safeName = displayName
            .components(separatedBy: invalidCharacters)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return folderURL
            .appendingPathComponent("dist", isDirectory: true)
            .appendingPathComponent("\(safeName.isEmpty ? scheme : safeName).dmg")
    }

    var versionDisplay: String {
        switch (marketingVersion, buildNumber) {
        case let (marketingVersion?, buildNumber?) where !buildNumber.isEmpty:
            "\(marketingVersion) (\(buildNumber))"
        case let (marketingVersion?, _):
            marketingVersion
        case let (_, buildNumber?):
            buildNumber
        default:
            L10n.text("Unknown")
        }
    }

    var effectiveSupportedDeviceFamilies: Set<MobileDeviceFamily> {
        guard let supportedDeviceFamilies, !supportedDeviceFamilies.isEmpty else {
            return Set(MobileDeviceFamily.allCases)
        }
        return supportedDeviceFamilies
    }

    var deviceCompatibilityDescription: String {
        guard let supportedDeviceFamilies, !supportedDeviceFamilies.isEmpty else {
            return L10n.text("iPhone and iPad (not detected by Xcode)")
        }
        switch supportedDeviceFamilies {
        case [.iPhone]:
            return L10n.text("iPhone only")
        case [.iPad]:
            return L10n.text("iPad only")
        default:
            return L10n.text("iPhone and iPad")
        }
    }

    func supports(_ device: ConnectedDevice) -> Bool {
        guard !isMacOSApplication else { return false }
        guard let family = device.mobileDeviceFamily else { return false }
        return effectiveSupportedDeviceFamilies.contains(family)
    }

    func isSelectedInstallationTarget(_ device: ConnectedDevice) -> Bool {
        supports(device) && excludedDeviceUDIDs?.contains(device.udid) != true
    }

    func selectedDeviceCount(in connectedDevices: [ConnectedDevice]) -> Int {
        connectedDevices.lazy.filter {
            $0.supportsIOSAppInstallation && isSelectedInstallationTarget($0)
        }.count
    }

    func installationEnabled(for device: ConnectedDevice) -> Bool {
        isEnabled && isSelectedInstallationTarget(device)
    }

    mutating func setInstallationEnabled(_ enabled: Bool, for deviceUDID: String) {
        var exclusions = excludedDeviceUDIDs ?? []
        if enabled {
            exclusions.remove(deviceUDID)
        } else {
            exclusions.insert(deviceUDID)
        }
        excludedDeviceUDIDs = exclusions.isEmpty ? nil : exclusions
    }

    func devicesInInstallationOrder(_ devices: [ConnectedDevice]) -> [ConnectedDevice] {
        guard let installationDeviceOrder, !installationDeviceOrder.isEmpty else {
            return devices
        }

        var positions: [String: Int] = [:]
        for deviceUDID in installationDeviceOrder where positions[deviceUDID] == nil {
            positions[deviceUDID] = positions.count
        }

        return devices.enumerated()
            .sorted { lhs, rhs in
                let lhsPosition = positions[lhs.element.udid] ?? Int.max
                let rhsPosition = positions[rhs.element.udid] ?? Int.max
                return lhsPosition == rhsPosition ? lhs.offset < rhs.offset : lhsPosition < rhsPosition
            }
            .map(\.element)
    }

    mutating func setInstallationDeviceOrder(_ connectedDeviceUDIDs: [String]) {
        var seenConnectedDeviceUDIDs: Set<String> = []
        let uniqueConnectedDeviceUDIDs = connectedDeviceUDIDs.filter {
            seenConnectedDeviceUDIDs.insert($0).inserted
        }
        let connectedDeviceSet = Set(uniqueConnectedDeviceUDIDs)
        var reorderedConnectedDevices = uniqueConnectedDeviceUDIDs.makeIterator()
        var seenSavedDeviceUDIDs: Set<String> = []
        var updatedOrder: [String] = []

        for savedDeviceUDID in installationDeviceOrder ?? []
        where seenSavedDeviceUDIDs.insert(savedDeviceUDID).inserted {
            if connectedDeviceSet.contains(savedDeviceUDID) {
                if let reorderedDeviceUDID = reorderedConnectedDevices.next() {
                    updatedOrder.append(reorderedDeviceUDID)
                }
            } else {
                updatedOrder.append(savedDeviceUDID)
            }
        }
        while let reorderedDeviceUDID = reorderedConnectedDevices.next() {
            updatedOrder.append(reorderedDeviceUDID)
        }
        installationDeviceOrder = updatedOrder.isEmpty ? nil : updatedOrder
    }

    func configurationMatchingScheme(_ selectedScheme: String) -> String? {
        let normalizedScheme = selectedScheme.lowercased()
        return availableConfigurations.first { configuration in
            let distinctiveName = configuration.lowercased()
                .replacingOccurrences(of: "debug", with: "")
                .replacingOccurrences(of: "release", with: "")
                .replacingOccurrences(of: "profile", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return !distinctiveName.isEmpty && normalizedScheme.contains(distinctiveName)
        }
    }
}

struct ProjectDescriptor: Equatable {
    let displayName: String
    let folderPath: String
    let containerPath: String
    let containerKind: ProjectContainerKind
    let schemes: [String]
    let configurations: [String]
    let installScriptPath: String?
    var supportedDeviceFamilies: Set<MobileDeviceFamily>? = nil
    var bundleIdentifier: String? = nil
    var projectSigningTeamID: String? = nil
    var applicationPlatform: ApplicationPlatform? = nil

    func makeManagedProject() -> ManagedProject {
        let preferredScheme = Self.preferredScheme(in: schemes, projectName: displayName)
        let preferredConfiguration = configurations.contains("Debug")
            ? "Debug"
            : configurations.first(where: { $0.localizedCaseInsensitiveContains("debug") })
                ?? configurations.first
                ?? "Debug"

        return ManagedProject(
            id: UUID(),
            displayName: displayName,
            folderPath: folderPath,
            containerPath: containerPath,
            containerKind: containerKind,
            scheme: preferredScheme,
            configuration: preferredConfiguration,
            availableSchemes: schemes,
            availableConfigurations: configurations,
            installMethod: .xcodebuild,
            installScriptPath: installScriptPath,
            isEnabled: true,
            marketingVersion: nil,
            buildNumber: nil,
            supportedDeviceFamilies: supportedDeviceFamilies,
            bundleIdentifier: bundleIdentifier,
            projectSigningTeamID: projectSigningTeamID,
            applicationPlatform: applicationPlatform
        )
    }

    private static func preferredScheme(in schemes: [String], projectName: String) -> String {
        if let exact = schemes.first(where: { $0.caseInsensitiveCompare(projectName) == .orderedSame }) {
            return exact
        }

        let unsuitableSuffixes = ["tests", "uitests", "widget", "watch", "share"]
        if let applicationScheme = schemes.first(where: { scheme in
            !unsuitableSuffixes.contains(where: { scheme.lowercased().hasSuffix($0) })
        }) {
            return applicationScheme
        }

        return schemes.first ?? projectName
    }
}
