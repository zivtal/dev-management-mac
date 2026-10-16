import Foundation

enum DistributionCertificatePurpose: Sendable {
    case application
    case macApplication
    case macInstaller

    var apiType: String { self == .macInstaller ? "MAC_INSTALLER_DISTRIBUTION" : "DISTRIBUTION" }
    var acceptedTypes: Set<String> {
        switch self {
        case .application: ["DISTRIBUTION", "IOS_DISTRIBUTION"]
        case .macApplication: ["DISTRIBUTION"]
        case .macInstaller: ["MAC_INSTALLER_DISTRIBUTION"]
        }
    }
    var namePrefixes: [String] {
        switch self {
        case .application: ["Apple Distribution:", "iPhone Distribution:"]
        case .macApplication: ["Apple Distribution:"]
        case .macInstaller: ["3rd Party Mac Developer Installer:", "Mac Installer Distribution:"]
        }
    }
}
