import Foundation

enum MobileDeviceFamily: String, Codable, CaseIterable, Equatable {
    case iPhone
    case iPad
}

struct ConnectedDevice: Identifiable, Codable, Equatable {
    let udid: String
    let name: String
    let model: String?
    let platform: String
    let transportType: String?
    let isInstallReady: Bool

    var id: String { udid }

    var connectionDescription: String {
        let transportDescription = switch transportType?.lowercased() {
        case "localnetwork": L10n.text("Wi‑Fi")
        case "wired", "usb": L10n.text("USB")
        default: L10n.text("Connected")
        }
        guard !isInstallReady else { return transportDescription }
        return L10n.format("%@ · %@", transportDescription, L10n.text("Connecting…"))
    }

    var supportsIOSAppInstallation: Bool {
        mobileDeviceFamily != nil
    }

    var isAvailableInstallationTarget: Bool {
        supportsIOSAppInstallation && isInstallReady
    }

    var mobileDeviceFamily: MobileDeviceFamily? {
        if platform.lowercased() == "ipados" { return .iPad }
        guard platform.lowercased() == "ios" else { return nil }
        let identity = [model, name]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        return identity.contains("ipad") ? .iPad : .iPhone
    }

    var platformDescription: String {
        switch platform.lowercased() {
        case "ipados": "iPadOS"
        case "ios" where mobileDeviceFamily == .iPad: "iPadOS"
        case "ios": "iOS"
        case "watchos": "watchOS"
        default: platform
        }
    }

    var symbolName: String {
        switch platform.lowercased() {
        case "watchos": "applewatch"
        case "ipados": "ipad"
        case "ios" where mobileDeviceFamily == .iPad: "ipad"
        case "ios": "iphone"
        default: "display"
        }
    }
}

struct DeviceListEnvelope: Decodable {
    struct Result: Decodable {
        let devices: [DevicePayload]
    }

    struct DevicePayload: Decodable {
        struct HardwareProperties: Decodable {
            let platform: String?
            let udid: String?
            let marketingName: String?
            let deviceType: String?
            let productType: String?
        }

        struct DeviceProperties: Decodable {
            let name: String?
        }

        struct ConnectionProperties: Decodable {
            let pairingState: String?
            let tunnelState: String?
            let transportType: String?
        }

        let hardwareProperties: HardwareProperties?
        let deviceProperties: DeviceProperties?
        let connectionProperties: ConnectionProperties?
    }

    let result: Result

    var availableAppleDevices: [ConnectedDevice] {
        result.devices.compactMap { payload in
            guard let platform = payload.hardwareProperties?.platform,
                  ["ios", "ipados", "watchos"].contains(platform.lowercased()),
                  payload.connectionProperties?.pairingState?.lowercased() == "paired",
                  let udid = payload.hardwareProperties?.udid,
                  !udid.isEmpty
            else {
                return nil
            }

            return ConnectedDevice(
                udid: udid,
                name: payload.deviceProperties?.name ?? "iPhone",
                model: payload.hardwareProperties?.marketingName
                    ?? payload.hardwareProperties?.deviceType
                    ?? payload.hardwareProperties?.productType,
                platform: platform,
                transportType: payload.connectionProperties?.transportType,
                isInstallReady: payload.connectionProperties?.tunnelState?.lowercased() == "connected"
            )
        }
        .sorted { lhs, rhs in
            if lhs.supportsIOSAppInstallation != rhs.supportsIOSAppInstallation {
                return lhs.supportsIOSAppInstallation
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}
