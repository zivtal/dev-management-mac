import Foundation

struct AppStoreReadinessCheck: Equatable, Sendable {
    let name: String
    let passed: Bool
    var required = true
}

struct AppStoreSubmissionReadiness: Sendable {
    let platform: AppStorePlatform
    let version: String
    let state: String
    let checks: [AppStoreReadinessCheck]
    var isReady: Bool { checks.allSatisfy { $0.passed || !$0.required } }
    var text: String {
        "\(platform.rawValue) \(version): \(state)\n" + checks.map {
            "[\($0.passed ? "OK" : ($0.required ? "MISSING" : "OPTIONAL"))] \($0.name)"
        }.joined(separator: "\n") + "\n"
    }
    func requireReady() throws {
        guard isReady else { throw AppStoreReleaseError.invalid(text) }
    }
}

extension AppStoreConnectService {
    /// All requests in doctor/readiness are GETs. Authentication/network failures are not empty data.
    func submissionReadiness(versionID: String, expectedVersion: String? = nil,
                             expectedBuildID: String? = nil,
                             requiredDemoVideoURL: String? = nil) async throws -> AppStoreSubmissionReadiness {
        let versionResponse = try await request(method: "GET", path: "/v1/appStoreVersions/\(versionID)")
        let version = versionResponse["data"] as? [String: Any] ?? [:]
        let attributes = version["attributes"] as? [String: Any] ?? [:]
        let versionString = attributes["versionString"] as? String ?? "?"
        var checks = [AppStoreReadinessCheck(name: "Platform \(platform.rawValue)",
            passed: attributes["platform"] as? String == platform.rawValue)]
        if let expectedVersion {
            checks.append(.init(name: "Version matches archive (\(expectedVersion))", passed: versionString == expectedVersion))
        }
        checks.append(.init(name: "Copyright", passed: Self.hasText(attributes, "copyright")))
        checks.append(.init(name: "Release type", passed: ["MANUAL", "AFTER_APPROVAL", "SCHEDULED"].contains(attributes["releaseType"] as? String ?? "")))
        let build = try await optionalReadinessResource("/v1/appStoreVersions/\(versionID)/build")
        let buildAttributes = build?["attributes"] as? [String: Any] ?? [:]
        checks.append(.init(name: "Processed build attached", passed: buildAttributes["processingState"] as? String == "VALID"))
        if let expectedBuildID {
            checks.append(.init(name: "Attached build matches uploaded build", passed: build?["id"] as? String == expectedBuildID))
        }
        if let buildID = build?["id"] as? String {
            let pre = try await optionalReadinessResource("/v1/builds/\(buildID)/preReleaseVersion")
            let preAttributes = pre?["attributes"] as? [String: Any] ?? [:]
            checks.append(.init(name: "Build platform/version matches storefront",
                passed: preAttributes["platform"] as? String == platform.rawValue && preAttributes["version"] as? String == versionString))
        }
        let localizations = try await pagedData(path: "/v1/appStoreVersions/\(versionID)/appStoreVersionLocalizations", query: ["limit": "200"])
        checks.append(.init(name: "Store listing localizations", passed: !localizations.isEmpty))
        var hasScreenshots = false
        for localization in localizations {
            guard let id = localization["id"] as? String else { throw AppStoreConnectError.invalidResponse }
            let values = localization["attributes"] as? [String: Any] ?? [:]
            let locale = values["locale"] as? String ?? "?"
            for key in ["description", "keywords", "supportUrl"] {
                checks.append(.init(name: "\(locale): \(key)", passed: Self.hasText(values, key)))
            }
            for key in ["promotionalText", "marketingUrl"] {
                checks.append(.init(name: "\(locale): \(key)", passed: Self.hasText(values, key), required: false))
            }
            let sets = try await pagedData(path: "/v1/appStoreVersionLocalizations/\(id)/appScreenshotSets", query: ["limit": "200"])
            for set in sets {
                let values = set["attributes"] as? [String: Any] ?? [:]
                let type = values["screenshotDisplayType"] as? String ?? ""
                guard platform != .macOS || type == "APP_DESKTOP" else { continue }
                guard let setID = set["id"] as? String else { throw AppStoreConnectError.invalidResponse }
                let assets = try await pagedData(path: "/v1/appScreenshotSets/\(setID)/appScreenshots", query: ["limit": "200"])
                hasScreenshots = hasScreenshots || assets.contains {
                    let attributes = $0["attributes"] as? [String: Any] ?? [:]
                    let delivery = attributes["assetDeliveryState"] as? [String: Any] ?? [:]
                    return delivery["state"] as? String == "COMPLETE"
                }
            }
        }
        checks.append(.init(name: platform == .macOS ? "Processed APP_DESKTOP screenshots" : "Processed screenshots", passed: hasScreenshots))
        let review = try await optionalReadinessResource("/v1/appStoreVersions/\(versionID)/appStoreReviewDetail")
        let details = review?["attributes"] as? [String: Any] ?? [:]
        for key in ["contactFirstName", "contactLastName", "contactEmail", "contactPhone", "notes"] {
            checks.append(.init(name: "App Review: \(key)", passed: Self.hasText(details, key)))
        }
        checks.append(.init(name: "App Review: sign-in declaration", passed: details["demoAccountRequired"] is Bool))
        if details["demoAccountRequired"] as? Bool == true {
            // Only report presence; never print reviewer credentials.
            for key in ["demoAccountName", "demoAccountPassword"] {
                checks.append(.init(name: "App Review: \(key)", passed: Self.hasText(details, key)))
            }
        }
        if let video = requiredDemoVideoURL?.nilIfEmpty {
            checks.append(.init(name: "Hardware demo video in review notes", passed: (details["notes"] as? String ?? "").contains(video)))
        }
        return AppStoreSubmissionReadiness(platform: platform, version: versionString,
            state: attributes["appStoreState"] as? String ?? "UNKNOWN", checks: checks)
    }

    func doctor(appID: String) async throws -> String {
        let builds = try await pagedData(path: "/v1/builds", query: ["filter[app]": appID,
            "filter[preReleaseVersion.platform]": platform.rawValue, "limit": "200"])
        var output = "\(platform.rawValue): \(builds.count) TestFlight build(s)\n"
        for build in builds {
            let values = build["attributes"] as? [String: Any] ?? [:]
            output += "  Build \(values["version"] as? String ?? "?"): \(values["processingState"] as? String ?? "UNKNOWN")\n"
        }
        let versions = try await pagedData(path: "/v1/apps/\(appID)/appStoreVersions",
            query: ["filter[platform]": platform.rawValue, "limit": "200"])
        if versions.isEmpty { output += "[MISSING] App Store version\n" }
        for version in versions {
            guard let id = version["id"] as? String else { throw AppStoreConnectError.invalidResponse }
            output += try await submissionReadiness(versionID: id).text
        }
        return output
    }

    func validateNewMacBuildNumber(appID: String, buildNumber: String) async throws {
        let builds = try await pagedData(path: "/v1/builds", query: ["filter[app]": appID,
            "filter[preReleaseVersion.platform]": "MAC_OS", "limit": "200"])
        for build in builds {
            let values = build["attributes"] as? [String: Any] ?? [:]
            guard let previous = values["version"] as? String else { continue }
            if buildNumber.compare(previous, options: .numeric) != .orderedDescending {
                throw AppStoreReleaseError.invalid("MAC_OS build \(buildNumber) must be greater than existing Mac build \(previous), across all versions. Update the repository's version explicitly; publishing never bumps it.")
            }
        }
    }

    func waitForSubmittedVersion(versionID: String, buildID: String,
                                 attempts: Int = 30, onOutput: @escaping @Sendable (String) -> Void) async throws {
        for attempt in 0..<attempts {
            try Task.checkCancellation()
            let response = try await request(method: "GET", path: "/v1/appStoreVersions/\(versionID)",
                query: ["include": "build"])
            let data = response["data"] as? [String: Any] ?? [:]
            let attributes = data["attributes"] as? [String: Any] ?? [:]
            let relationships = data["relationships"] as? [String: Any] ?? [:]
            let relation = relationships["build"] as? [String: Any] ?? [:]
            let attached = relation["data"] as? [String: Any] ?? [:]
            let state = attributes["appStoreState"] as? String ?? "UNKNOWN"
            onOutput("\(platform.rawValue) App Store version: \(state)\n")
            if ["WAITING_FOR_REVIEW", "IN_REVIEW", "PENDING_APPLE_RELEASE", "PENDING_DEVELOPER_RELEASE",
                "READY_FOR_SALE", "READY_FOR_DISTRIBUTION", "PROCESSING_FOR_APP_STORE"].contains(state),
               attached["id"] as? String == buildID, attributes["platform"] as? String == platform.rawValue { return }
            if attempt + 1 < attempts { try await Task.sleep(for: .seconds(5)) }
        }
        throw AppStoreReleaseError.invalid("\(platform.rawValue): submission was sent, but Apple has not confirmed the attached build entered review. Check status before retrying.")
    }

    private func optionalReadinessResource(_ path: String) async throws -> [String: Any]? {
        do { return try await request(method: "GET", path: path)["data"] as? [String: Any] }
        catch AppStoreConnectError.requestFailed(let status, _) where status == 404 { return nil }
    }
    private static func hasText(_ values: [String: Any], _ key: String) -> Bool {
        (values[key] as? String)?.nilIfEmpty != nil
    }
}
