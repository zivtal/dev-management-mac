import Foundation

struct AppStoreConnectBuildUpload: Equatable, Sendable {
    let id: String
    let state: String
    let errors: [String]

    var wasAccepted: Bool { state == "PROCESSING" || state == "COMPLETE" }

    func checkForFailure() throws {
        if state == "FAILED" {
            throw AppStoreConnectError.requestFailed(422, L10n.format(
                "Apple could not process the uploaded build: %@",
                errors.isEmpty ? state : errors.joined(separator: "\n")
            ))
        }
    }
}

extension AppStoreConnectService {
    /// Build uploads exist before /builds exposes a processed TestFlight build.
    func buildUpload(
        appID: String, marketingVersion: String, buildNumber: String
    ) async throws -> AppStoreConnectBuildUpload? {
        let uploads = try await pagedData(path: "/v1/apps/\(appID)/buildUploads", query: [
            "filter[cfBundleShortVersionString]": marketingVersion,
            "filter[cfBundleVersion]": buildNumber,
            "filter[platform]": "IOS",
            "sort": "-uploadedDate",
            "limit": "200"
        ])
        return Self.matchingBuildUpload(in: uploads, marketingVersion: marketingVersion, buildNumber: buildNumber)
    }

    func isBuildSubmitted(appID: String, marketingVersion: String, buildID: String) async throws -> Bool {
        let versions = try await pagedData(path: "/v1/apps/\(appID)/appStoreVersions", query: [
            "filter[versionString]": marketingVersion,
            "filter[platform]": "IOS",
            "fields[appStoreVersions]": "versionString,appStoreState,build",
            "include": "build",
            "limit": "200"
        ])
        return versions.contains { version in
            let attributes = version["attributes"] as? [String: Any] ?? [:]
            let relationships = version["relationships"] as? [String: Any] ?? [:]
            let build = relationships["build"] as? [String: Any] ?? [:]
            let data = build["data"] as? [String: Any] ?? [:]
            return attributes["versionString"] as? String == marketingVersion
                && data["id"] as? String == buildID
                && Self.submittedVersionStates.contains(attributes["appStoreState"] as? String ?? "")
        }
    }

    private static let submittedVersionStates: Set<String> = [
        "WAITING_FOR_REVIEW", "IN_REVIEW", "PENDING_APPLE_RELEASE", "PENDING_DEVELOPER_RELEASE",
        "PROCESSING_FOR_APP_STORE", "READY_FOR_SALE", "READY_FOR_DISTRIBUTION",
        "PREORDER_READY_FOR_SALE"
    ]

    static func matchingBuildUpload(
        in uploads: [[String: Any]], marketingVersion: String, buildNumber: String
    ) -> AppStoreConnectBuildUpload? {
        let matches = uploads.compactMap { resource -> AppStoreConnectBuildUpload? in
            guard let id = resource["id"] as? String,
                  let attributes = resource["attributes"] as? [String: Any],
                  attributes["cfBundleShortVersionString"] as? String == marketingVersion,
                  attributes["cfBundleVersion"] as? String == buildNumber,
                  attributes["platform"] as? String == "IOS",
                  let state = attributes["state"] as? [String: Any],
                  let value = state["state"] as? String else { return nil }
            let errors = (state["errors"] as? [[String: Any]] ?? []).map { error in
                [error["code"] as? String, error["description"] as? String]
                    .compactMap { $0 }.joined(separator: ": ")
            }
            return AppStoreConnectBuildUpload(id: id, state: value, errors: errors)
        }
        // A completed retry takes precedence over an earlier failed transfer.
        return matches.first(where: { $0.wasAccepted }) ?? matches.first
    }
}
