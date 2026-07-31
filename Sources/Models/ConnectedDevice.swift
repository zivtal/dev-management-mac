import Foundation

struct ConnectedDevice: Identifiable, Codable, Equatable {
    let udid: String
    let name: String
    let model: String?
    let platform: String
    let transportType: String?
    let isInstallReady: Bool

    var id: String { udid }

    var connectionDescription: String {
        switch transportType?.lowercased() {
        case "localnetwork": L10n.text("Wi‑Fi")
        case "wired", "usb": L10n.text("USB")
        default: L10n.text("Connected")
        }
    }

    var supportsIOSAppInstallation: Bool {
        platform.lowercased() == "ios"
    }

    var platformDescription: String {
        switch platform.lowercased() {
        case "ios" where model?.lowercased().contains("ipad") == true: "iPadOS"
        case "ios": "iOS"
        case "watchos": "watchOS"
        default: platform
        }
    }

    var symbolName: String {
        switch platform.lowercased() {
        case "watchos": "applewatch"
        case "ios" where model?.lowercased().contains("ipad") == true: "ipad"
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
                  ["ios", "watchos"].contains(platform.lowercased()),
                  payload.connectionProperties?.pairingState?.lowercased() == "paired",
                  let udid = payload.hardwareProperties?.udid,
                  !udid.isEmpty
            else {
                return nil
            }

            return ConnectedDevice(
                udid: udid,
                name: payload.deviceProperties?.name ?? "iPhone",
                model: payload.hardwareProperties?.marketingName,
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
