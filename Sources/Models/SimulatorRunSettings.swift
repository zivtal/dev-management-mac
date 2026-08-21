import Foundation

struct SimulatorRunSettings: Codable, Equatable, Sendable {
    var deviceUDID: String? = nil
    var latitude: Double? = nil
    var longitude: Double? = nil
    var isLocationEnabled: Bool? = nil
    var simulatedDate: String? = nil
    var simulatedTime: String? = nil
    var language: String? = nil
    var debugNowVariableName: String? = nil

    static let simctlChildEnvironmentPrefix = "SIMCTL_CHILD_"

    var usesLocation: Bool {
        isLocationEnabled == true && latitude != nil && longitude != nil
    }

    var locationArgument: String? {
        guard usesLocation, let latitude, let longitude else { return nil }
        return "\(latitude),\(longitude)"
    }

    static func defaultDebugNowVariableName(forScheme scheme: String) -> String {
        var normalized = scheme.uppercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "_"
        }
        if normalized.first?.isNumber == true {
            normalized.insert("_", at: 0)
        }
        let name = String(normalized)
        return (name.isEmpty ? "APP" : name) + "_DEBUG_NOW"
    }

    func effectiveDebugNowVariableName(forScheme scheme: String) -> String {
        let trimmed = debugNowVariableName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty { return trimmed }
        return Self.defaultDebugNowVariableName(forScheme: scheme)
    }

    /// The simulated "now" the Debug app should believe in, mirroring
    /// run-emulator.sh: a bare date, or an ISO date-time carrying the Mac's
    /// current UTC offset. Returns nil when no date or time is configured.
    func simulatedNowValue(timeZone: TimeZone = .current, now: Date = Date()) -> String? {
        let trimmedDate = simulatedDate?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTime = simulatedTime?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasDate = trimmedDate?.isEmpty == false
        let hasTime = trimmedTime?.isEmpty == false
        guard hasDate || hasTime else { return nil }

        let date: String
        if let trimmedDate, hasDate {
            date = trimmedDate
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = "yyyy-MM-dd"
            date = formatter.string(from: now)
        }
        guard let trimmedTime, hasTime else { return date }

        let offsetSeconds = timeZone.secondsFromGMT(for: now)
        let sign = offsetSeconds < 0 ? "-" : "+"
        let absoluteOffset = abs(offsetSeconds)
        let offset = String(
            format: "%@%02d:%02d",
            sign,
            absoluteOffset / 3600,
            (absoluteOffset % 3600) / 60
        )
        return "\(date)T\(trimmedTime):00\(offset)"
    }

    /// Extra arguments for `simctl launch`, mirroring run-emulator.sh's
    /// `-AppleLanguages "(code)"` handling.
    var launchArguments: [String] {
        guard let language = language?.trimmingCharacters(in: .whitespacesAndNewlines),
              !language.isEmpty else {
            return []
        }
        return ["-AppleLanguages", "(\(language))"]
    }

    /// Environment for the `simctl launch` process. simctl forwards only
    /// SIMCTL_CHILD_-prefixed variables into the launched app.
    func launchEnvironment(
        forScheme scheme: String,
        timeZone: TimeZone = .current,
        now: Date = Date()
    ) -> [String: String] {
        guard let simulatedNow = simulatedNowValue(timeZone: timeZone, now: now) else {
            return [:]
        }
        let variable = effectiveDebugNowVariableName(forScheme: scheme)
        return [Self.simctlChildEnvironmentPrefix + variable: simulatedNow]
    }

    static func isValidDate(_ value: String) -> Bool {
        value.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil
    }

    static func isValidTime(_ value: String) -> Bool {
        value.range(of: #"^([01][0-9]|2[0-3]):[0-5][0-9]$"#, options: .regularExpression) != nil
    }

    static func isValidCoordinate(latitude: Double, longitude: Double) -> Bool {
        (-90.0...90.0).contains(latitude) && (-180.0...180.0).contains(longitude)
    }
}
