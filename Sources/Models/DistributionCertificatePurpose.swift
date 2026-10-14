import Foundation

enum DistributionCertificatePurpose: Sendable {
    case application
    case macInstaller

    var apiType: String { self == .macInstaller ? "MAC_INSTALLER_DISTRIBUTION" : "DISTRIBUTION" }
    var acceptedTypes: Set<String> {
        self == .macInstaller ? ["MAC_INSTALLER_DISTRIBUTION"] : ["DISTRIBUTION", "IOS_DISTRIBUTION"]
    }
    var namePrefixes: [String] {
        self == .macInstaller ? ["3rd Party Mac Developer Installer:", "Mac Installer Distribution:"]
            : ["Apple Distribution:", "iPhone Distribution:"]
    }
}
