import Foundation

struct AppStoreArchiveRequirements: Codable, Equatable, Sendable {
    var networkClient: Bool? = nil
    /// Fully expanded groups, e.g. TEAMID.app.example.credentials.
    var keychainAccessGroups: [String]? = nil
    var encryptionDeclarationInInfoPlist: Bool? = nil
}

struct AppStorePlatformReleaseConfiguration: Codable, Equatable, Sendable {
    var scheme: String
    var configuration: String? = nil
    var sourcePaths: [String]? = nil
    var publication: [String: AppStoreJSONValue]? = nil
    var archiveRequirements: AppStoreArchiveRequirements? = nil
}

enum AppStoreReleaseError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

extension AppStorePublishingManifest {
    static func load(from folder: URL) throws -> AppStorePublishingManifest? {
        for name in ["app-store-publishing.json", ".app-store-publishing.json"] {
            let url = folder.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let manifest = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
            try manifest.validatePlatforms()
            return manifest
        }
        return nil
    }

    func validatePlatforms() throws {
        guard [1, 2].contains(schemaVersion ?? 1) else {
            throw AppStoreReleaseError.invalid("Unsupported publishing schema version.")
        }
        guard let platforms else { return }
        guard schemaVersion == 2, !platforms.isEmpty else {
            throw AppStoreReleaseError.invalid("A multi-platform release requires schemaVersion 2 and at least one platform.")
        }
        if let defaultPlatforms, defaultPlatforms.isEmpty || !Set(defaultPlatforms).isSubset(of: Set(platforms.keys)) {
            throw AppStoreReleaseError.invalid("defaultPlatforms must name at least one configured release platform.")
        }
        for (name, entry) in platforms {
            if let paths = entry.sourcePaths, paths.isEmpty || paths.contains(where: { $0.nilIfEmpty == nil }) {
                throw AppStoreReleaseError.invalid("sourcePaths must contain at least one source file or directory.")
            }
            guard AppStorePlatform(rawValue: name) != nil, entry.scheme.nilIfEmpty != nil else {
                throw AppStoreReleaseError.invalid("Invalid release platform/scheme: \(name). Use IOS or MAC_OS with an explicit scheme.")
            }
        }
    }

    /// Shared scalar/object fields are inherited; explicitly supplied arrays replace shared arrays.
    func publication(for platform: AppStorePlatform) throws -> AppStorePublicationConfiguration? {
        try validatePlatforms()
        guard let override = platforms?[platform.rawValue]?.publication else { return publication }
        guard let publication else {
            return try JSONDecoder().decode(AppStorePublicationConfiguration.self, from: JSONEncoder().encode(override))
        }
        let encoder = JSONEncoder()
        let shared = try JSONSerialization.jsonObject(with: encoder.encode(publication)) as! [String: Any]
        let specific = try JSONSerialization.jsonObject(with: encoder.encode(override)) as! [String: Any]
        func merge(_ base: [String: Any], _ overrides: [String: Any]) -> [String: Any] {
            base.merging(overrides) { old, new in
                if let old = old as? [String: Any], let new = new as? [String: Any] { return merge(old, new) }
                return new
            }
        }
        return try JSONDecoder().decode(AppStorePublicationConfiguration.self,
            from: JSONSerialization.data(withJSONObject: merge(shared, specific)))
    }
}

extension PublishingConfiguration {
    func applying(_ publication: AppStorePublicationConfiguration?, validateReviewRequirements: Bool = true) throws -> Self {
        guard let p = publication else { return self }
        var result = self
        if let value = p.locale { result.locale = value }
        if let value = p.copyright { result.copyright = value }
        if let value = p.supportURL { result.supportURL = value }
        if let value = p.marketingURL { result.marketingURL = value }
        if let value = p.termsURL { result.termsURL = value }
        if let value = p.privacyPolicyURL { result.privacyPolicyURL = value }
        if let value = p.privacyChoicesURL { result.privacyChoicesURL = value }
        if let value = p.appName { result.appName = value }
        if let value = p.subtitle { result.subtitle = value }
        if let value = p.licenseAgreementText { result.licenseAgreementText = value }
        if let value = p.metadata { result.manualMetadata = value }
        if let value = p.localizations { result.manualLocalizations = value }
        if let value = p.screenshotPaths { result.screenshotPaths = value }
        if let value = p.screenshotSimulatorUDIDs { result.screenshotSimulatorUDIDs = value }
        if let value = p.reviewAttachmentPaths { result.reviewAttachmentPaths = value }
        if let value = p.replaceScreenshots { result.replaceScreenshots = value }
        if let value = p.releaseAutomatically { result.releaseAutomatically = value }
        if let value = p.testFlight { result.testFlight = value }
        if let value = p.usesNonExemptEncryption { result.usesNonExemptEncryption = value }
        let old = result.review
        let review = p.review
        let video = review?.demoVideoURL ?? old.demoVideoURL
        let required = review?.demoVideoRequired ?? old.demoVideoRequired
        if let video, !video.isEmpty {
            guard let url = URL(string: video), url.scheme == "https", url.host != nil else {
                throw AppStoreReleaseError.invalid("The App Review demo video must have a public HTTPS URL.")
            }
        }
        if validateReviewRequirements && intent.submitsForReview && required && video?.nilIfEmpty == nil {
            throw AppStoreReleaseError.invalid("App Review requires a hardware demo video. Set review.demoVideoURL before publishing.")
        }
        var notes = review?.notes ?? old.notes
        if let video = video?.nilIfEmpty, !notes.contains(video) { notes += "\n\nHardware demo video: \(video)" }
        result.review = AppStoreReviewConfiguration(
            contactFirstName: review?.contactFirstName ?? old.contactFirstName,
            contactLastName: review?.contactLastName ?? old.contactLastName,
            contactPhone: review?.contactPhone ?? old.contactPhone,
            contactEmail: review?.contactEmail ?? old.contactEmail,
            notes: notes, demoAccountRequired: review?.demoAccountRequired ?? old.demoAccountRequired,
            demoAccountName: old.demoAccountName, demoAccountPassword: old.demoAccountPassword,
            demoVideoURL: video, demoVideoRequired: required)
        return result
    }
}

/// Partial objects are merged before decoding typed publication fields, allowing a Mac-only
/// description override without duplicating all shared metadata or contact fields.
enum AppStoreJSONValue: Codable, Equatable, Sendable {
    case string(String), bool(Bool), number(Double), object([String: AppStoreJSONValue]), array([AppStoreJSONValue]), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([String: Self].self) { self = .object(v) }
        else { self = .array(try c.decode([Self].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}

extension PublishingConfiguration {
    func validateReleaseInputs() throws {
        var missing: [String] = []
        if let error = AppStoreCopyrightNormalizer.validationError(for: copyright) { missing.append(error.localizedDescription) }
        for (name, value) in [("supportURL", supportURL), ("privacyPolicyURL", privacyPolicyURL ?? "")] {
            if let url = URL(string: value), ["http", "https"].contains(url.scheme ?? ""), url.host != nil {} else { missing.append(name) }
        }
        if manualLocalizations.isEmpty {
            if manualMetadata?.description.nilIfEmpty == nil { missing.append("description") }
            if manualMetadata?.keywords.nilIfEmpty == nil { missing.append("keywords") }
        } else {
            for listing in manualLocalizations {
                if listing.description.nilIfEmpty == nil { missing.append("\(listing.locale): description") }
                if listing.keywords.nilIfEmpty == nil { missing.append("\(listing.locale): keywords") }
            }
        }
        for (name, value) in [("contactFirstName", review.contactFirstName), ("contactLastName", review.contactLastName),
                              ("contactPhone", review.contactPhone), ("contactEmail", review.contactEmail), ("notes", review.notes)] {
            if value.nilIfEmpty == nil { missing.append("review.\(name)") }
        }
        if review.demoAccountRequired && (review.demoAccountName?.nilIfEmpty == nil || review.demoAccountPassword?.nilIfEmpty == nil) {
            missing.append("review demo account in Keychain")
        }
        if !missing.isEmpty { throw AppStoreReleaseError.invalid("Missing release configuration: " + missing.joined(separator: ", ")) }
    }
}
