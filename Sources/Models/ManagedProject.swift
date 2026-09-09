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
    var appStoreConnectCredentialProfileID: UUID? = nil
    var simulatorRunSettings: SimulatorRunSettings? = nil
    var simulatorTestedDeviceUDIDs: Set<String>? = nil
    /// Git branch whose committed tip is built for installs. `nil` (or blank)
    /// builds the working copy at `folderPath` exactly as checked out.
    var buildBranch: String? = nil

    var folderURL: URL { URL(fileURLWithPath: folderPath, isDirectory: true) }
    var containerURL: URL { URL(fileURLWithPath: containerPath) }

    var normalizedBuildBranch: String? {
        guard let branch = buildBranch?.trimmingCharacters(in: .whitespacesAndNewlines),
              !branch.isEmpty else { return nil }
        return branch
    }

    var buildsFromWorkingCopy: Bool {
        normalizedBuildBranch == nil
    }

    /// Text for the popover's Branch column: the selected build branch, or
    /// the working copy's current branch when installs follow the checkout.
    func buildBranchDisplayName(workingCopyBranch: String?) -> String {
        normalizedBuildBranch ?? workingCopyBranch ?? "—"
    }

    /// Branch choices for pickers in the Git service's order (local branches,
    /// then remote-only ones), always including the selected branch so a
    /// branch that has since been deleted still shows as chosen.
    func buildBranchOptions(available: [String]) -> [String] {
        guard let selected = normalizedBuildBranch, !available.contains(selected) else {
            return available
        }
        return [selected] + available
    }

    /// Returns a copy whose folder and container point into `checkoutURL`,
    /// preserving the container's path relative to the repository root.
    func rerooted(to checkoutURL: URL) -> ManagedProject {
        var copy = self
        let originalFolder = folderURL.standardizedFileURL.path
        let originalContainer = containerURL.standardizedFileURL.path
        var relativeContainer = originalContainer.hasPrefix(originalFolder)
            ? String(originalContainer.dropFirst(originalFolder.count))
            : containerURL.lastPathComponent
        while relativeContainer.hasPrefix("/") { relativeContainer.removeFirst() }
        let newFolder = checkoutURL.standardizedFileURL
        copy.folderPath = newFolder.path
        copy.containerPath = relativeContainer.isEmpty
            ? newFolder.path
            : newFolder.appendingPathComponent(relativeContainer).path
        return copy
    }

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

    /// Simulator sessions must build Debug like run-emulator.sh: debug-only
    /// affordances (e.g. simulated-date environment variables) are compiled
    /// out of Release builds.
    var simulatorBuildConfiguration: String {
        if availableConfigurations.contains("Debug") { return "Debug" }
        return availableConfigurations.first { $0.localizedCaseInsensitiveContains("debug") }
            ?? configuration
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
