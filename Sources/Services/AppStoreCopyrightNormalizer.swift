import Foundation

enum AppStoreCopyrightNormalizer {
    static func normalized(_ value: String, referenceDate: Date = Date()) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let first = trimmed.split(whereSeparator: \.isWhitespace).first,
           first.count == 4,
           first.allSatisfy(\.isNumber) {
            return trimmed
        }
        let year = Calendar(identifier: .gregorian).component(.year, from: referenceDate)
        return "\(year) \(trimmed)"
    }
}
