import CryptoKit
import Foundation

struct AppStoreScreenshotAsset: Equatable, Sendable {
    let url: URL
    let displayType: String
}

struct AppStoreConnectPublication: Sendable {
    let appID: String
    let versionID: String
    let localizationID: String
}

enum AppStoreConnectError: LocalizedError {
    case invalidPrivateKey
    case invalidResponse
    case requestFailed(Int, String)
    case applicationNotFound(String)
    case missingIdentifier(String)
    case buildProcessingTimedOut

    var errorDescription: String? {
        switch self {
        case .invalidPrivateKey:
            return L10n.text("The App Store Connect private key is invalid. Import the .p8 key again.")
        case .invalidResponse:
            return L10n.text("App Store Connect returned an invalid response.")
        case .requestFailed(let status, let message):
            return L10n.format("App Store Connect request failed (HTTP %d): %@", status, message)
        case .applicationNotFound(let bundleIdentifier):
            return L10n.format("No App Store Connect application has bundle identifier %@.", bundleIdentifier)
        case .missingIdentifier(let name):
            return L10n.format("App Store Connect did not return the %@ identifier.", name)
        case .buildProcessingTimedOut:
            return L10n.text("The build upload succeeded, but App Store processing did not finish before the timeout.")
        }
    }
}

final class AppStoreConnectService {
    private let session: URLSession
    private let issuerID: String
    private let keyID: String
    private let privateKey: P256.Signing.PrivateKey
    private let baseURL = URL(string: "https://api.appstoreconnect.apple.com")!

    init(
        issuerID: String,
        keyID: String,
        privateKeyPEM: String,
        session: URLSession = .shared
    ) throws {
        self.issuerID = issuerID
        self.keyID = keyID
        self.session = session
        do {
            privateKey = try P256.Signing.PrivateKey(pemRepresentation: privateKeyPEM)
        } catch {
            throw AppStoreConnectError.invalidPrivateKey
        }
    }

    func preparePublication(
        bundleIdentifier: String,
        version: String,
        locale: String,
        metadata: AppStoreMetadata,
        copyright: String,
        supportURL: String,
        releaseAutomatically: Bool
    ) async throws -> AppStoreConnectPublication {
        let appID = try await findApplication(bundleIdentifier: bundleIdentifier)
        let versionID = try await findOrCreateVersion(
            appID: appID,
            version: version,
            copyright: copyright,
            releaseAutomatically: releaseAutomatically
        )
        let localizationID = try await findOrCreateLocalization(
            versionID: versionID,
            locale: locale
        )
        do {
            try await updateLocalization(
                localizationID,
                metadata: metadata,
                supportURL: supportURL,
                includesReleaseNotes: true
            )
        } catch AppStoreConnectError.requestFailed(let status, _) where status == 409 || status == 422 {
            // App Store Connect rejects release notes for an application's first version.
            try await updateLocalization(
                localizationID,
                metadata: metadata,
                supportURL: supportURL,
                includesReleaseNotes: false
            )
        }
        return AppStoreConnectPublication(
            appID: appID,
            versionID: versionID,
            localizationID: localizationID
        )
    }

    func uploadScreenshots(
        _ screenshots: [AppStoreScreenshotAsset],
        localizationID: String,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws {
        for group in Dictionary(grouping: screenshots, by: \AppStoreScreenshotAsset.displayType).sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation()
            let displayType = group.key
            let setResponse = try await request(
                method: "GET",
                path: "/v1/appStoreVersionLocalizations/\(localizationID)/appScreenshotSets",
                query: ["filter[screenshotDisplayType]": displayType, "include": "appScreenshots", "limit": "50"]
            )
            let existingScreenshots = (setResponse["included"] as? [[String: Any]])?.filter {
                $0["type"] as? String == "appScreenshots"
            } ?? []
            if !existingScreenshots.isEmpty {
                onOutput(L10n.format("Keeping %d existing screenshot(s) for %@.\n", existingScreenshots.count, displayType))
                continue
            }

            let screenshotSetID: String
            if let existingSet = (setResponse["data"] as? [[String: Any]])?.first,
               let id = existingSet["id"] as? String {
                screenshotSetID = id
            } else {
                let created = try await request(
                    method: "POST",
                    path: "/v1/appScreenshotSets",
                    body: [
                        "data": [
                            "type": "appScreenshotSets",
                            "attributes": ["screenshotDisplayType": displayType],
                            "relationships": [
                                "appStoreVersionLocalization": [
                                    "data": ["type": "appStoreVersionLocalizations", "id": localizationID]
                                ]
                            ]
                        ]
                    ]
                )
                screenshotSetID = try Self.identifier(in: created, named: "screenshot set")
            }

            for screenshot in group.value.prefix(10) {
                try await uploadScreenshot(
                    screenshot,
                    screenshotSetID: screenshotSetID,
                    onOutput: onOutput
                )
            }
        }
    }

    func waitForBuild(
        appID: String,
        buildNumber: String,
        timeout: TimeInterval = 30 * 60,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            let response = try await request(
                method: "GET",
                path: "/v1/builds",
                query: [
                    "filter[app]": appID,
                    "filter[version]": buildNumber,
                    "sort": "-uploadedDate",
                    "limit": "10"
                ]
            )
            if let build = (response["data"] as? [[String: Any]])?.first,
               let id = build["id"] as? String {
                let attributes = build["attributes"] as? [String: Any]
                let state = attributes?["processingState"] as? String ?? "PROCESSING"
                if state == "VALID" { return id }
                if state == "FAILED" || state == "INVALID" {
                    throw AppStoreConnectError.requestFailed(422, L10n.format("Build processing finished with state %@.", state))
                }
                onOutput(L10n.format("App Store build processing: %@.\n", state))
            } else {
                onOutput(L10n.text("Waiting for the uploaded build to appear in App Store Connect…\n"))
            }
            try await Task.sleep(for: .seconds(30))
        }
        throw AppStoreConnectError.buildProcessingTimedOut
    }

    func attachBuild(_ buildID: String, toVersion versionID: String) async throws {
        _ = try await request(
            method: "PATCH",
            path: "/v1/appStoreVersions/\(versionID)/relationships/build",
            body: ["data": ["type": "builds", "id": buildID]]
        )
    }

    func submitForReview(appID: String, versionID: String) async throws {
        let submissionResponse: [String: Any]
        do {
            submissionResponse = try await request(
                method: "POST",
                path: "/v1/reviewSubmissions",
                body: [
                    "data": [
                        "type": "reviewSubmissions",
                        "attributes": ["platform": "IOS"],
                        "relationships": [
                            "app": ["data": ["type": "apps", "id": appID]]
                        ]
                    ]
                ]
            )
        } catch AppStoreConnectError.requestFailed(let status, _) where status == 409 {
            let existing = try await request(
                method: "GET",
                path: "/v1/apps/\(appID)/reviewSubmissions",
                query: [
                    "filter[platform]": "IOS",
                    "filter[state]": "READY_FOR_REVIEW,UNRESOLVED_ISSUES",
                    "limit": "50"
                ]
            )
            guard let unresolved = (existing["data"] as? [[String: Any]])?.first else {
                throw AppStoreConnectError.requestFailed(409, L10n.text("An active review submission could not be located."))
            }
            submissionResponse = ["data": unresolved]
        }
        let submissionID = try Self.identifier(in: submissionResponse, named: "review submission")

        do {
            _ = try await request(
                method: "POST",
                path: "/v1/reviewSubmissionItems",
                body: [
                    "data": [
                        "type": "reviewSubmissionItems",
                        "relationships": [
                            "reviewSubmission": [
                                "data": ["type": "reviewSubmissions", "id": submissionID]
                            ],
                            "appStoreVersion": [
                                "data": ["type": "appStoreVersions", "id": versionID]
                            ]
                        ]
                    ]
                ]
            )
        } catch AppStoreConnectError.requestFailed(let status, _) where status == 409 {
            // The version is already attached to this active review submission.
        }

        _ = try await request(
            method: "PATCH",
            path: "/v1/reviewSubmissions/\(submissionID)",
            body: [
                "data": [
                    "type": "reviewSubmissions",
                    "id": submissionID,
                    "attributes": ["submitted": true]
                ]
            ]
        )
    }

    static func jwt(
        issuerID: String,
        keyID: String,
        privateKey: P256.Signing.PrivateKey,
        now: Date = Date()
    ) throws -> String {
        let header: [String: Any] = ["alg": "ES256", "kid": keyID, "typ": "JWT"]
        let issuedAt = Int(now.timeIntervalSince1970)
        let payload: [String: Any] = [
            "iss": issuerID,
            "iat": issuedAt,
            "exp": issuedAt + 1_100,
            "aud": "appstoreconnect-v1"
        ]
        let encodedHeader = base64URL(try JSONSerialization.data(withJSONObject: header))
        let encodedPayload = base64URL(try JSONSerialization.data(withJSONObject: payload))
        let signingInput = "\(encodedHeader).\(encodedPayload)"
        guard let signingData = signingInput.data(using: .utf8) else {
            throw AppStoreConnectError.invalidPrivateKey
        }
        let signature = try privateKey.signature(for: signingData)
        return "\(signingInput).\(base64URL(signature.rawRepresentation))"
    }

    private func findApplication(bundleIdentifier: String) async throws -> String {
        let response = try await request(
            method: "GET",
            path: "/v1/apps",
            query: ["filter[bundleId]": bundleIdentifier, "limit": "1"]
        )
        guard let app = (response["data"] as? [[String: Any]])?.first,
              let appID = app["id"] as? String else {
            throw AppStoreConnectError.applicationNotFound(bundleIdentifier)
        }
        return appID
    }

    private func updateLocalization(
        _ localizationID: String,
        metadata: AppStoreMetadata,
        supportURL: String,
        includesReleaseNotes: Bool
    ) async throws {
        var attributes: [String: Any] = [
            "description": metadata.description,
            "keywords": metadata.keywords,
            "promotionalText": metadata.promotionalText,
            "supportUrl": supportURL
        ]
        if includesReleaseNotes {
            attributes["whatsNew"] = metadata.whatsNew
        }
        _ = try await request(
            method: "PATCH",
            path: "/v1/appStoreVersionLocalizations/\(localizationID)",
            body: [
                "data": [
                    "type": "appStoreVersionLocalizations",
                    "id": localizationID,
                    "attributes": attributes
                ]
            ]
        )
    }

    private func findOrCreateVersion(
        appID: String,
        version: String,
        copyright: String,
        releaseAutomatically: Bool
    ) async throws -> String {
        let response = try await request(
            method: "GET",
            path: "/v1/apps/\(appID)/appStoreVersions",
            query: ["filter[platform]": "IOS", "filter[versionString]": version, "limit": "10"]
        )
        if let existing = (response["data"] as? [[String: Any]])?.first,
           let id = existing["id"] as? String {
            _ = try await request(
                method: "PATCH",
                path: "/v1/appStoreVersions/\(id)",
                body: [
                    "data": [
                        "type": "appStoreVersions",
                        "id": id,
                        "attributes": [
                            "releaseType": releaseAutomatically ? "AFTER_APPROVAL" : "MANUAL",
                            "copyright": copyright
                        ]
                    ]
                ]
            )
            return id
        }
        let created = try await request(
            method: "POST",
            path: "/v1/appStoreVersions",
            body: [
                "data": [
                    "type": "appStoreVersions",
                    "attributes": [
                        "platform": "IOS",
                        "versionString": version,
                        "copyright": copyright,
                        "releaseType": releaseAutomatically ? "AFTER_APPROVAL" : "MANUAL"
                    ],
                    "relationships": ["app": ["data": ["type": "apps", "id": appID]]]
                ]
            ]
        )
        return try Self.identifier(in: created, named: "App Store version")
    }

    private func findOrCreateLocalization(versionID: String, locale: String) async throws -> String {
        let response = try await request(
            method: "GET",
            path: "/v1/appStoreVersions/\(versionID)/appStoreVersionLocalizations",
            query: ["filter[locale]": locale, "limit": "10"]
        )
        if let existing = (response["data"] as? [[String: Any]])?.first,
           let id = existing["id"] as? String {
            return id
        }
        let created = try await request(
            method: "POST",
            path: "/v1/appStoreVersionLocalizations",
            body: [
                "data": [
                    "type": "appStoreVersionLocalizations",
                    "attributes": ["locale": locale],
                    "relationships": [
                        "appStoreVersion": [
                            "data": ["type": "appStoreVersions", "id": versionID]
                        ]
                    ]
                ]
            ]
        )
        return try Self.identifier(in: created, named: "localization")
    }

    private func uploadScreenshot(
        _ screenshot: AppStoreScreenshotAsset,
        screenshotSetID: String,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws {
        let fileData = try Data(contentsOf: screenshot.url)
        let reserved = try await request(
            method: "POST",
            path: "/v1/appScreenshots",
            body: [
                "data": [
                    "type": "appScreenshots",
                    "attributes": [
                        "fileName": screenshot.url.lastPathComponent,
                        "fileSize": fileData.count
                    ],
                    "relationships": [
                        "appScreenshotSet": [
                            "data": ["type": "appScreenshotSets", "id": screenshotSetID]
                        ]
                    ]
                ]
            ]
        )
        let screenshotID = try Self.identifier(in: reserved, named: "screenshot")
        guard let data = reserved["data"] as? [String: Any],
              let attributes = data["attributes"] as? [String: Any],
              let operations = attributes["uploadOperations"] as? [[String: Any]] else {
            throw AppStoreConnectError.invalidResponse
        }
        for operation in operations {
            guard let rawURL = operation["url"] as? String,
                  let url = URL(string: rawURL),
                  let method = operation["method"] as? String,
                  let offset = operation["offset"] as? Int,
                  let length = operation["length"] as? Int,
                  offset >= 0, length >= 0, offset + length <= fileData.count else {
                throw AppStoreConnectError.invalidResponse
            }
            var uploadRequest = URLRequest(url: url)
            uploadRequest.httpMethod = method
            for header in operation["requestHeaders"] as? [[String: Any]] ?? [] {
                if let name = header["name"] as? String, let value = header["value"] as? String {
                    uploadRequest.setValue(value, forHTTPHeaderField: name)
                }
            }
            uploadRequest.httpBody = fileData.subdata(in: offset..<(offset + length))
            let (_, response) = try await session.data(for: uploadRequest)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw AppStoreConnectError.requestFailed(
                    (response as? HTTPURLResponse)?.statusCode ?? 0,
                    L10n.text("Screenshot asset upload failed.")
                )
            }
        }
        _ = try await request(
            method: "PATCH",
            path: "/v1/appScreenshots/\(screenshotID)",
            body: [
                "data": [
                    "type": "appScreenshots",
                    "id": screenshotID,
                    "attributes": ["uploaded": true]
                ]
            ]
        )
        onOutput(L10n.format("Uploaded screenshot %@.\n", screenshot.url.lastPathComponent))
    }

    private func request(
        method: String,
        path: String,
        query: [String: String] = [:],
        body: [String: Any]? = nil
    ) async throws -> [String: Any] {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.sorted(by: { $0.key < $1.key }).map(URLQueryItem.init)
        }
        guard let url = components.url else { throw AppStoreConnectError.invalidResponse }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = method
        urlRequest.setValue("Bearer \(try token())", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.timeoutInterval = 120
        if let body {
            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw AppStoreConnectError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AppStoreConnectError.requestFailed(http.statusCode, Self.errorMessage(from: data))
        }
        if data.isEmpty { return [:] }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppStoreConnectError.invalidResponse
        }
        return root
    }

    private func token() throws -> String {
        try Self.jwt(issuerID: issuerID, keyID: keyID, privateKey: privateKey)
    }

    private static func identifier(in response: [String: Any], named name: String) throws -> String {
        guard let data = response["data"] as? [String: Any], let id = data["id"] as? String else {
            throw AppStoreConnectError.missingIdentifier(name)
        }
        return id
    }

    private static func errorMessage(from data: Data) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8) ?? L10n.text("Unknown error")
        }
        if let errors = root["errors"] as? [[String: Any]], !errors.isEmpty {
            return errors.compactMap {
                ($0["detail"] as? String) ?? ($0["title"] as? String)
            }.joined(separator: "\n")
        }
        return L10n.text("Unknown error")
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
