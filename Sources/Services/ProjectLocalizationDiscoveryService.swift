import Foundation

struct ProjectLocalizationDiscoveryService {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func discover(project: ManagedProject, defaultLocale: String) -> [String] {
        var locales = Set<String>()
        locales.insert(Self.normalizedAppStoreLocale(defaultLocale))

        guard let enumerator = fileManager.enumerator(
            at: project.folderURL,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return locales.sorted()
        }

        for case let url as URL in enumerator {
            let depth = url.pathComponents.count - project.folderURL.pathComponents.count
            if depth > 9 || Self.isIgnored(url) {
                enumerator.skipDescendants()
                continue
            }

            if url.pathExtension.lowercased() == "lproj" {
                Self.insert(url.deletingPathExtension().lastPathComponent, into: &locales)
                continue
            }
            switch url.pathExtension.lowercased() {
            case "xcstrings":
                discoverXCStringsLocales(url, into: &locales)
            case "plist":
                discoverPropertyListLocales(url, into: &locales)
            case "pbxproj":
                discoverProjectLocales(url, into: &locales)
            default:
                break
            }
        }
        return locales.sorted { lhs, rhs in
            if lhs == rhs { return false }
            if lhs == Self.normalizedAppStoreLocale(defaultLocale) { return true }
            if rhs == Self.normalizedAppStoreLocale(defaultLocale) { return false }
            return lhs < rhs
        }
    }

    private func discoverXCStringsLocales(_ url: URL, into locales: inout Set<String>) {
        guard let data = try? Data(contentsOf: url),
              data.count <= 5_000_000,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        if let sourceLanguage = root["sourceLanguage"] as? String {
            Self.insert(sourceLanguage, into: &locales)
        }
        guard let strings = root["strings"] as? [String: Any] else { return }
        for value in strings.values {
            guard let entry = value as? [String: Any],
                  let localizedValues = entry["localizations"] as? [String: Any]
            else { continue }
            for locale in localizedValues.keys {
                Self.insert(locale, into: &locales)
            }
        }
    }

    private func discoverPropertyListLocales(_ url: URL, into locales: inout Set<String>) {
        guard let data = try? Data(contentsOf: url), data.count <= 1_000_000,
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = root as? [String: Any]
        else { return }
        if let developmentRegion = dictionary["CFBundleDevelopmentRegion"] as? String,
           !developmentRegion.contains("$(") {
            Self.insert(developmentRegion, into: &locales)
        }
        for locale in dictionary["CFBundleLocalizations"] as? [String] ?? [] {
            Self.insert(locale, into: &locales)
        }
    }

    private func discoverProjectLocales(_ url: URL, into locales: inout Set<String>) {
        guard let contents = try? String(contentsOf: url, encoding: .utf8),
              contents.count <= 10_000_000 else { return }
        if let expression = try? NSRegularExpression(pattern: #"developmentRegion\s*=\s*\"?([^;\"\s]+)"#),
           let match = expression.firstMatch(
                in: contents,
                range: NSRange(contents.startIndex..., in: contents)
           ), let range = Range(match.range(at: 1), in: contents) {
            Self.insert(String(contents[range]), into: &locales)
        }
        guard let expression = try? NSRegularExpression(
            pattern: #"knownRegions\s*=\s*\((.*?)\);"#,
            options: [.dotMatchesLineSeparators]
        ), let match = expression.firstMatch(
            in: contents,
            range: NSRange(contents.startIndex..., in: contents)
        ), let range = Range(match.range(at: 1), in: contents) else { return }
        for rawValue in contents[range].split(separator: ",") {
            Self.insert(
                rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"")),
                into: &locales
            )
        }
    }

    private static func insert(_ rawLocale: String, into locales: inout Set<String>) {
        let value = rawLocale.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.caseInsensitiveCompare("Base") != .orderedSame else { return }
        locales.insert(normalizedAppStoreLocale(value))
    }

    static func normalizedAppStoreLocale(_ rawLocale: String) -> String {
        let normalized = rawLocale.replacingOccurrences(of: "_", with: "-")
        guard !normalized.contains("-") else { return normalized }
        return [
            "en": "en-US", "ar": "ar-SA", "ca": "ca", "cs": "cs", "da": "da",
            "de": "de-DE", "el": "el", "es": "es-ES", "fi": "fi", "fr": "fr-FR",
            "he": "he", "hi": "hi", "hr": "hr", "hu": "hu", "id": "id",
            "it": "it", "ja": "ja", "ko": "ko", "ms": "ms", "nl": "nl-NL",
            "no": "no", "pl": "pl", "pt": "pt-PT", "ro": "ro", "ru": "ru",
            "sk": "sk", "sv": "sv", "th": "th", "tr": "tr", "uk": "uk",
            "vi": "vi", "zh": "zh-Hans"
        ][normalized.lowercased()] ?? normalized
    }

    private static func isIgnored(_ url: URL) -> Bool {
        let components = Set(url.pathComponents.map { $0.lowercased() })
        return !components.isDisjoint(with: [
            "build", "deriveddata", "node_modules", ".build", "pods", ".git"
        ])
    }
}
