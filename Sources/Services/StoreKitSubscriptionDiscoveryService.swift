import Foundation

enum StoreKitSubscriptionDiscoveryError: LocalizedError {
    case invalidConfiguration(String, String)
    case unsupportedPeriod(String, String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let file, let reason):
            return L10n.format("Could not read subscription configuration %@: %@", file, reason)
        case .unsupportedPeriod(let period, let productID):
            return L10n.format("Subscription %@ uses unsupported period %@.", productID, period)
        }
    }
}

final class StoreKitSubscriptionDiscoveryService {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func discover(project: ManagedProject, defaultLocale: String) throws -> AppStoreSubscriptionCatalog {
        let rootManifestURLs = ["app-store-publishing.json", ".app-store-publishing.json"]
            .map(project.folderURL.appendingPathComponent)
            .filter { fileManager.fileExists(atPath: $0.path) }
        let nestedManifestURLs = discoverFiles(withExtension: "json", in: project.folderURL)
            .filter { $0.lastPathComponent == "app-store-publishing.json" }
        let rootManifestSet = Set(rootManifestURLs)
        let manifestURLs = rootManifestURLs
            + nestedManifestURLs.filter { !rootManifestSet.contains($0) }
        let manifest = try manifestURLs.first.map(loadManifest)
        let storeKitURLs = discoverFiles(withExtension: "storekit", in: project.folderURL)
        let effectiveLocale = manifest?.publication?.locale?.nilIfEmpty ?? defaultLocale

        var groups = try storeKitURLs.flatMap { try loadStoreKitConfiguration($0, defaultLocale: effectiveLocale) }
        if let manifestGroups = manifest?.subscriptions?.groups {
            groups = merge(groups: groups, overrides: manifestGroups)
        }

        let defaults = manifest?.subscriptions
        let fallbackReviewScreenshot = defaults?.reviewScreenshot
            ?? discoverSubscriptionReviewScreenshot(in: project.folderURL)?.path
        for groupIndex in groups.indices {
            if groupIndex < groups.count, groups[groupIndex].localizations?.isEmpty != false {
                groups[groupIndex].localizations = [
                    AppStoreSubscriptionLocalization(
                        locale: effectiveLocale,
                        name: groups[groupIndex].referenceName,
                        description: nil
                    )
                ]
            }
            for subscriptionIndex in groups[groupIndex].subscriptions.indices {
                var subscription = groups[groupIndex].subscriptions[subscriptionIndex]
                subscription.period = try Self.applePeriod(
                    subscription.period,
                    productID: subscription.productID
                )
                subscription.baseTerritory = subscription.baseTerritory
                    ?? defaults?.baseTerritory
                subscription.availableInAllTerritories = subscription.availableInAllTerritories
                    ?? defaults?.availableInAllTerritories
                subscription.reviewScreenshot = subscription.reviewScreenshot
                    ?? fallbackReviewScreenshot
                if subscription.localizations?.isEmpty != false {
                    subscription.localizations = [
                        AppStoreSubscriptionLocalization(
                            locale: effectiveLocale,
                            name: Self.readableName(subscription.referenceName),
                            description: Self.fallbackDescription(
                                name: subscription.referenceName,
                                period: subscription.period
                            )
                        )
                    ]
                } else {
                    subscription.localizations = subscription.localizations?.map {
                        AppStoreSubscriptionLocalization(
                            locale: Self.normalizedLocale($0.locale),
                            name: $0.name,
                            description: $0.description
                        )
                    }
                }
                groups[groupIndex].subscriptions[subscriptionIndex] = subscription
            }
        }

        let configuredIDs = Set(groups.flatMap(\.subscriptions).map(\.productID))
        let sourceProducts = discoverProductIdentifiers(in: project.folderURL)
        return AppStoreSubscriptionCatalog(
            publication: manifest?.publication,
            application: manifest?.application,
            compliance: manifest?.compliance,
            groups: groups,
            detectedProductIDs: sourceProducts.identifiers.union(configuredIDs),
            sourceFiles: manifestURLs.map { Self.relativePath($0, from: project.folderURL) }
                + storeKitURLs.map { Self.relativePath($0, from: project.folderURL) }
                + sourceProducts.sourceFiles.sorted(),
            projectDirectory: project.folderURL
        )
    }

    private func loadManifest(_ url: URL) throws -> AppStorePublishingManifest {
        do {
            let manifest = try JSONDecoder().decode(
                AppStorePublishingManifest.self,
                from: Data(contentsOf: url)
            )
            guard manifest.schemaVersion == nil || manifest.schemaVersion == 1 else {
                throw StoreKitSubscriptionDiscoveryError.invalidConfiguration(
                    url.lastPathComponent,
                    L10n.text("unsupported schema version")
                )
            }
            return manifest
        } catch let error as StoreKitSubscriptionDiscoveryError {
            throw error
        } catch {
            throw StoreKitSubscriptionDiscoveryError.invalidConfiguration(
                url.lastPathComponent,
                error.localizedDescription
            )
        }
    }

    private func loadStoreKitConfiguration(
        _ url: URL,
        defaultLocale: String
    ) throws -> [AppStoreSubscriptionGroupDefinition] {
        do {
            guard let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
            else {
                throw StoreKitSubscriptionDiscoveryError.invalidConfiguration(
                    url.lastPathComponent,
                    L10n.text("the file does not contain a JSON object")
                )
            }
            let rawGroups = root["subscriptionGroups"] as? [[String: Any]] ?? []
            return try rawGroups.compactMap { rawGroup in
                let rawSubscriptions = rawGroup["subscriptions"] as? [[String: Any]] ?? []
                let subscriptions = try rawSubscriptions.compactMap { raw -> AppStoreSubscriptionDefinition? in
                    guard let productID = Self.string(raw, keys: ["productID", "productId"]),
                          !productID.isEmpty else { return nil }
                    let referenceName = Self.string(raw, keys: ["referenceName", "name"])
                        ?? Self.readableName(productID.split(separator: ".").last.map(String.init) ?? productID)
                    let rawPeriod = Self.string(raw, keys: ["recurringSubscriptionPeriod", "subscriptionPeriod"])
                        ?? Self.inferredPeriod(from: productID)
                        ?? ""
                    return AppStoreSubscriptionDefinition(
                        referenceName: referenceName,
                        productID: productID,
                        period: try Self.applePeriod(rawPeriod, productID: productID),
                        basePrice: Self.decimalString(raw["displayPrice"]),
                        baseTerritory: nil,
                        availableInAllTerritories: nil,
                        familySharable: Self.bool(raw, keys: ["familyShareable", "familySharable"]),
                        groupLevel: Self.integer(raw, keys: ["groupNumber", "groupLevel"]),
                        reviewNote: Self.string(raw, keys: ["reviewNote"]),
                        reviewScreenshot: nil,
                        localizations: Self.localizations(raw["localizations"], defaultLocale: defaultLocale)
                    )
                }
                guard !subscriptions.isEmpty else { return nil }
                let referenceName = Self.string(rawGroup, keys: ["name", "referenceName"])
                    ?? L10n.text("Subscriptions")
                return AppStoreSubscriptionGroupDefinition(
                    referenceName: referenceName,
                    localizations: Self.localizations(rawGroup["localizations"], defaultLocale: defaultLocale),
                    subscriptions: subscriptions
                )
            }
        } catch let error as StoreKitSubscriptionDiscoveryError {
            throw error
        } catch {
            throw StoreKitSubscriptionDiscoveryError.invalidConfiguration(
                url.lastPathComponent,
                error.localizedDescription
            )
        }
    }

    private func merge(
        groups: [AppStoreSubscriptionGroupDefinition],
        overrides: [AppStoreSubscriptionGroupDefinition]
    ) -> [AppStoreSubscriptionGroupDefinition] {
        var result = groups
        for override in overrides {
            if let groupIndex = result.firstIndex(where: {
                $0.referenceName.caseInsensitiveCompare(override.referenceName) == .orderedSame
                    || !$0.subscriptions.map(\.productID).allSatisfy(
                        { !override.subscriptions.map(\.productID).contains($0) }
                    )
            }) {
                var group = result[groupIndex]
                group.referenceName = override.referenceName
                group.localizations = override.localizations ?? group.localizations
                for subscription in override.subscriptions {
                    if let index = group.subscriptions.firstIndex(where: { $0.productID == subscription.productID }) {
                        group.subscriptions[index] = subscription
                    } else {
                        group.subscriptions.append(subscription)
                    }
                }
                result[groupIndex] = group
            } else {
                result.append(override)
            }
        }
        return result
    }

    private func discoverFiles(withExtension pathExtension: String, in root: URL) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var results: [URL] = []
        for case let url as URL in enumerator {
            let relativeDepth = url.pathComponents.count - root.pathComponents.count
            if relativeDepth > 8 || Self.isIgnored(url) {
                enumerator.skipDescendants()
                continue
            }
            if url.pathExtension.lowercased() == pathExtension.lowercased() {
                results.append(url)
            }
        }
        return results.sorted { $0.path < $1.path }
    }

    private struct ProductIdentifierDiscovery {
        var identifiers: Set<String> = []
        var sourceFiles: Set<String> = []
    }

    private func discoverProductIdentifiers(in root: URL) -> ProductIdentifierDiscovery {
        let extensions = Set(["swift", "m", "mm", "h", "json", "plist", "yml", "yaml", "js", "ts"])
        guard let expression = try? NSRegularExpression(
            pattern: #"[\"']((?:[A-Za-z0-9_-]+\.){2,}[A-Za-z0-9._-]+)[\"']"#
        ), let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return ProductIdentifierDiscovery() }
        var results = ProductIdentifierDiscovery()
        for case let url as URL in enumerator {
            let relativeDepth = url.pathComponents.count - root.pathComponents.count
            if relativeDepth > 8 || Self.isIgnored(url) {
                enumerator.skipDescendants()
                continue
            }
            let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            guard extensions.contains(url.pathExtension.lowercased()),
                  fileSize < 1_000_000,
                  let contents = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let range = NSRange(contents.startIndex..., in: contents)
            for match in expression.matches(in: contents, range: range) {
                guard let productRange = Range(match.range(at: 1), in: contents) else { continue }
                let productID = String(contents[productRange])
                let lower = productID.lowercased()
                let contextStart = contents.index(productRange.lowerBound, offsetBy: -160, limitedBy: contents.startIndex)
                    ?? contents.startIndex
                let contextEnd = contents.index(productRange.upperBound, offsetBy: 160, limitedBy: contents.endIndex)
                    ?? contents.endIndex
                let context = (
                    String(contents[contextStart..<productRange.lowerBound])
                        + String(contents[productRange.upperBound..<contextEnd])
                ).lowercased()
                let looksLikeSubscription = ["subscription", "premium", "monthly", "annual", "yearly", "weekly"]
                    .contains(where: lower.contains)
                let hasProductContext = ["productid", "product_ids", "products(for", "product.products", "purchase"]
                    .contains(where: context.contains)
                if looksLikeSubscription && hasProductContext {
                    results.identifiers.insert(productID)
                    results.sourceFiles.insert(Self.relativePath(url, from: root))
                }
            }
        }
        return results
    }

    private func discoverSubscriptionReviewScreenshot(in root: URL) -> URL? {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }
        for case let url as URL in enumerator {
            if Self.isIgnored(url) {
                enumerator.skipDescendants()
                continue
            }
            let path = url.path.lowercased()
            guard ["png", "jpg", "jpeg"].contains(url.pathExtension.lowercased()),
                  path.contains("screenshot"),
                  path.contains("subscription") || path.contains("paywall") else { continue }
            return url
        }
        return nil
    }

    private static func localizations(
        _ value: Any?,
        defaultLocale: String
    ) -> [AppStoreSubscriptionLocalization]? {
        guard let rawLocalizations = value as? [[String: Any]], !rawLocalizations.isEmpty else {
            return nil
        }
        let result = rawLocalizations.compactMap { raw -> AppStoreSubscriptionLocalization? in
            guard let name = string(raw, keys: ["displayName", "name", "customAppName"]),
                  !name.isEmpty else { return nil }
            return AppStoreSubscriptionLocalization(
                locale: normalizedLocale(string(raw, keys: ["locale"]) ?? defaultLocale),
                name: name,
                description: string(raw, keys: ["description"])
            )
        }
        return result.isEmpty ? nil : result
    }

    static func applePeriod(_ value: String, productID: String) throws -> String {
        let normalized = value.uppercased().replacingOccurrences(of: "-", with: "_")
        let mapped: String?
        switch normalized {
        case "P1W", "ONE_WEEK", "WEEKLY": mapped = "ONE_WEEK"
        case "P1M", "ONE_MONTH", "MONTHLY": mapped = "ONE_MONTH"
        case "P2M", "TWO_MONTHS": mapped = "TWO_MONTHS"
        case "P3M", "THREE_MONTHS", "QUARTERLY": mapped = "THREE_MONTHS"
        case "P6M", "SIX_MONTHS", "SEMI_ANNUAL", "SEMIANNUAL": mapped = "SIX_MONTHS"
        case "P1Y", "ONE_YEAR", "YEARLY", "ANNUAL": mapped = "ONE_YEAR"
        default: mapped = inferredPeriod(from: normalized)
        }
        guard let mapped else {
            throw StoreKitSubscriptionDiscoveryError.unsupportedPeriod(value, productID)
        }
        return mapped
    }

    private static func inferredPeriod(from value: String) -> String? {
        let lower = value.lowercased()
        if lower.contains("week") { return "ONE_WEEK" }
        if lower.contains("year") || lower.contains("annual") { return "ONE_YEAR" }
        if lower.contains("month") { return "ONE_MONTH" }
        return nil
    }

    private static func normalizedLocale(_ locale: String) -> String {
        locale.replacingOccurrences(of: "_", with: "-")
    }

    private static func readableName(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    private static func fallbackDescription(name: String, period: String) -> String {
        let duration: String
        switch period {
        case "ONE_WEEK": duration = L10n.text("one week")
        case "ONE_MONTH": duration = L10n.text("one month")
        case "TWO_MONTHS": duration = L10n.text("two months")
        case "THREE_MONTHS": duration = L10n.text("three months")
        case "SIX_MONTHS": duration = L10n.text("six months")
        case "ONE_YEAR": duration = L10n.text("one year")
        default: duration = L10n.text("the selected period")
        }
        return L10n.format("%@ access for %@.", readableName(name), duration)
    }

    private static func isIgnored(_ url: URL) -> Bool {
        let components = Set(url.pathComponents.map { $0.lowercased() })
        return !components.isDisjoint(with: ["build", "deriveddata", "node_modules", ".build", "pods"])
    }

    private static func relativePath(_ url: URL, from root: URL) -> String {
        let fileComponents = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let rootComponents = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard fileComponents.starts(with: rootComponents) else { return url.lastPathComponent }
        return fileComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    private static func string(_ dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dictionary[key] as? String { return value }
        }
        return nil
    }

    private static func bool(_ dictionary: [String: Any], keys: [String]) -> Bool? {
        for key in keys {
            if let value = dictionary[key] as? Bool { return value }
        }
        return nil
    }

    private static func integer(_ dictionary: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = dictionary[key] as? Int { return value }
            if let value = dictionary[key] as? NSNumber { return value.intValue }
        }
        return nil
    }

    private static func decimalString(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }
}
