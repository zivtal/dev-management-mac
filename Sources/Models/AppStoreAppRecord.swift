import Foundation

struct AppStoreAppRecord {
    var name: String
    var bundleID: String
    var sku: String
    var locale: String
    var version: String
    var platforms: Set<AppStorePlatform>

    func validated() throws -> Self {
        let cleaned = Self(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                           bundleID: bundleID.trimmingCharacters(in: .whitespacesAndNewlines),
                           sku: sku.trimmingCharacters(in: .whitespacesAndNewlines),
                           locale: AppStoreLocale.canonicalIdentifier(locale) ?? "",
                           version: version.trimmingCharacters(in: .whitespacesAndNewlines),
                           platforms: platforms)
        guard !cleaned.name.isEmpty, cleaned.name.count <= 30,
              !cleaned.bundleID.isEmpty, !cleaned.bundleID.contains("*"),
              !cleaned.sku.isEmpty, cleaned.sku.count <= 100,
              !cleaned.locale.isEmpty, !cleaned.version.isEmpty,
              !cleaned.platforms.isEmpty else {
            throw AppStoreConnectError.requestFailed(0, L10n.text(
                "Enter an app name (up to 30 characters), bundle ID, unique SKU, supported locale, version, and at least one platform."
            ))
        }
        return cleaned
    }

    /// Apple's authenticated website endpoint uses compound resources. This is not
    /// a public API-key endpoint. Keep its payload isolated from the public API client.
    func payload() throws -> [String: Any] {
        let value = try validated()
        func ref(_ type: String, _ id: String) -> [String: String] { ["type": type, "id": id] }
        let infoID = "${new-appInfo-id}"
        let localeID = "${new-appInfoLocalization-id}"
        var included: [[String: Any]] = [
            ["type": "appInfos", "id": infoID,
             "relationships": ["appInfoLocalizations": ["data": [ref("appInfoLocalizations", localeID)]]]],
            ["type": "appInfoLocalizations", "id": localeID,
             "attributes": ["locale": value.locale, "name": value.name]]
        ]
        var versions: [[String: String]] = []
        for platform in AppStorePlatform.allCases where value.platforms.contains(platform) {
            let versionID = "${store-version-\(platform.rawValue)}"
            let localizationID = "${new-\(platform.rawValue)VersionLocalization-id}"
            versions.append(ref("appStoreVersions", versionID))
            included.append([
                "type": "appStoreVersions", "id": versionID,
                "attributes": ["platform": platform.rawValue, "versionString": value.version],
                "relationships": ["appStoreVersionLocalizations": [
                    "data": [ref("appStoreVersionLocalizations", localizationID)]
                ]]
            ])
            included.append(["type": "appStoreVersionLocalizations", "id": localizationID,
                             "attributes": ["locale": value.locale]])
        }
        return ["data": ["type": "apps",
                         "attributes": ["sku": value.sku, "primaryLocale": value.locale, "bundleId": value.bundleID],
                         "relationships": ["appStoreVersions": ["data": versions],
                                           "appInfos": ["data": [ref("appInfos", infoID)]]]],
                "included": included]
    }
}
