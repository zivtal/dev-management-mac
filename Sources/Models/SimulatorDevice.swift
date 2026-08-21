import Foundation

struct SimulatorDevice: Identifiable, Equatable, Sendable {
    let udid: String
    let name: String
    let state: String
    let runtimeIdentifier: String
    var deviceTypeIdentifier: String? = nil

    var id: String { udid }

    var isBooted: Bool { state == "Booted" }

    var isIOS: Bool {
        runtimeIdentifier.lowercased().contains("ios-")
    }

    var mobileDeviceFamily: MobileDeviceFamily? {
        guard isIOS else { return nil }
        if let deviceTypeIdentifier {
            if deviceTypeIdentifier.contains("iPad") { return .iPad }
            if deviceTypeIdentifier.contains("iPhone") { return .iPhone }
        }
        return name.localizedCaseInsensitiveContains("iPad") ? .iPad : .iPhone
    }

    /// Devices created programmatically by test scripts (e.g. "ios_sim_1756199254",
    /// "test_flow_1756199150") that clutter the picker without being real targets.
    var isEphemeralTestDevice: Bool {
        name.range(
            of: #"^[a-z][a-z0-9_]*_[0-9]{6,}$"#,
            options: .regularExpression
        ) != nil
    }

    var runtimeVersion: [Int] {
        runtimeIdentifier.split(separator: "-").suffix(3).compactMap { Int($0) }
    }

    var friendlyRuntime: String {
        let component = runtimeIdentifier.split(separator: ".").last.map(String.init)
            ?? runtimeIdentifier
        return component
            .replacingOccurrences(of: "-", with: " ", options: [], range: component.range(of: "-"))
            .replacingOccurrences(of: "-", with: ".")
    }

    var displayTitle: String {
        "\(name) — \(friendlyRuntime)"
    }

    static func availableDevices(fromSimctlList data: Data) -> [SimulatorDevice] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let runtimes = root["devices"] as? [String: [[String: Any]]] else {
            return []
        }
        return runtimes.flatMap { runtime, values in
            values.compactMap { value -> SimulatorDevice? in
                guard value["isAvailable"] as? Bool != false,
                      let udid = value["udid"] as? String,
                      let name = value["name"] as? String
                else { return nil }
                return SimulatorDevice(
                    udid: udid,
                    name: name,
                    state: value["state"] as? String ?? "Shutdown",
                    runtimeIdentifier: runtime,
                    deviceTypeIdentifier: value["deviceTypeIdentifier"] as? String
                )
            }
        }
    }

    static func compatibleIOSDevices(
        in devices: [SimulatorDevice],
        supportedFamilies: Set<MobileDeviceFamily>
    ) -> [SimulatorDevice] {
        devices
            .filter { device in
                !device.isEphemeralTestDevice
                    && device.mobileDeviceFamily.map(supportedFamilies.contains) == true
            }
            .sorted { lhs, rhs in
                if lhs.runtimeVersion != rhs.runtimeVersion {
                    return rhs.runtimeVersion.lexicographicallyPrecedes(lhs.runtimeVersion)
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    static func preferredDevice(
        in devices: [SimulatorDevice],
        supportedFamilies: Set<MobileDeviceFamily>
    ) -> SimulatorDevice? {
        let compatible = compatibleIOSDevices(in: devices, supportedFamilies: supportedFamilies)
        if let booted = compatible.first(where: \.isBooted) {
            return booted
        }
        let newestRuntime = compatible.first?.runtimeVersion
        let newest = compatible.filter { $0.runtimeVersion == newestRuntime }
        return newest.first { $0.mobileDeviceFamily == .iPhone } ?? newest.first
    }
}
