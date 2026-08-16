import Foundation

enum L10n {
    static func text(_ key: String) -> String {
        NSLocalizedString(key, bundle: .main, value: key, comment: "")
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: Locale.current, arguments: arguments)
    }

    static func text(_ key: String, localeIdentifier: String) -> String {
        let normalized = localeIdentifier.replacingOccurrences(of: "_", with: "-")
        let language = normalized.split(separator: "-").first.map(String.init)
        let candidates = [normalized, language].compactMap { $0 }
        for candidate in candidates {
            guard let path = Bundle.main.path(forResource: candidate, ofType: "lproj"),
                  let bundle = Bundle(path: path) else {
                continue
            }
            return NSLocalizedString(key, bundle: bundle, value: key, comment: "")
        }
        return text(key)
    }
}
