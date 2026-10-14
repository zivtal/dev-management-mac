import Foundation

enum AppStoreCopyrightError: LocalizedError {
    case missingOwner
    case containsLink

    var errorDescription: String? {
        switch self {
        case .missingOwner:
            L10n.text("Copyright owner is required.")
        case .containsLink:
            L10n.text("Copyright must contain the owner's name, not a website URL or email address.")
        }
    }
}

enum AppStoreCopyrightNormalizer {
    static func validationError(for value: String) -> AppStoreCopyrightError? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .missingOwner }
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        if detector?.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil {
            return .containsLink
        }
        return nil
    }

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
